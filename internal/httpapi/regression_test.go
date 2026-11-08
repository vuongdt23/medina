package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"medina/internal/config"
	"medina/internal/store/sqlite"
)

func regressionServer(t *testing.T, files map[string]string) (*Server, *sqlite.Store, string) {
	t.Helper()
	root := t.TempDir()
	for name, contents := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0644); err != nil {
			t.Fatal(err)
		}
	}
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	server, err := New(config.Config{ContentRoot: root, LibraryName: "Test"}, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Scan(context.Background(), "library_default", root); err != nil {
		t.Fatal(err)
	}
	return server, store, root
}

func TestMedinaBranding(t *testing.T) {
	server, _, _ := regressionServer(t, nil)
	for _, test := range []struct{ path, contains string }{
		{"/api/v1/system/info", `"name":"Medina"`},
		{"/swagger/", "<title>Medina API"},
		{"/openapi.yaml", "title: Medina API"},
		{"/", "<title>Medina · Debug</title>"},
	} {
		rec := httptest.NewRecorder()
		server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", test.path, nil))
		if !frontendBundled && (test.path == "/" || test.path == "/swagger/") {
			if rec.Code != http.StatusNotFound {
				t.Errorf("%s: frontend served in API-only build: status=%d", test.path, rec.Code)
			}
			continue
		}
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), test.contains) {
			t.Errorf("%s: expected Medina branding, status=%d", test.path, rec.Code)
		}
	}
}

func TestActiveDocumentsAreDownloadOnly(t *testing.T) {
	files := map[string]string{}
	for _, ext := range []string{"html", "htm", "HTM", "xhtml", "xht", "svg"} {
		files["Course/unsafe."+ext] = "<script>alert(document.origin)</script>"
	}
	server, store, _ := regressionServer(t, files)
	items, err := store.Items(context.Background(), "library_default")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if item.Type != "asset" {
			continue
		}
		t.Run(item.OriginalName, func(t *testing.T) {
			for _, suffix := range []string{"content", "download"} {
				rec := httptest.NewRecorder()
				server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/assets/"+item.ID+"/"+suffix, nil))
				if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment") || rec.Header().Get("Content-Security-Policy") == "" {
					t.Fatalf("unsafe response: status=%d headers=%v", rec.Code, rec.Header())
				}
			}
			rec := httptest.NewRecorder()
			server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/assets/"+item.ID+"/preview", nil))
			if rec.Code != http.StatusUnsupportedMediaType {
				t.Fatalf("preview status=%d", rec.Code)
			}
		})
	}
	// MIME parameters must not bypass the active-document check.
	if previewable("text/html; charset=utf-8", ".unknown") || previewable("image/svg+xml; charset=utf-8", ".unknown") {
		t.Fatal("parameterized active MIME type allowed")
	}
}

func TestPreviewableAllowsCodeAndImagesByExtensionWhenMimeIsUnknown(t *testing.T) {
	// The OS mime database is incomplete, so source and image files frequently
	// arrive as application/octet-stream. They must still preview by extension.
	for _, ext := range []string{".kt", ".swift", ".rb", ".php", ".c", ".cpp", ".lua", ".toml"} {
		if !previewable("application/octet-stream", ext) {
			t.Errorf("code %s should be previewable with unknown mime", ext)
		}
	}
	for _, ext := range []string{".png", ".webp", ".avif", ".heic", ".tiff"} {
		if !previewable("application/octet-stream", ext) {
			t.Errorf("image %s should be previewable with unknown mime", ext)
		}
	}
	// HTML/SVG remain blocked on /preview (served via /content, sandboxed).
	if previewable("text/html", ".html") || previewable("image/svg+xml", ".svg") {
		t.Error("active documents must not be previewable")
	}
	// Genuinely opaque binaries stay unsupported.
	if previewable("application/octet-stream", ".bin") {
		t.Error(".bin should not be previewable")
	}
}

