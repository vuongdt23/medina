package indexer

import (
	"context"
	"errors"
	"sync"
)

// Coordinator runs at most one library scan at a time. Scan jobs use the
// application context supplied by the caller, never an HTTP request context.
type Coordinator struct {
	RunScan func(context.Context, string) error
	mu      sync.Mutex
	job     *scanJob
}

type scanJob struct {
	done     chan error
	finished chan struct{}
	err      error // published by closing finished; safe for multiple waiters
	rejected bool
}

// Submit starts a scan if none is running. Duplicate submissions return the
// existing job's result channel. Background reconciliation should use Wait.
func (c *Coordinator) Submit(ctx context.Context, reason string) (bool, <-chan error) {
	started, job := c.submit(ctx, reason)
	return started, job.done
}

func (c *Coordinator) submit(ctx context.Context, reason string) (bool, *scanJob) {
	c.mu.Lock()
	defer c.mu.Unlock()
	failed := func(err error) (bool, *scanJob) {
		job := &scanJob{done: make(chan error, 1), finished: make(chan struct{}), err: err, rejected: true}
		job.done <- err
		close(job.done)
		close(job.finished)
		return false, job
	}
	if err := ctx.Err(); err != nil {
		return failed(err)
	}
	if c.job != nil {
		select {
		case <-c.job.finished:
		default:
			return false, c.job
		}
	}
	if c.RunScan == nil {
		return failed(errors.New("scan coordinator has no scan function"))
	}
	job := &scanJob{done: make(chan error, 1), finished: make(chan struct{})}
	c.job = job
	go func() {
		job.err = c.RunScan(ctx, reason)
		job.done <- job.err
		close(job.done)
		close(job.finished)
	}()
	return true, job
}

// Wait runs a fresh reconciliation after any existing job has finished. Merely
// joining an older scan can miss changes to directories it already enumerated.
func (c *Coordinator) Wait(ctx context.Context, reason string) error {
	for {
		started, job := c.submit(ctx, reason)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-job.finished:
		}
		if started {
			return job.err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if job.rejected {
			return job.err
		}
	}
}

// WaitForIdle joins actual scan completion, even if Wait returned on
// cancellation. Call after cancelling the application context, so new jobs
// cannot start while shutdown waits for filesystem syscalls and cleanup.
func (c *Coordinator) WaitForIdle() {
	c.mu.Lock()
	job := c.job
	c.mu.Unlock()
	if job != nil {
		<-job.finished
	}
}
