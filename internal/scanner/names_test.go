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
