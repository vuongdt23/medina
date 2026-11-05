package indexer

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestMonitorStartupAndPeriodicReconciliation(t *testing.T) {
	root := t.TempDir()
	var mu sync.Mutex
	var reasons []string
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	monitor := &Monitor{
		Root: root, Interval: 40 * time.Millisecond, Debounce: 20 * time.Millisecond,
		Logger: slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		Scan: func(_ context.Context, reason string) error {
			mu.Lock()
			reasons = append(reasons, reason)
			mu.Unlock()
			return nil
		},
	}
	go func() { done <- monitor.Run(ctx) }()

	deadline := time.After(2 * time.Second)
	for {
		mu.Lock()
		count := len(reasons)
		mu.Unlock()
		if count >= 2 {
			break
		}
		select {
		case <-deadline:
			cancel()
			<-done
			t.Fatalf("expected startup and periodic scans, got %d", count)
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if reasons[0] != "startup_reconciliation" {
		t.Fatalf("first scan reason = %q", reasons[0])
	}
}

func TestMonitorDebouncesFilesystemChanges(t *testing.T) {
	root := t.TempDir()
	calls := make(chan string, 8)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	monitor := &Monitor{
		Root: root, Interval: time.Hour, Debounce: 40 * time.Millisecond,
		Logger: slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		Scan: func(_ context.Context, reason string) error {
			calls <- reason
			return nil
		},
	}
	go func() { done <- monitor.Run(ctx) }()
	select {
	case reason := <-calls:
		if reason != "startup_reconciliation" {
			t.Fatalf("startup scan reason = %q", reason)
		}
	case <-time.After(time.Second):
		cancel()
		<-done
		t.Fatal("startup scan did not run")
	}
	waitForWatch(t, monitor, root)
	if err := os.WriteFile(filepath.Join(root, "new-course.mp4"), []byte("media"), 0o600); err != nil {
		cancel()
		<-done
		t.Fatal(err)
	}
	select {
	case reason := <-calls:
		if reason != "filesystem_change" {
			t.Fatalf("change scan reason = %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("filesystem change did not trigger a scan")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