func TestAssetTreeSerializesEachItemOnce(t *testing.T) {
	name := "Course/" + strings.Repeat("nested/", 12) + "leaf.txt"
	server, store, _ := regressionServer(t, map[string]string{name: "hello"})
	items, err := store.Items(context.Background(), "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var courseID string
	for _, item := range items {
		if item.Type == "course" {
			courseID = item.ID
		}
	}
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/courses/"+courseID+"/tree", nil))
	if rec.Code != 200 {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	for _, item := range items {
		if count := strings.Count(rec.Body.String(), `"id":"`+item.ID+`"`); count != 1 {
			t.Errorf("%s serialized %d times", item.RelativePath, count)
		}
	}
	if rec.Body.Len() > 16000 {
		t.Fatalf("unexpectedly large tree: %d bytes", rec.Body.Len())
	}
}

func TestCourseTreeIncludesCachedLessonDuration(t *testing.T) {
	server, store, _ := regressionServer(t, map[string]string{"Course/lesson.mp4": "not real media"})
	items, err := store.Items(context.Background(), "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var courseID, lessonID string
	for _, item := range items {
		switch item.Type {
		case "course":
			courseID = item.ID
		case "lesson":
			lessonID = item.ID
		}
	}
	if courseID == "" || lessonID == "" {
		t.Fatalf("missing indexed course or lesson: course=%q lesson=%q", courseID, lessonID)
	}
	if _, err := store.DB.ExecContext(context.Background(), `UPDATE entry_snapshots SET duration_seconds=? WHERE generation_id=(SELECT active_generation_id FROM library_roots WHERE id=?) AND item_id=?`, 123.5, "library_default", lessonID); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/courses/"+courseID+"/tree", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var tree map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &tree); err != nil {
		t.Fatal(err)
	}
	lessons := tree["lessons"].([]any)
	lesson := lessons[0].(map[string]any)
	if lesson["durationSeconds"] != 123.5 {
		t.Fatalf("tree durationSeconds = %v, want 123.5: %s", lesson["durationSeconds"], rec.Body.String())
	}
}

func TestCoursesPaginateInNaturalOrder(t *testing.T) {
	server, _, _ := regressionServer(t, map[string]string{"Course 1/readme.txt": "", "Course 2/readme.txt": "", "Course 10/readme.txt": ""})
	cursor := ""
	for _, want := range []string{"Course 1", "Course 2", "Course 10"} {
		rec := httptest.NewRecorder()
		server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/libraries/library_default/courses?limit=1&cursor="+cursor, nil))
		var page struct {
			Items      []struct{ OriginalName string }
			NextCursor *string
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Items) != 1 || page.Items[0].OriginalName != want {
			t.Fatalf("expected %s: %s", want, rec.Body.String())
		}
		cursor = ""
		if page.NextCursor != nil {
			cursor = *page.NextCursor
		}
	}
	if cursor != "" {
		t.Fatalf("unexpected final cursor %q", cursor)
	}
}

func TestArchiveFailuresReturnJSONNotPartialZIP(t *testing.T) {
	for _, scenario := range []string{"source limit", "temporary storage failure"} {
		t.Run(scenario, func(t *testing.T) {
			server, store, root := regressionServer(t, map[string]string{"Course/examples/file.txt": "hello"})
			want := http.StatusInternalServerError
			if scenario == "source limit" {
				// Sparse file: the source limit is checked before reading its contents.
				if err := os.Truncate(filepath.Join(root, "Course/examples/file.txt"), (2<<30)+1); err != nil {
					t.Fatal(err)
				}
				want = http.StatusRequestEntityTooLarge
			} else {
				badTemp := filepath.Join(t.TempDir(), "not-a-directory")
				if err := os.WriteFile(badTemp, []byte("file"), 0600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("TMPDIR", badTemp)
			}
			items, err := store.Items(context.Background(), "library_default")
			if err != nil {
				t.Fatal(err)
			}
			var folderID string
			for _, item := range items {
				if item.Type == "asset_directory" {
					folderID = item.ID
				}
			}
			rec := httptest.NewRecorder()
			server.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/assets/"+folderID+"/archive.zip", nil))
			if rec.Code != want || rec.Header().Get("Content-Type") != "application/json; charset=utf-8" || rec.Header().Get("Content-Disposition") != "" {
				t.Fatalf("status=%d headers=%v body=%s", rec.Code, rec.Header(), rec.Body.String())
			}
		})
	}
}
