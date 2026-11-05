package scanner

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Observers run serially on the traversal goroutine, even when filesystem
// operations overlap. Workers limits metadata requests across the entire scan.
type Options struct {
	Workers          int
	DirectoryWorkers int
	OnProgress       func(Progress)
	OnDirectory      func(string)
}

type Progress struct {
	Phase                string `json:"phase"`
	EntriesVisited       int    `json:"entriesVisited"`
	CurrentDirectory     string `json:"currentDirectory"`
	CurrentOperation     string `json:"currentOperation"`
	DirectoriesRead      int    `json:"directoriesRead"`
	ActiveDirectoryReads int    `json:"activeDirectoryReads"`
	ActiveMetadataReads  int    `json:"activeMetadataReads"`
	ElapsedMS            int64  `json:"elapsedMs"`
	// These are aggregate operation times, including active operations. Parallel
	// operations overlap, so they must not be added to estimate elapsed time.
	EnumerationMS int64 `json:"enumerationMs"`
	MetadataMS    int64 `json:"metadataMs"`
	PersistenceMS int64 `json:"persistenceMs"`
}

type namedEntry struct {
	name string
	info fs.FileInfo
}

func (e namedEntry) Name() string { return e.name }
func (e namedEntry) Info() (fs.FileInfo, error) {
	if e.info == nil {
		return nil, fs.ErrInvalid
	}
	return e.info, nil
}
func (e namedEntry) IsDir() bool { return e.info != nil && e.info.IsDir() }
func (e namedEntry) Type() fs.FileMode {
	if e.info == nil {
		return 0
	}
	return e.info.Mode().Type()
}

func ignoredEntry(name string) bool {
	if isIgnoredName(name) {
		return true
	}
	for _, suffix := range tempSuffixes {
		if strings.HasSuffix(strings.ToLower(name), suffix) {
			return true
		}
	}
	return false
}

type walkFS struct {
	readNames func(string) ([]string, error)
	lstat     func(string) (fs.FileInfo, error)
}

func readNames(path string) ([]string, error) {
	directory, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	// Unlike ReadDir, Readdirnames never falls back to per-entry lstat when
	// the filesystem returns an unknown directory-entry type.
	names, err := directory.Readdirnames(-1)
	sort.Strings(names)
	return names, err
}

type directoryResult struct {
	entries []namedEntry
	errors  []error
	err     error
}
type directoryTask struct {
	path      string
	result    chan directoryResult
	mu        sync.Mutex
	operation string
}

func (t *directoryTask) setOperation(operation string) {
	t.mu.Lock()
	t.operation = operation
	t.mu.Unlock()
}
func (t *directoryTask) getOperation() string { t.mu.Lock(); defer t.mu.Unlock(); return t.operation }

type walkMetrics struct {
	mu          sync.Mutex
	listings    map[string]time.Time
	metadata    map[string]time.Time
	enumeration time.Duration
	statTime    time.Duration
	directories int
}

func (m *walkMetrics) snapshot(p *Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	listing, metadata := m.enumeration, m.statTime
	for _, start := range m.listings {
		listing += now.Sub(start)
	}
	for _, start := range m.metadata {
		metadata += now.Sub(start)
	}
	p.EnumerationMS = listing.Milliseconds()
	p.MetadataMS = metadata.Milliseconds()
	p.ActiveDirectoryReads = len(m.listings)
	p.ActiveMetadataReads = len(m.metadata)
	p.DirectoriesRead = m.directories
}

func boundedWorkers(value, fallback int) int {
	if value <= 0 {
		return fallback
	}
	if value > 64 {
		return 64
	}
	return value
}

// Directory results are prefetched concurrently but consumed in lexical DFS
// order. This keeps IDs, parent insertion, and partial batches deterministic.
// The lookahead is bounded (16–128 outstanding directory results), rather
// than buffering the entire library before publishing.
func walkMetadata(ctx context.Context, root string, options Options, progress *Progress, report func(), visit fs.WalkDirFunc) error {
	return walkMetadataWithFS(ctx, root, options, progress, report, visit, walkFS{readNames: readNames, lstat: os.Lstat})
}

