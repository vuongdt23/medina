package httpapi

import (
	"archive/zip"
	"bytes"
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

func TestManualScanSubmissionDoesNotDependOnRequestContext(t *testing.T) {
	root := t.TempDir()
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "scan-context.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server, err := New(config.Config{BindAddress: "127.0.0.1:0", ContentRoot: root, LibraryName: "Test"}, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	submitted := false
	server.SetScanSubmitter(func(reason string) bool {
		submitted = reason == "manual"
		return submitted
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/index/scan", nil).WithContext(ctx)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted || !submitted {
		t.Fatalf("canceled request prevented background submission: status=%d submitted=%v body=%q", rec.Code, submitted, rec.Body.String())
	}
}

func TestManualScanSubmitsSingletonBackgroundJob(t *testing.T) {
	root := t.TempDir()
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "scan-submit.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server, err := New(config.Config{BindAddress: "127.0.0.1:0", ContentRoot: root, LibraryName: "Test"}, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	server.SetScanSubmitter(func(reason string) bool {
		calls++
		return calls == 1 && reason == "manual"
	})

	accepted := httptest.NewRecorder()
	server.Handler().ServeHTTP(accepted, httptest.NewRequest(http.MethodPost, "/api/v1/index/scan", nil))
	if accepted.Code != http.StatusAccepted || accepted.Header().Get("Location") != "/api/v1/index/status" {
		t.Fatalf("first scan: status=%d headers=%v body=%q", accepted.Code, accepted.Header(), accepted.Body.String())
	}
	duplicate := httptest.NewRecorder()
	server.Handler().ServeHTTP(duplicate, httptest.NewRequest(http.MethodPost, "/api/v1/index/scan", nil))
	if duplicate.Code != http.StatusConflict || calls != 2 {
		t.Fatalf("duplicate scan: status=%d calls=%d body=%q", duplicate.Code, calls, duplicate.Body.String())
	}
}

func TestSwaggerAndOpenAPIEndpoints(t *testing.T) {
	root := t.TempDir()
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "swagger.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	server, err := New(config.Config{BindAddress: "127.0.0.1:0", ContentRoot: root, LibraryName: "Test"}, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ path, contentType, contains string }{
		{"/openapi.yaml", "application/yaml; charset=utf-8", "openapi: 3.1.0"},
		{"/api-docs/openapi.yaml", "application/yaml; charset=utf-8", "openapi: 3.1.0"},
		{"/swagger/", "text/html; charset=utf-8", "SwaggerUIBundle"},
		{"/swagger-ui.css", "text/css; charset=utf-8", ".swagger-ui"},
		{"/swagger-ui-bundle.js", "application/javascript; charset=utf-8", "SwaggerUIBundle"},
	} {
		rec := httptest.NewRecorder()
		server.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, test.path, nil))
		if !frontendBundled && test.path != "/openapi.yaml" && test.path != "/api-docs/openapi.yaml" {
			if rec.Code != http.StatusNotFound {
				t.Fatalf("%s: frontend served in API-only build: status=%d", test.path, rec.Code)
			}
			continue
		}
		if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != test.contentType || !strings.Contains(rec.Body.String(), test.contains) {
			t.Fatalf("%s: code=%d type=%q body=%q", test.path, rec.Code, rec.Header().Get("Content-Type"), rec.Body.String())
		}
	}
}

func TestContentServesRangesAndRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "lesson.mp4"), []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "slides.pdf"), []byte("%PDF-1.4 test"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "example.go"), []byte("package main\\n\\nfunc main() {}\\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "unsafe.html"), []byte("<script>alert(1)</script>"), 0o644); err != nil {
		t.Fatal(err)
	}
	assetDir := filepath.Join(course, "examples")
	if err := os.MkdirAll(filepath.Join(assetDir, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "main.go"), []byte("package main"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "nested", "README.md"), []byte("nested asset"), 0o644); err != nil {
		t.Fatal(err)
	}
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	cfg := config.Config{BindAddress: "127.0.0.1:0", DatabasePath: "unused", ContentRoot: root, LibraryName: "Test"}
	server, err := New(cfg, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Scan(context.Background(), "library_default", root); err != nil {
		t.Fatal(err)
	}
	items, err := store.Items(context.Background(), "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var id string
	for _, it := range items {
		if it.Type == "lesson" {
			id = it.ID
		}
	}
	if id == "" {
		t.Fatal("lesson not indexed")
	}
	req := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+id+"/content", nil)
	req.Header.Set("Range", "bytes=2-5")
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent || rec.Body.String() != "2345" {
		t.Fatalf("range response: status=%d body=%q", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("Accept-Ranges=%q", rec.Header().Get("Accept-Ranges"))
	}
	if rec.Header().Get("ETag") == "" || rec.Header().Get("Last-Modified") == "" {
		t.Fatal("expected ETag and Last-Modified headers")
	}
	if rec.Header().Get("Content-Security-Policy") != "" {
		t.Fatal("browser-native video must not receive a restrictive document CSP")
	}
	var pdfID string
	for _, item := range items {
		if item.OriginalName == "slides.pdf" {
			pdfID = item.ID
		}
	}
	pdfReq := httptest.NewRequest(http.MethodGet, "/api/v1/assets/"+pdfID+"/preview", nil)
	pdfRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(pdfRec, pdfReq)
	if pdfRec.Code != http.StatusOK || pdfRec.Header().Get("Content-Security-Policy") != "" || !strings.HasPrefix(pdfRec.Header().Get("Content-Type"), "application/pdf") || !strings.HasPrefix(pdfRec.Header().Get("Content-Disposition"), "inline") {
		t.Fatalf("PDF preview status=%d CSP=%q type=%q disposition=%q", pdfRec.Code, pdfRec.Header().Get("Content-Security-Policy"), pdfRec.Header().Get("Content-Type"), pdfRec.Header().Get("Content-Disposition"))
	}
	var codeID, htmlID, folderID string
	for _, item := range items {
		if item.OriginalName == "example.go" {
			codeID = item.ID
		}
		if item.OriginalName == "unsafe.html" {
			htmlID = item.ID
		}
		if item.Type == "asset_directory" && item.OriginalName == "examples" {
			folderID = item.ID
		}
	}
	codeReq := httptest.NewRequest(http.MethodGet, "/api/v1/assets/"+codeID+"/preview", nil)
	codeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(codeRec, codeReq)
	if codeRec.Code != http.StatusOK || codeRec.Header().Get("Content-Type") != "text/plain; charset=utf-8" || !strings.Contains(codeRec.Body.String(), "package main") {
		t.Fatalf("source preview: status=%d type=%q body=%q", codeRec.Code, codeRec.Header().Get("Content-Type"), codeRec.Body.String())
	}
	htmlReq := httptest.NewRequest(http.MethodGet, "/api/v1/assets/"+htmlID+"/preview", nil)
	htmlRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(htmlRec, htmlReq)
	if htmlRec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("HTML preview status=%d, expected 415", htmlRec.Code)
	}
	zipReq := httptest.NewRequest(http.MethodGet, "/api/v1/assets/"+folderID+"/archive.zip", nil)
	zipRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(zipRec, zipReq)
	if zipRec.Code != http.StatusOK || zipRec.Header().Get("Content-Type") != "application/zip" || !strings.HasPrefix(zipRec.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("zip status=%d headers=%v", zipRec.Code, zipRec.Header())
	}
	archive, err := zip.NewReader(bytes.NewReader(zipRec.Body.Bytes()), int64(zipRec.Body.Len()))
	if err != nil {
		t.Fatalf("read generated zip: %v", err)
	}
	entries := map[string]string{}
	for _, entry := range archive.File {
		reader, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		content, err := io.ReadAll(reader)
		reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		entries[entry.Name] = string(content)
	}
	if entries["main.go"] != "package main" || entries[filepath.ToSlash(filepath.Join("nested", "README.md"))] != "nested asset" {
		t.Fatalf("zip contents: %v", entries)
	}
	missingZip := httptest.NewRequest(http.MethodGet, "/api/v1/assets/missing/archive.zip", nil)
	missingRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(missingRec, missingZip)
	if missingRec.Code != http.StatusNotFound {
		t.Fatalf("missing zip status=%d", missingRec.Code)
	}
	unsupported := httptest.NewRequest(http.MethodGet, "/api/v1/assets/"+pdfID+"/preview-extra", nil)
	unsupportedRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(unsupportedRec, unsupported)
	if unsupportedRec.Code == http.StatusOK {
		t.Fatal("unknown preview path should not resolve as asset preview")
	}
	badRange := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+id+"/content", nil)
	badRange.Header.Set("Range", "bytes=99-100")
	badRangeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(badRangeRec, badRange)
	if badRangeRec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("unsatisfiable range status=%d", badRangeRec.Code)
	}
	if badRangeRec.Header().Get("Content-Range") != "bytes */10" {
		t.Fatalf("unsatisfiable Content-Range=%q", badRangeRec.Header().Get("Content-Range"))
	}
	conditional := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+id+"/content", nil)
	conditional.Header.Set("If-None-Match", rec.Header().Get("ETag"))
	conditionalRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(conditionalRec, conditional)
	if conditionalRec.Code != http.StatusNotModified {
		t.Fatalf("If-None-Match status=%d", conditionalRec.Code)
	}
	ifRange := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+id+"/content", nil)
	ifRange.Header.Set("Range", "bytes=2-5")
	ifRange.Header.Set("If-Range", `"stale"`)
	ifRangeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(ifRangeRec, ifRange)
	if ifRangeRec.Code != http.StatusOK || ifRangeRec.Body.String() != "0123456789" {
		t.Fatalf("If-Range should fall back to full response: status=%d body=%q", ifRangeRec.Code, ifRangeRec.Body.String())
	}
	// The ETag must be strong (no W/ prefix): media players (libVLC) seek with
	// Range + If-Range, and a weak validator makes every conditional range fail,
	// collapsing the seek to a full-file 200 the demuxer rejects.
	servedETag := rec.Header().Get("ETag")
	if strings.HasPrefix(servedETag, "W/") {
		t.Fatalf("content ETag must be strong for range validation, got %q", servedETag)
	}
	// A matching If-Range must preserve the Range and return 206 with the exact
	// bytes — the seek case that was broken when the ETag was weak.
	ifRangeMatch := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+id+"/content", nil)
	ifRangeMatch.Header.Set("Range", "bytes=2-5")
	ifRangeMatch.Header.Set("If-Range", servedETag)
	ifRangeMatchRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(ifRangeMatchRec, ifRangeMatch)
	if ifRangeMatchRec.Code != http.StatusPartialContent || ifRangeMatchRec.Body.String() != "2345" {
		t.Fatalf("matching If-Range should return 206 partial: status=%d body=%q", ifRangeMatchRec.Code, ifRangeMatchRec.Body.String())
	}
	bad := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/../../etc/passwd/content", nil)
	badRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(badRec, bad)
	if badRec.Code == http.StatusOK {
		t.Fatal("traversal URL unexpectedly succeeded")
	}
	if strings.Contains(badRec.Body.String(), root) {
		t.Fatal("error leaked absolute path")
	}
}

