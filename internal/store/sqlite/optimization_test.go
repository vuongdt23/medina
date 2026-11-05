package sqlite

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"medina/internal/scanner"
)

func TestUnchangedRescanSkipsWritesAndKeepsCanonicalLinks(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	section := filepath.Join(root, "Course", "Section")
	if err := os.MkdirAll(section, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"01.mp4", "01.en.srt", "01.pdf"} {
		if err := os.WriteFile(filepath.Join(section, name), []byte("data"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	s, err := Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.EnsureLibrary(ctx, "lib", "Test", root); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Scan(ctx, "lib", root); err != nil {
		t.Fatal(err)
	}
	written := 0
	if _, err = s.ScanWithProgress(ctx, "lib", root, func(n int) error { written = n; return nil }); err != nil {
		t.Fatal(err)
	}
	if written != 0 {
		t.Fatalf("unchanged rescan wrote %d scanner records", written)
	}
	status, err := s.Status(ctx, "lib")
	if err != nil {
		t.Fatal(err)
	}
	p := status["progress"].(scanner.Progress)
	if p.Phase != "complete" || p.EntriesVisited != 5 {
		t.Fatalf("unexpected progress: %+v", p)
	}
	// Replace a file in place with a different inode, then rename it. This
	// exercises canonical replacement, reference repair, and stable identity.
	replacement := filepath.Join(section, "new.tmp")
	if err = os.WriteFile(replacement, []byte("replacement"), 0644); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(replacement, filepath.Join(section, "01.mp4")); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Scan(ctx, "lib", root); err != nil {
		t.Fatal(err)
	}
	items, err := s.Items(ctx, "lib")
	if err != nil {
		t.Fatal(err)
	}
	lessonID := ""
	for _, item := range items {
		if item.Type == "lesson" {
			lessonID = item.ID
		}
	}
	for _, item := range items {
		if item.Type == "subtitle" || item.Type == "asset" {
			if item.ParentID != lessonID {
				t.Fatalf("stale sidecar link: %+v", item)
			}
		}
	}
	if err = os.Rename(filepath.Join(section, "01.mp4"), filepath.Join(section, "02.mp4")); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Scan(ctx, "lib", root); err != nil {
		t.Fatal(err)
	}
	items, err = s.Items(ctx, "lib")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if item.Type == "lesson" && item.ID != lessonID {
			t.Fatal("rename lost identity")
		}
		if item.Type == "subtitle" && item.LessonID != "" {
			t.Fatal("renamed lesson retained mismatched association")
		}
	}
}
