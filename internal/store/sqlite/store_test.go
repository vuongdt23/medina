package sqlite

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestScanPersistsDiscoveredBatchesBeforeCompletion(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 140; i++ {
		name := filepath.Join(course, fmt.Sprintf("lesson-%03d.mp4", i))
		if err := os.WriteFile(name, []byte("video"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	store, err := Open(filepath.Join(t.TempDir(), "incremental.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.EnsureLibrary(ctx, "library_default", "Test", root); err != nil {
		t.Fatal(err)
	}
	var observed int
	_, err = store.ScanWithProgress(ctx, "library_default", root, func(processed int) error {
		status, err := store.Status(ctx, "library_default")
		if err != nil {
			return err
		}
		count := status["itemCount"].(int)
		if status["state"] != "scanning" || count == 0 {
			return fmt.Errorf("expected persisted partial scan, status=%v", status)
		}
		if count > observed {
			observed = count
		}
		if processed < 64 {
			return fmt.Errorf("unexpected batch progress count %d", processed)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if observed < 128 {
		t.Fatalf("scan did not persist a substantial partial batch: %d", observed)
	}
	status, err := store.Status(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	if status["state"] != "idle" || status["itemCount"] != 141 {
		t.Fatalf("unexpected completed scan status: %v", status)
	}
}

func TestScanPublishesGenerationAndKeepsPreviousOnFailure(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "Lesson.mp4"), []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	store, err := Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err = store.EnsureLibrary(ctx, "library_default", "Test", root); err != nil {
		t.Fatal(err)
	}
	first, err := store.Scan(ctx, "library_default", root)
	if err != nil {
		t.Fatal(err)
	}
	if first == "" {
		t.Fatal("expected generation id")
	}
	items, err := store.Items(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("got %d indexed items", len(items))
	}
	if _, err = store.Scan(ctx, "library_default", filepath.Join(root, "missing")); err == nil {
		t.Fatal("expected missing-root scan to fail")
	}
	status, err := store.Status(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	if status["activeGenerationId"] != first {
		t.Fatalf("failed scan replaced generation: %v", status)
	}
	if status["state"] != "failed" {
		t.Fatalf("unexpected scan state: %v", status["state"])
	}
}

func TestLessonProgressUpsertIsIdempotentAndProfileScoped(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "lesson.mp4"), []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	store, err := Open(filepath.Join(t.TempDir(), "progress-store.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.EnsureLibrary(ctx, "library_default", "Test", root); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Scan(ctx, "library_default", root); err != nil {
		t.Fatal(err)
	}
	items, err := store.Items(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var lessonID string
	for _, it := range items {
		if it.Type == "lesson" {
			lessonID = it.ID
		}
	}
	if lessonID == "" {
		t.Fatal("lesson not indexed")
	}

	if err := store.UpsertLessonProgress(ctx, "library_default", "p1", LessonProgress{ItemID: lessonID, PositionSeconds: 10}); err != nil {
		t.Fatal(err)
	}
	// A second upsert replaces rather than duplicating.
	if err := store.UpsertLessonProgress(ctx, "library_default", "p1", LessonProgress{ItemID: lessonID, PositionSeconds: 55, Completed: true}); err != nil {
		t.Fatal(err)
	}
	all, err := store.AllLessonProgress(ctx, "library_default", "p1")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 {
		t.Fatalf("expected 1 row after repeated upsert, got %d", len(all))
	}
	rec, ok, err := store.LessonProgressFor(ctx, "library_default", "p1", lessonID)
	if err != nil || !ok {
		t.Fatalf("expected stored record, ok=%v err=%v", ok, err)
	}
	if rec.PositionSeconds != 55 || !rec.Completed {
		t.Fatalf("upsert did not replace values: %+v", rec)
	}

	// A different profile is isolated.
	if _, ok, err := store.LessonProgressFor(ctx, "library_default", "p2", lessonID); err != nil || ok {
		t.Fatalf("expected no record for p2, ok=%v err=%v", ok, err)
	}
}
