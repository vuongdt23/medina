package indexer

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestCoordinatorShutdownWaitsForActualScanCleanup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{})
	release := make(chan struct{})
	cleaned := make(chan struct{})
	coordinator := &Coordinator{RunScan: func(context.Context, string) error {
		close(started)
		<-release // simulate a filesystem syscall that cannot be canceled
		close(cleaned)
		return context.Canceled
	}}
	waiter := make(chan error, 1)
	go func() { waiter <- coordinator.Wait(ctx, "startup") }()
	<-started
	cancel()
	if err := <-waiter; err != context.Canceled {
		t.Fatalf("waiter error=%v", err)
	}
	idle := make(chan struct{})
	go func() { coordinator.WaitForIdle(); close(idle) }()
	select {
	case <-idle:
		t.Fatal("shutdown joined canceled waiter, not scan cleanup")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case <-idle:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not finish")
	}
	select {
	case <-cleaned:
	default:
		t.Fatal("cleanup not completed before shutdown")
	}
	if accepted, _ := coordinator.Submit(ctx, "manual"); accepted {
		t.Fatal("canceled application accepted a new scan")
	}
}

func TestMonitorReconcilesChangesAfterManualScan(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manualStarted := make(chan struct{})
	release := make(chan struct{})
	reconciled := make(chan struct{})
	startupFinished := make(chan struct{})
	scheduled := make(chan string, 8)
	var calls atomic.Int32
	coordinator := &Coordinator{RunScan: func(ctx context.Context, reason string) error {
		calls.Add(1)
		switch reason {
		case "manual":
			close(manualStarted)
			select {
			case <-release:
			case <-ctx.Done():
				return ctx.Err()
			}
		case "filesystem_change":
			close(reconciled)
		}
		return nil
	}}
	monitor := &Monitor{Root: root, Interval: time.Hour, Debounce: 20 * time.Millisecond, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Scan: func(ctx context.Context, reason string) error {
		scheduled <- reason
		err := coordinator.Wait(ctx, reason)
		if reason == "startup_reconciliation" {
			close(startupFinished)
		}
		return err
	}}
	done := make(chan error, 1)
	go func() { done <- monitor.Run(ctx) }()
	defer func() { cancel(); <-done; coordinator.WaitForIdle() }()
	select {
	case <-startupFinished:
	case <-time.After(time.Second):
		t.Fatal("startup did not finish")
	}
	waitForWatch(t, monitor, root)
	<-scheduled // startup scheduling notification
	if accepted, _ := coordinator.Submit(ctx, "manual"); !accepted {
		t.Fatal("manual scan rejected")
	}
	<-manualStarted
	if err := os.WriteFile(filepath.Join(root, "changed.txt"), []byte("changed after traversal"), 0644); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-scheduled:
		if reason != "filesystem_change" {
			t.Fatalf("reason=%s", reason)
		}
	case <-time.After(time.Second):
		t.Fatal("change was not scheduled")
	}
	// Give the monitor waiter time to join the blocked job. A fresh scan must
	// follow it, not count the manual job as the requested reconciliation.
	time.Sleep(20 * time.Millisecond)
	close(release)
	select {
	case <-reconciled:
	case <-time.After(time.Second):
		t.Fatal("filesystem change was lost during manual scan")
	}
	if calls.Load() < 3 {
		t.Fatalf("scans=%d", calls.Load())
	}
}

func TestCoordinatorWaitRejectsMissingScanFunction(t *testing.T) {
	coordinator := &Coordinator{}
	if err := coordinator.Wait(context.Background(), "manual"); err == nil {
		t.Fatal("missing scan function accepted")
	}
	coordinator.WaitForIdle()
}
