package indexer

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestCoordinatorAllowsOnlyOneScanAtATime(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	coordinator := &Coordinator{RunScan: func(ctx context.Context, reason string) error {
		calls.Add(1)
		close(started)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	accepted, firstDone := coordinator.Submit(ctx, "manual")
	if !accepted {
		t.Fatal("first scan was not accepted")
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("scan did not start")
	}
	accepted, secondDone := coordinator.Submit(ctx, "manual")
	if accepted {
		t.Fatal("second scan accepted while one is running")
	}
	if firstDone != secondDone {
		t.Fatal("second submit did not join the running job")
	}
	if calls.Load() != 1 {
		t.Fatalf("scan function called %d times", calls.Load())
	}
	close(release)
	select {
	case err := <-firstDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("scan did not complete")
	}
}

func TestCoordinatorJobUsesApplicationContextNotCallerContext(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	coordinator := &Coordinator{RunScan: func(ctx context.Context, _ string) error {
		close(started)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	appCtx, cancelApp := context.WithCancel(context.Background())
	defer cancelApp()
	_, cancelRequest := context.WithCancel(context.Background())
	accepted, done := coordinator.Submit(appCtx, "manual")
	if !accepted {
		t.Fatal("scan was not accepted")
	}
	<-started
	cancelRequest()
	select {
	case err := <-done:
		t.Fatalf("request cancellation stopped the scan: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
