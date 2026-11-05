package indexer

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Monitor combines low-latency filesystem notifications with a periodic full
// reconciliation scan. The periodic scan is important for Docker/network mounts
// that do not reliably forward host filesystem events.
type Monitor struct {
	Root            string
	Interval        time.Duration
	Debounce        time.Duration
	Logger          *slog.Logger
	Scan            func(context.Context, string) error
	DisableWatching bool
	watchMu         sync.Mutex
	watcher         *fsnotify.Watcher
	watchQueue      chan string
	watchPending    map[string]bool
	watched         map[string]bool
	watchOverflow   bool
}

// WatchDirectory only enqueues registration; filesystem watch syscalls never
// run on the scanner's ordered-consumption goroutine.
func (m *Monitor) WatchDirectory(path string) {
	m.watchMu.Lock()
	defer m.watchMu.Unlock()
	if m.watchQueue == nil || m.watched[path] || m.watchPending[path] {
		return
	}
	select {
	case m.watchQueue <- path:
		m.watchPending[path] = true
	default:
		if !m.watchOverflow {
			m.watchOverflow = true
			logger := m.Logger
			if logger == nil {
				logger = slog.Default()
			}
			logger.Warn("directory watch queue full; periodic reconciliation remains enabled")
		}
	}
}

func (m *Monitor) registerWatches(ctx context.Context, watcher *fsnotify.Watcher, queue <-chan string, logger *slog.Logger) {
	for {
		select {
		case <-ctx.Done():
			return
		case path := <-queue:
			if ctx.Err() != nil {
				return
			}
			started := time.Now()
			err := watcher.Add(path)
			m.watchMu.Lock()
			delete(m.watchPending, path)
			if err == nil {
				m.watched[path] = true
			}
			m.watchMu.Unlock()
			if err != nil {
				logger.Warn("cannot watch directory; periodic reconciliation remains enabled", "path", path, "error", err)
			} else if time.Since(started) >= time.Second {
				logger.Debug("slow directory watch registration", "path", path, "duration_ms", time.Since(started).Milliseconds())
			}
		}
	}
}

func (m *Monitor) Run(ctx context.Context) error {
	logger := m.Logger
	if logger == nil {
		logger = slog.Default()
	}
	if m.Scan == nil {
		return errors.New("index monitor requires a scan function")
	}
	if m.Interval <= 0 {
		return errors.New("index monitor interval must be positive")
	}
	if m.Debounce <= 0 {
		return errors.New("index monitor debounce must be positive")
	}

	var watcher *fsnotify.Watcher
	changes := make(chan string, 256)
	watchErrors := make(chan error, 16)
	watching := false
	watchCtx, stopWatches := context.WithCancel(ctx)
	defer stopWatches()
	var watchWG sync.WaitGroup
	var err error
	if !m.DisableWatching {
		watcher, err = fsnotify.NewWatcher()
		if err != nil {
			logger.Warn("filesystem watcher unavailable; periodic reconciliation remains enabled", "error", err)
			if watcher != nil {
				_ = watcher.Close()
			}
			watcher = nil
		} else {
			watching = true
			m.watchMu.Lock()
			m.watcher = watcher
			m.watchQueue = make(chan string, 1024)
			m.watchPending = make(map[string]bool)
			m.watched = make(map[string]bool)
			m.watchOverflow = false
			queue := m.watchQueue
			m.watchMu.Unlock()
			watchWG.Add(2)
			go func() { defer watchWG.Done(); m.registerWatches(watchCtx, watcher, queue, logger) }()
			go func() { defer watchWG.Done(); m.readEvents(watchCtx, watcher, changes, watchErrors, logger) }()
			m.WatchDirectory(m.Root)
		}
	}
	if watcher != nil {
		defer func() {
			stopWatches()
			m.watchMu.Lock()
			m.watcher = nil
			m.watchQueue = nil
			m.watchMu.Unlock()
			_ = watcher.Close()
			watchWG.Wait()
		}()
	}
	logger.Info("library monitoring started", "root", m.Root, "watching", watching, "scan_interval", m.Interval.String(), "event_debounce", m.Debounce.String())

	ticker := time.NewTicker(m.Interval)
	defer ticker.Stop()
	var debounce *time.Timer
	var debounceC <-chan time.Time
	var scanDone chan error
	pendingReason := ""
	requestScan := func(reason string) {
		if scanDone != nil {
			if pendingReason == "" {
				pendingReason = reason
			} else if !strings.Contains(pendingReason, reason) {
				pendingReason += "+" + reason
			}
			return
		}
		logger.Info("library scan scheduled", "reason", reason)
		scanDone = make(chan error, 1)
		go func() { scanDone <- m.Scan(ctx, reason) }()
	}
	resetDebounce := func() {
		if debounce == nil {
			debounce = time.NewTimer(m.Debounce)
		} else {
			if !debounce.Stop() {
				select {
				case <-debounce.C:
				default:
				}
			}
			debounce.Reset(m.Debounce)
		}
		debounceC = debounce.C
	}
	defer func() {
		if debounce != nil {
			debounce.Stop()
		}
	}()
	requestScan("startup_reconciliation")
	for {
		select {
		case <-ctx.Done():
			if scanDone != nil {
				<-scanDone // finish the monitor waiter; shutdown also joins the coordinator
			}
			return nil
		case name, ok := <-changes:
			if !ok {
				return nil
			}
			logger.Debug("filesystem change observed", "path", name)
			resetDebounce()
		case err, ok := <-watchErrors:
			if !ok {
				return nil
			}
			logger.Warn("filesystem watcher error; scheduling reconciliation", "error", err)
			resetDebounce()
		case <-debounceC:
			debounceC = nil
			requestScan("filesystem_change")
		case <-ticker.C:
			requestScan("periodic_reconciliation")
		case err := <-scanDone:
			scanDone = nil
			if err != nil {
				logger.Error("monitored library scan failed", "error", err)
			} else {
				logger.Info("monitored library scan completed")
			}
			if pendingReason != "" {
				reason := pendingReason
				pendingReason = ""
				requestScan(reason)
			}
		}
	}
}

func (m *Monitor) readEvents(ctx context.Context, watcher *fsnotify.Watcher, changes chan<- string, watchErrors chan<- error, logger *slog.Logger) {
	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			if ignoredName(filepath.Base(event.Name)) {
				continue
			}
			if event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) {
				m.watchMu.Lock()
				for path := range m.watched {
					if path == event.Name || strings.HasPrefix(path, event.Name+string(filepath.Separator)) {
						delete(m.watched, path)
					}
				}
				m.watchMu.Unlock()
			}
			if event.Has(fsnotify.Create) {
				if info, err := os.Lstat(event.Name); err == nil && info.IsDir() {
					m.WatchDirectory(event.Name)
				}
			}
			select {
			case changes <- event.Name:
			default:
				// One queued path is enough to request a full snapshot reconciliation.
				select {
				case changes <- "<event queue overflow>":
				default:
				}
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			notifyError(watchErrors, err)
		}
	}
}

func ignoredName(name string) bool {
	lower := strings.ToLower(name)
	return strings.HasPrefix(lower, "._") || lower == ".ds_store" || lower == "thumbs.db" || lower == "desktop.ini" || lower == ".git" || lower == ".svn" || lower == "@eadir"
}

func notifyError(ch chan<- error, err error) {
	select {
	case ch <- err:
	default:
	}
}