func TestLessonProgressRoundTripAndCourseAggregation(t *testing.T) {
	root := t.TempDir()
	course := filepath.Join(root, "Course")
	if err := os.MkdirAll(course, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "lesson-a.mp4"), []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(course, "lesson-b.mp4"), []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	store, err := sqlite.Open(filepath.Join(t.TempDir(), "progress.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	cfg := config.Config{BindAddress: "127.0.0.1:0", DatabasePath: "unused", ContentRoot: root, LibraryName: "Test"}
	server, err := New(cfg, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Scan(context.Background(), "library_default", root); err != nil {
		t.Fatal(err)
	}
	items, err := store.Items(context.Background(), "library_default")
	if err != nil {
		t.Fatal(err)
	}
	var courseID, lessonA string
	for _, it := range items {
		switch {
		case it.Type == "course":
			courseID = it.ID
		case it.Type == "lesson" && it.OriginalName == "lesson-a.mp4":
			lessonA = it.ID
		}
	}
	if courseID == "" || lessonA == "" {
		t.Fatalf("library not indexed as expected: course=%q lessonA=%q", courseID, lessonA)
	}
	const profile = "profile-123"

	// Capability flag advertises the feature.
	infoRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(infoRec, httptest.NewRequest(http.MethodGet, "/api/v1/system/info", nil))
	var info struct {
		Capabilities map[string]bool `json:"capabilities"`
	}
	if err := json.Unmarshal(infoRec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if !info.Capabilities["progress"] {
		t.Fatal("progress capability should be advertised as true")
	}

	// PUT requires a profile header.
	noProfile := httptest.NewRequest(http.MethodPut, "/api/v1/lessons/"+lessonA+"/progress", strings.NewReader(`{"positionSeconds":1}`))
	noProfileRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(noProfileRec, noProfile)
	if noProfileRec.Code != http.StatusBadRequest {
		t.Fatalf("missing profile: expected 400, got %d", noProfileRec.Code)
	}

	// PUT rejects a malformed body.
	badBody := httptest.NewRequest(http.MethodPut, "/api/v1/lessons/"+lessonA+"/progress", strings.NewReader("not json"))
	badBody.Header.Set("X-Medina-Profile", profile)
	badBodyRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(badBodyRec, badBody)
	if badBodyRec.Code != http.StatusBadRequest {
		t.Fatalf("bad body: expected 400, got %d", badBodyRec.Code)
	}

	// PUT rejects an unknown lesson.
	unknown := httptest.NewRequest(http.MethodPut, "/api/v1/lessons/does-not-exist/progress", strings.NewReader(`{"positionSeconds":1}`))
	unknown.Header.Set("X-Medina-Profile", profile)
	unknownRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(unknownRec, unknown)
	if unknownRec.Code != http.StatusNotFound {
		t.Fatalf("unknown lesson: expected 404, got %d", unknownRec.Code)
	}

	// PUT then GET round-trips the stored record.
	put := httptest.NewRequest(http.MethodPut, "/api/v1/lessons/"+lessonA+"/progress", strings.NewReader(`{"positionSeconds":42.5,"durationSeconds":100,"completed":true}`))
	put.Header.Set("X-Medina-Profile", profile)
	putRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(putRec, put)
	if putRec.Code != http.StatusOK {
		t.Fatalf("put: expected 200, got %d (%s)", putRec.Code, putRec.Body.String())
	}

	getReq := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+lessonA+"/progress", nil)
	getReq.Header.Set("X-Medina-Profile", profile)
	getRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(getRec, getReq)
	var record struct {
		PositionSeconds float64 `json:"positionSeconds"`
		Completed       bool    `json:"completed"`
	}
	if err := json.Unmarshal(getRec.Body.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record.PositionSeconds != 42.5 || !record.Completed {
		t.Fatalf("round-trip mismatch: %+v", record)
	}

	// A different profile sees no progress for the same lesson.
	otherGet := httptest.NewRequest(http.MethodGet, "/api/v1/lessons/"+lessonA+"/progress", nil)
	otherGet.Header.Set("X-Medina-Profile", "someone-else")
	otherRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(otherRec, otherGet)
	var otherRecord struct {
		Completed bool `json:"completed"`
	}
	if err := json.Unmarshal(otherRec.Body.Bytes(), &otherRecord); err != nil {
		t.Fatal(err)
	}
	if otherRecord.Completed {
		t.Fatal("progress leaked across profiles")
	}

	// Course aggregation counts the course's lessons and completions.
	courseReq := httptest.NewRequest(http.MethodGet, "/api/v1/courses/"+courseID+"/progress", nil)
	courseReq.Header.Set("X-Medina-Profile", profile)
	courseRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(courseRec, courseReq)
	var agg struct {
		Lessons        map[string]any `json:"lessons"`
		CompletedCount int            `json:"completedCount"`
		TotalCount     int            `json:"totalCount"`
	}
	if err := json.Unmarshal(courseRec.Body.Bytes(), &agg); err != nil {
		t.Fatal(err)
	}
	if agg.TotalCount != 2 {
		t.Fatalf("expected totalCount=2, got %d", agg.TotalCount)
	}
	if agg.CompletedCount != 1 {
		t.Fatalf("expected completedCount=1, got %d", agg.CompletedCount)
	}
	if _, ok := agg.Lessons[lessonA]; !ok {
		t.Fatal("aggregation missing the completed lesson")
	}
}
