package scanner

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDottedDirectoryTitlesPreserveNames(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "ASP.NET Core", "01. Introduction", "01. Welcome.mp4")
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("media"), 0644); err != nil {
		t.Fatal(err)
	}
	result, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"ASP.NET Core": "ASP.NET Core", "01. Introduction": "Introduction", "01. Welcome.mp4": "Welcome"}
	for _, item := range result.Items {
		expected, ok := want[item.OriginalName]
		if !ok {
			t.Fatalf("unexpected item %+v", item)
		}
		if item.Title != expected {
			t.Errorf("%s: title=%q want=%q", item.OriginalName, item.Title, expected)
		}
		delete(want, item.OriginalName)
	}
	if len(want) != 0 {
		t.Fatalf("missing items: %v", want)
	}
}

func TestUnderscoreSubtitleAndCompactNumericPrefixes(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"Course/01-Welcome/001 Welcome to Data Engineering Essentials.mp4":    "video",
		"Course/01-Welcome/001 Welcome to Data Engineering Essentials_en.srt": "subtitle",
		"Course/02_Architecture/01_Overview.mp4":                              "video",
	}
	for rel, content := range files {
		path := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	result, err := Scan(root)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]Item{}
	for _, it := range result.Items {
		byName[it.OriginalName] = it
	}
	if got := byName["01-Welcome"].Title; got != "Welcome" {
		t.Errorf("01-Welcome title = %q, want Welcome", got)
	}
	if got := byName["02_Architecture"].Title; got != "Architecture" {
		t.Errorf("02_Architecture title = %q, want Architecture", got)
	}
	if got := byName["01_Overview.mp4"].Title; got != "Overview" {
		t.Errorf("01_Overview.mp4 title = %q, want Overview", got)
	}
	lesson := byName["001 Welcome to Data Engineering Essentials.mp4"]
	sub := byName["001 Welcome to Data Engineering Essentials_en.srt"]
	if sub.LessonID != lesson.ID || sub.SubtitleFor != lesson.ID || sub.ParentID != lesson.ID {
		t.Fatalf("underscore subtitle not associated with lesson: sub=%+v lesson=%+v", sub, lesson)
	}
}

