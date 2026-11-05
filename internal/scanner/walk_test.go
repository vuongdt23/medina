package scanner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestWorkerCountsProduceIdenticalItemsAndProgress(t *testing.T) {
	root := t.TempDir()
	for _, path := range []string{"Course/Section/01.mp4", "Course/Section/01.en.srt", "Course/Section/01.pdf", "Course/assets/code.go", "Loose.mp4", "Course/.DS_Store", "Course/partial.mp4.part"} {
		path = filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("data"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Link(filepath.Join(root, "Course/Section/01.mp4"), filepath.Join(root, "Course/Section/02.mp4")); err != nil {
		t.Fatal(err)
	}
	serial, err := ScanWithOptions(context.Background(), root, Options{Workers: 1, DirectoryWorkers: 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var latest Progress
	directories := make(map[string]bool)
	parallel, err := ScanWithOptions(context.Background(), root, Options{Workers: 8, DirectoryWorkers: 4, OnProgress: func(p Progress) {
		if p.EntriesVisited < latest.EntriesVisited {
			t.Fatal("visited count went backwards")
		}
		latest = p
	}, OnDirectory: func(path string) { directories[path] = true }}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(serial, parallel) {
		t.Fatalf("worker count changed scan results\nserial=%+v\nparallel=%+v", serial, parallel)
	}
	if latest.EntriesVisited != 11 {
		t.Fatalf("visited=%d; expected 11 entries including ignored files", latest.EntriesVisited)
	}
	if len(directories) != 4 {
		t.Fatalf("directories=%v", directories)
	}
}

func TestScanCancellationStopsTraversal(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "Course"), 0755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	_, err := ScanWithOptions(ctx, root, Options{OnDirectory: func(string) { cancel() }}, nil)
	if err == nil {
		t.Fatal("cancelled traversal succeeded")
	}
}

func BenchmarkScanLocalMetadata(b *testing.B) {
	root := b.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.Mkdir(course, 0755); err != nil {
		b.Fatal(err)
	}
	for i := 0; i < 1000; i++ {
		if err := os.WriteFile(filepath.Join(course, fmt.Sprintf("%04d.mp4", i)), nil, 0644); err != nil {
			b.Fatal(err)
		}
	}
	for _, workers := range []int{1, 8} {
		b.Run(fmt.Sprintf("workers-%d", workers), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := ScanWithOptions(context.Background(), root, Options{Workers: workers}, nil); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
