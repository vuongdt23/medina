package indexer

import (
	"testing"
	"time"
)

func TestWatchDirectoryEnqueueDoesNotBlockOnFullQueue(t *testing.T) {
	m := &Monitor{watchQueue: make(chan string, 1), watchPending: make(map[string]bool), watched: make(map[string]bool)}
	done := make(chan struct{})
	go func() { m.WatchDirectory("first"); m.WatchDirectory("first"); m.WatchDirectory("second"); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("scanner blocked on watch registration queue")
	}
	if len(m.watchQueue) != 1 || !m.watchPending["first"] || m.watchPending["second"] {
		t.Fatal("queue did not deduplicate or bound registration work")
	}
}
