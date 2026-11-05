package scanner

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScanWithProgressEmitsProvisionalAndCanonicalBatches(t *testing.T) {
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "Lesson.mp4"), []byte("video"), 0o644); err != nil {
		t.Fatal(err)
	}
	var batches [][]Item
	var provisional bool
	result, err := ScanWithProgress(root, func(batch []Item, canonical bool) error {
		copyBatch := append([]Item(nil), batch...)
		if canonical {
			batches = append(batches, copyBatch)
		} else {
			provisional = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !provisional || len(batches) == 0 {
		t.Fatalf("expected provisional and canonical batches, provisional=%v canonical=%d", provisional, len(batches))
	}
	if batches[0][0].Type != "course" {
		t.Fatalf("provisional first item type = %q", batches[0][0].Type)
	}
	var canonicalLesson bool
	for _, item := range batches[len(batches)-1] {
		if item.OriginalName == "Lesson.mp4" && item.Type == "lesson" {
			canonicalLesson = true
		}
	}
	if !canonicalLesson || len(result.Items) != 2 {
		t.Fatalf("canonical result did not include course and lesson: %+v", result.Items)
	}
}

func TestScanBuildsCourseSectionsLessonsAndSidecars(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"Go Basics/01 - Intro/02 - Second.mp4":   "video",
		"Go Basics/01 - Intro/01 - First.mp4":    "video",
		"Go Basics/01 - Intro/01 - First.en.srt": "subtitle",
		"Go Basics/01 - Intro/01 - First.pdf":    "slides",
		"Go Basics/01 - Intro/examples/main.go":  "code",
		"Loose.mp4":                              "not-a-course",
	}
	for name, contents := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	result, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]Item{}
	for _, item := range result.Items {
		byName[item.OriginalName] = item
	}
	course, ok := byName["Go Basics"]
	if !ok || course.Type != "course" {
		t.Fatalf("course missing or wrong: %+v", course)
	}
	section, ok := byName["01 - Intro"]
	if !ok || section.Type != "section" || section.ParentID != course.ID {
		t.Fatalf("section wrong: %+v", section)
	}
	first, ok := byName["01 - First.mp4"]
	if !ok || first.Type != "lesson" || first.Title != "First" {
		t.Fatalf("lesson wrong: %+v", first)
	}
	subtitle, ok := byName["01 - First.en.srt"]
	if !ok || subtitle.Type != "subtitle" || subtitle.LessonID != first.ID || subtitle.ParentID != first.ID {
		t.Fatalf("subtitle not associated: %+v", subtitle)
	}
	asset, ok := byName["01 - First.pdf"]
	if !ok || asset.Type != "asset" || asset.LessonID != first.ID {
		t.Fatalf("asset not associated: %+v", asset)
	}
	if _, ok := byName["Loose.mp4"]; ok {
		t.Fatal("root-level media should remain unclassified")
	}
	second := byName["02 - Second.mp4"]
	if first.Position >= second.Position {
		t.Fatalf("natural ordering failed: first=%d second=%d", first.Position, second.Position)
	}
}

func TestFileIdentitySurvivesRename(t *testing.T) {
	root := t.TempDir()
	oldPath := filepath.Join(root, "Course", "lesson.mp4")
	if err := os.MkdirAll(filepath.Dir(oldPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(oldPath, []byte("media"), 0o644); err != nil {
		t.Fatal(err)
	}
	before, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(oldPath, filepath.Join(root, "Course", "renamed.mp4")); err != nil {
		t.Fatal(err)
	}
	after, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	var beforeID, afterID string
	for _, item := range before.Items {
		if item.Type == "lesson" {
			beforeID = item.ID
		}
	}
	for _, item := range after.Items {
		if item.Type == "lesson" {
			afterID = item.ID
		}
	}
	if beforeID == "" || beforeID != afterID {
		t.Fatalf("identity changed across rename: before=%q after=%q", beforeID, afterID)
	}
}

func TestScanIgnoresJunkAndSymlinks(t *testing.T) {
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, ".DS_Store"), []byte("junk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "._.DS_Store"), []byte("AppleDouble metadata"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "unfinished.mp4.part"), []byte("junk"), 0o644); err != nil {
		t.Fatal(err)
	}
	external := t.TempDir()
	if err := os.WriteFile(filepath.Join(external, "secret.mp4"), []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, filepath.Join(course, "escape")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	result, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 1 || result.Items[0].Type != "course" {
		t.Fatalf("unexpected indexed items: %+v", result.Items)
	}
	if len(result.Ignored) != 4 {
		t.Fatalf("expected junk, AppleDouble metadata, and symlink diagnostics; got %v", result.Ignored)
	}
}
