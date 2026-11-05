package indexer

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"medina/internal/scanner"
)

func TestScannerRegistersNestedWatchesWithoutSeparateWalk(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "Course", "Section")
	if err := os.MkdirAll(nested, 0755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := make(chan string, 8)
	done := make(chan error, 1)
	monitor := &Monitor{Root: root, Interval: time.Hour, Debounce: 20 * time.Millisecond}
	monitor.Scan = func(ctx context.Context, reason string) error {
		_, err := scanner.ScanWithOptions(ctx, root, scanner.Options{OnDirectory: monitor.WatchDirectory}, nil)
		calls <- reason
		return err
	}
	go func() { done <- monitor.Run(ctx) }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	select {
	case <-calls:
	case <-time.After(2 * time.Second):
		t.Fatal("startup not scheduled")
	}
	waitForWatch(t, monitor, nested)
	if err := os.WriteFile(filepath.Join(nested, "lesson.mp4"), []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-calls:
		if reason != "filesystem_change" {
			t.Fatalf("reason=%s", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("nested directory was not watched")
	}
}

func waitForWatch(t *testing.T, monitor *Monitor, path string) {
	t.Helper()
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		monitor.watchMu.Lock()
		registered := monitor.watched[path] || monitor.watched[canonical]
		monitor.watchMu.Unlock()
		if registered {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("directory watch was not registered: %s", path)
}

func TestDisabledWatcherStillScansAtStartup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := make(chan string, 4)
	done := make(chan error, 1)
	monitor := &Monitor{Root: t.TempDir(), DisableWatching: true, Interval: time.Hour, Debounce: time.Millisecond, Scan: func(_ context.Context, reason string) error { calls <- reason; return nil }}
	go func() { done <- monitor.Run(ctx) }()
	select {
	case reason := <-calls:
		if reason != "startup_reconciliation" {
			t.Fatalf("reason=%s", reason)
		}
	case <-time.After(time.Second):
		t.Fatal("startup not scheduled")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
