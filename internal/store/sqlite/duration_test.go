package sqlite

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"medina/internal/scanner"
)

func TestCourseItemsRestrictsReadToCourseSubtree(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	for name, content := range map[string]string{
		"Course A/Section/notes.txt": "a",
		"Course B/Section/notes.txt": "b",
	} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	store, err := Open(filepath.Join(t.TempDir(), "course-items.sqlite"))
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
	all, err := store.Items(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var courseA string
	for _, item := range all {
		if item.Type == "course" && item.OriginalName == "Course A" {
			courseA = item.ID
		}
	}
	if courseA == "" {
		t.Fatal("Course A was not indexed")
	}
	got, err := store.CourseItems(ctx, "library_default", courseA)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("CourseItems returned %d entries, want the course, section directory, and asset", len(got))
	}
	for _, item := range got {
		if item.RelativePath != "Course A" && !strings.HasPrefix(item.RelativePath, "Course A/") {
			t.Errorf("CourseItems leaked other course entry %q", item.RelativePath)
		}
	}
	missing, err := store.CourseItems(ctx, "library_default", "missing-course")
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		t.Fatalf("unknown course returned %d entries", len(missing))
	}

	var generation string
	if err := store.DB.QueryRowContext(ctx, `SELECT active_generation_id FROM library_roots WHERE id=?`, "library_default").Scan(&generation); err != nil {
		t.Fatal(err)
	}
	plan, err := store.DB.QueryContext(ctx, "EXPLAIN QUERY PLAN "+courseItemsQuery, generation, courseA, generation, generation)
	if err != nil {
		t.Fatal(err)
	}
	defer plan.Close()
	usesParentIndex := false
	for plan.Next() {
		var id, parent, unused int
		var detail string
		if err := plan.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(detail, "USING INDEX entry_parent_idx") {
			usesParentIndex = true
		}
	}
	if err := plan.Err(); err != nil {
		t.Fatal(err)
	}
	if !usesParentIndex {
		t.Fatal("course item recursion did not use entry_parent_idx")
	}
}

func TestParseMediaDuration(t *testing.T) {
	for _, tc := range []struct {
		input string
		want  float64
	}{{"123.5\n", 123.5}, {"0", 0}, {"N/A", 0}, {"NaN", 0}, {"Inf", 0}} {
		if got := parseMediaDuration([]byte(tc.input)); got != tc.want {
			t.Errorf("parseMediaDuration(%q) = %v, want %v", tc.input, got, tc.want)
		}
	}
}

func TestScanRetainsCachedDurationForUnchangedLesson(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "lesson.mp4"), []byte("not real media"), 0o644); err != nil {
		t.Fatal(err)
	}
	store, err := Open(filepath.Join(t.TempDir(), "durations.sqlite"))
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
	for _, item := range items {
		if item.Type == "lesson" {
			lessonID = item.ID
		}
	}
	if lessonID == "" {
		t.Fatal("lesson was not indexed")
	}
	if _, err := store.DB.ExecContext(ctx, `UPDATE entry_snapshots SET duration_seconds=? WHERE generation_id=(SELECT active_generation_id FROM library_roots WHERE id=?) AND item_id=?`, 98.25, "library_default", lessonID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Scan(ctx, "library_default", root); err != nil {
		t.Fatal(err)
	}
	items, err = store.Items(ctx, "library_default")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if item.ID == lessonID {
			if item.DurationSeconds != 98.25 {
				t.Fatalf("cached duration after unchanged rescan = %v, want 98.25", item.DurationSeconds)
			}
			return
		}
	}
	t.Fatal("lesson disappeared from index")
}

func TestScanIndexesMediaDurationWhenFFmpegIsAvailable(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	ctx := context.Background()
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	mediaPath := filepath.Join(course, "lesson.wav")
	cmd := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:duration=2", "-c:a", "pcm_s16le", mediaPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("create test media: %v: %s", err, output)
	}
	store, err := Open(filepath.Join(t.TempDir(), "media-duration.sqlite"))
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
	for _, item := range items {
		if item.Type == "lesson" {
			if item.DurationSeconds < 1.9 || item.DurationSeconds > 2.1 {
				t.Fatalf("probed lesson duration = %v, want approximately 2 seconds", item.DurationSeconds)
			}
			return
		}
	}
	t.Fatal("lesson was not indexed")
}

func TestReuseLessonDurationOnlyWhenSourceIsUnchanged(t *testing.T) {
	modified := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	previous := map[string]scanner.Item{
		"lesson": {ID: "lesson", Type: "lesson", SizeBytes: 100, ModifiedAt: modified, DurationSeconds: 98.25},
	}
	unchanged := scanner.Item{ID: "lesson", Type: "lesson", SizeBytes: 100, ModifiedAt: modified}
	reuseLessonDuration(&unchanged, previous)
	if unchanged.DurationSeconds != 98.25 {
		t.Fatalf("unchanged lesson duration = %v, want 98.25", unchanged.DurationSeconds)
	}
	changed := scanner.Item{ID: "lesson", Type: "lesson", SizeBytes: 101, ModifiedAt: modified}
	reuseLessonDuration(&changed, previous)
	if changed.DurationSeconds != 0 {
		t.Fatalf("changed lesson reused stale duration %v", changed.DurationSeconds)
	}
}
