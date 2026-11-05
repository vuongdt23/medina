package scanner

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDirectoryReadsOverlapAndMetadataHasGlobalLimit(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 8; i++ {
		dir := filepath.Join(root, "Course", fmt.Sprintf("Section-%02d", i))
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
		for j := 0; j < 8; j++ {
			if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%02d.mp4", j)), nil, 0644); err != nil {
				t.Fatal(err)
			}
		}
	}
	var activeDirs, maxDirs, activeStats, maxStats atomic.Int32
	updateMax := func(max *atomic.Int32, value int32) {
		for old := max.Load(); value > old; old = max.Load() {
			if max.CompareAndSwap(old, value) {
				break
			}
		}
	}
	second := make(chan struct{})
	var once sync.Once
	filesystem := walkFS{
		readNames: func(path string) ([]string, error) {
			active := activeDirs.Add(1)
			updateMax(&maxDirs, active)
			defer activeDirs.Add(-1)
			name := filepath.Base(path)
			if name == "Section-01" {
				once.Do(func() { close(second) })
			}
			if name == "Section-00" {
				select {
				case <-second:
				case <-time.After(2 * time.Second):
					return nil, fmt.Errorf("sibling directory was not enumerated concurrently")
				}
			}
			return readNames(path)
		},
		lstat: func(path string) (fs.FileInfo, error) {
			active := activeStats.Add(1)
			updateMax(&maxStats, active)
			defer activeStats.Add(-1)
			time.Sleep(2 * time.Millisecond)
			return os.Lstat(path)
		},
	}
	p := Progress{}
	err := walkMetadataWithFS(context.Background(), root, Options{Workers: 3, DirectoryWorkers: 2}, &p, func() {}, func(string, fs.DirEntry, error) error { return nil }, filesystem)
	if err != nil {
		t.Fatal(err)
	}
	if maxDirs.Load() != 2 {
		t.Fatalf("directory concurrency=%d", maxDirs.Load())
	}
	if maxStats.Load() < 2 || maxStats.Load() > 3 {
		t.Fatalf("global metadata concurrency=%d; want 2–3", maxStats.Load())
	}
	if p.ActiveDirectoryReads != 0 || p.ActiveMetadataReads != 0 {
		t.Fatalf("active workers retained after completion: %+v", p)
	}
}

func TestSlowListingEmitsHeartbeatAndIgnoresNamesBeforeStat(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"Course/.git/deep", "Course/.pad.part/deep", "Course/assets"} {
		if err := os.MkdirAll(filepath.Join(root, name), 0755); err != nil {
			t.Fatal(err)
		}
	}
	p := Progress{}
	heartbeats := 0
	filesystem := walkFS{
		readNames: func(path string) ([]string, error) {
			if path == root {
				time.Sleep(600 * time.Millisecond)
			}
			return readNames(path)
		},
		lstat: func(path string) (fs.FileInfo, error) {
			if strings.Contains(path, ".git") || strings.Contains(path, ".pad.part") {
				return nil, fmt.Errorf("ignored path was statted: %s", path)
			}
			return os.Lstat(path)
		},
	}
	err := walkMetadataWithFS(context.Background(), root, Options{DirectoryWorkers: 2}, &p, func() {
		if p.CurrentOperation == "listing" && p.ActiveDirectoryReads > 0 && p.EnumerationMS >= 200 {
			heartbeats++
		}
	}, func(_ string, _ fs.DirEntry, err error) error { return err }, filesystem)
	if err != nil {
		t.Fatal(err)
	}
	if heartbeats < 1 {
		t.Fatal("no live progress while listing was blocked")
	}
	if p.DirectoriesRead != 3 {
		t.Fatalf("ignored directories enumerated: %+v", p)
	}
}

func TestParallelPrefetchPreservesWideAndDeepTraversal(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 80; i++ {
		path := filepath.Join(root, "Course", fmt.Sprintf("Section-%03d", i), "lesson.mp4")
		if i == 0 {
			path = filepath.Join(root, "Course", "Section-000", "a", "b", "c", "d", "e", "lesson.mp4")
		}
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, 0644); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	serial, err := ScanWithOptions(ctx, root, Options{Workers: 1, DirectoryWorkers: 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	parallel, err := ScanWithOptions(ctx, root, Options{Workers: 8, DirectoryWorkers: 4}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(serial, parallel) {
		t.Fatal("bounded prefetch changed traversal or IDs")
	}
}

func BenchmarkNestedDirectoryEnumeration(b *testing.B) {
	root := b.TempDir()
	for i := 0; i < 24; i++ {
		if err := os.MkdirAll(filepath.Join(root, "Course", fmt.Sprintf("Section-%02d", i)), 0755); err != nil {
			b.Fatal(err)
		}
	}
	filesystem := walkFS{readNames: func(path string) ([]string, error) { time.Sleep(2 * time.Millisecond); return readNames(path) }, lstat: os.Lstat}
	for _, workers := range []int{1, 4} {
		b.Run(fmt.Sprintf("directories-%d", workers), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				p := Progress{}
				if err := walkMetadataWithFS(context.Background(), root, Options{Workers: 8, DirectoryWorkers: workers}, &p, func() {}, func(_ string, _ fs.DirEntry, err error) error { return err }, filesystem); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