func walkMetadataWithFS(parent context.Context, root string, options Options, progress *Progress, report func(), visit fs.WalkDirFunc, filesystem walkFS) error {
	ctx, cancel := context.WithCancel(parent)
	workers := boundedWorkers(options.Workers, 8)
	directoryWorkers := boundedWorkers(options.DirectoryWorkers, 4)
	lookahead := directoryWorkers * 16
	if lookahead > 128 {
		lookahead = 128
	}
	metrics := walkMetrics{listings: make(map[string]time.Time), metadata: make(map[string]time.Time)}
	type statJob struct {
		path  string
		entry *namedEntry
		err   *error
		done  *sync.WaitGroup
	}
	statJobs := make(chan statJob, workers)
	tasks := make(chan *directoryTask, lookahead+1)
	var statWG, directoryWG sync.WaitGroup
	for i := 0; i < workers; i++ {
		statWG.Add(1)
		go func() {
			defer statWG.Done()
			for job := range statJobs {
				if ctx.Err() == nil {
					start := time.Now()
					metrics.mu.Lock()
					metrics.metadata[job.path] = start
					metrics.mu.Unlock()
					job.entry.info, *job.err = filesystem.lstat(job.path)
					metrics.mu.Lock()
					delete(metrics.metadata, job.path)
					metrics.statTime += time.Since(start)
					metrics.mu.Unlock()
				}
				job.done.Done()
			}
		}()
	}
	for i := 0; i < directoryWorkers; i++ {
		directoryWG.Add(1)
		go func() {
			defer directoryWG.Done()
			for {
				var task *directoryTask
				select {
				case <-ctx.Done():
					return
				case task = <-tasks:
				}
				if ctx.Err() != nil {
					return
				}
				task.setOperation("listing")
				start := time.Now()
				metrics.mu.Lock()
				metrics.listings[task.path] = start
				metrics.mu.Unlock()
				names, err := filesystem.readNames(task.path)
				metrics.mu.Lock()
				delete(metrics.listings, task.path)
				metrics.enumeration += time.Since(start)
				if err == nil {
					metrics.directories++
				}
				metrics.mu.Unlock()
				result := directoryResult{err: err}
				if err == nil && ctx.Err() == nil {
					result.entries = make([]namedEntry, len(names))
					result.errors = make([]error, len(names))
					task.setOperation("metadata")
					var jobsWG sync.WaitGroup
					for i, name := range names {
						result.entries[i].name = name
						if ignoredEntry(name) {
							continue
						}
						if ctx.Err() != nil {
							break
						}
						jobsWG.Add(1)
						job := statJob{filepath.Join(task.path, name), &result.entries[i], &result.errors[i], &jobsWG}
						select {
						case statJobs <- job:
						case <-ctx.Done():
							jobsWG.Done()
						}
					}
					jobsWG.Wait()
				}
				task.setOperation("ready")
				task.result <- result // Buffered; workers never wait for ordered consumption.
			}
		}()
	}
	defer func() {
		cancel()
		directoryWG.Wait()
		close(statJobs)
		statWG.Wait()
		progress.CurrentOperation = ""
		metrics.snapshot(progress)
		report()
	}()
	pending := make(map[string]*directoryTask)
	schedule := func(path string) *directoryTask {
		if task := pending[path]; task != nil {
			return task
		}
		task := &directoryTask{path: path, result: make(chan directoryResult, 1), operation: "queued"}
		pending[path] = task
		select {
		case tasks <- task:
		case <-ctx.Done():
		}
		return task
	}
	update := func(task *directoryTask) {
		if task != nil {
			progress.CurrentOperation = task.getOperation()
		}
		metrics.snapshot(progress)
		report()
	}
	var walk func(string, fs.DirEntry) error
	walk = func(path string, directory fs.DirEntry) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		relative, _ := filepath.Rel(root, path)
		progress.CurrentDirectory = filepath.ToSlash(relative)
		task := schedule(path)
		update(task)
		// WatchDirectory must only enqueue work, not perform filesystem operations.
		if options.OnDirectory != nil {
			options.OnDirectory(path)
		}
		ticker := time.NewTicker(250 * time.Millisecond)
		var result directoryResult
	wait:
		for {
			select {
			case <-ctx.Done():
				ticker.Stop()
				return ctx.Err()
			case <-ticker.C:
				update(task)
			case result = <-task.result:
				break wait
			}
		}
		ticker.Stop()
		delete(pending, path)
		update(task)
		if err := ctx.Err(); err != nil {
			return err
		}
		if result.err != nil {
			return visit(path, directory, result.err)
		}
		// Prefetch immediate child directories while the consumer handles this
		// directory. Optional prefetch never blocks when the lookahead is full.
		for _, entry := range result.entries {
			if len(pending) >= lookahead {
				break
			}
			if entry.IsDir() && !ignoredEntry(entry.Name()) {
				schedule(filepath.Join(path, entry.Name()))
			}
		}
		for i, entry := range result.entries {
			if err := ctx.Err(); err != nil {
				return err
			}
			child := filepath.Join(path, entry.Name())
			progress.CurrentDirectory = filepath.ToSlash(relative)
			progress.CurrentOperation = "visiting"
			progress.EntriesVisited++
			err := visit(child, entry, result.errors[i])
			if err == filepath.SkipDir {
				continue
			}
			if err != nil {
				return err
			}
			if !ignoredEntry(entry.Name()) && entry.IsDir() {
				if err := walk(child, entry); err != nil {
					return err
				}
			}
		}
		update(nil)
		return nil
	}
	return walk(root, nil)
}
