package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"medina/api"
	"medina/internal/config"
	"medina/internal/scanner"
	"medina/internal/store/sqlite"
)

type Server struct {
	cfg        config.Config
	store      *sqlite.Store
	logger     *slog.Logger
	mux        *http.ServeMux
	libraryID  string
	submitScan func(string) bool
}

func New(cfg config.Config, store *sqlite.Store, logger *slog.Logger) (*Server, error) {
	canonicalRoot, err := filepath.EvalSymlinks(cfg.ContentRoot)
	if err != nil {
		return nil, fmt.Errorf("resolve content root: %w", err)
	}
	cfg.ContentRoot = canonicalRoot
	s := &Server{cfg: cfg, store: store, logger: logger, mux: http.NewServeMux(), libraryID: "library_default"}
	if err := store.EnsureLibrary(context.Background(), s.libraryID, cfg.LibraryName, cfg.ContentRoot); err != nil {
		return nil, err
	}
	s.routes()
	return s, nil
}

// SetScanSubmitter connects manual scan requests to the application's
// singleton background scan coordinator.
func (s *Server) SetScanSubmitter(submit func(string) bool) {
	s.submitScan = submit
}

func (s *Server) Handler() http.Handler {
	return s.logRequests(s.recover(s.securityHeaders(s.mux)))
}

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) Flush() {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *statusWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	n, err := w.ResponseWriter.Write(body)
	w.bytes += int64(n)
	return n, err
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		logged := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(logged, r)
		if logged.status == 0 {
			logged.status = http.StatusOK
		}
		attrs := []any{
			"method", r.Method,
			"path", r.URL.Path,
			"status", logged.status,
			"bytes", logged.bytes,
			"duration_ms", time.Since(started).Milliseconds(),
			"remote_addr", r.RemoteAddr,
		}
		switch {
		case logged.status >= http.StatusInternalServerError:
			s.logger.Error("http request failed", attrs...)
		case logged.status >= http.StatusBadRequest:
			s.logger.Warn("http request rejected", attrs...)
		default:
			s.logger.Debug("http request", attrs...)
		}
	})
}
func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		if strings.HasPrefix(r.URL.Path, "/api/") && (r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodDelete) {
			origin := r.Header.Get("Origin")
			if origin != "" {
				u, err := url.Parse(origin)
				if err != nil || u.Host != r.Host {
					writeError(w, http.StatusForbidden, "invalid_origin", "Cross-origin state-changing requests are not allowed.")
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}
func (s *Server) routes() {
	s.mux.HandleFunc("GET /openapi.yaml", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/yaml; charset=utf-8")
		_, _ = w.Write(api.OpenAPI)
	})
	s.mux.HandleFunc("GET /api-docs/openapi.yaml", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/yaml; charset=utf-8")
		_, _ = w.Write(api.OpenAPI)
	})
	s.mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]any{"status": "ok"}) })
	s.mux.HandleFunc("GET /api/v1/system/info", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"name": "Medina", "version": "0.1.0", "apiVersion": "1", "capabilities": map[string]bool{"authentication": false, "transcoding": false, "progress": true, "fileWatching": !s.cfg.DisableWatching, "thumbnails": false}})
	})
	s.mux.HandleFunc("GET /api/v1/index/status", func(w http.ResponseWriter, r *http.Request) {
		v, e := s.store.Status(r.Context(), s.libraryID)
		if e != nil {
			writeError(w, 500, "internal_error", "Could not retrieve index status.")
			return
		}
		writeJSON(w, 200, v)
	})
	s.mux.HandleFunc("POST /api/v1/index/scan", func(w http.ResponseWriter, r *http.Request) {
		if s.submitScan == nil || !s.submitScan("manual") {
			writeError(w, http.StatusConflict, "scan_in_progress", "A library scan is already running.")
			return
		}
		w.Header().Set("Location", "/api/v1/index/status")
		writeJSON(w, http.StatusAccepted, map[string]any{"status": "scanning", "statusUrl": "/api/v1/index/status"})
	})
	s.mux.HandleFunc("GET /api/v1/libraries", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, []any{map[string]any{"id": s.libraryID, "name": s.cfg.LibraryName}})
	})
	s.mux.HandleFunc("GET /api/v1/libraries/{libraryID}/courses", func(w http.ResponseWriter, r *http.Request) {
		if r.PathValue("libraryID") != s.libraryID {
			writeError(w, 404, "item_not_found", "Library not found.")
			return
		}
		items, e := s.store.Courses(r.Context(), s.libraryID)
		if e != nil {
			writeError(w, 500, "internal_error", "Could not read indexed items.")
			return
		}
		var courses []map[string]any
		for _, it := range items {
			if it.Type == "course" {
				courses = append(courses, map[string]any{"id": it.ID, "title": it.Title, "originalName": it.OriginalName, "position": it.Position})
			}
		}
		limit := 100
		if raw := r.URL.Query().Get("limit"); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil || parsed < 1 {
				writeError(w, 400, "invalid_request", "limit must be a positive integer.")
				return
			}
			if parsed > 100 {
				parsed = 100
			}
			limit = parsed
		}
		offset := 0
		if raw := r.URL.Query().Get("cursor"); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil || parsed < 0 {
				writeError(w, 400, "invalid_request", "cursor must be a non-negative integer.")
				return
			}
			offset = parsed
		}
		if offset > len(courses) {
			offset = len(courses)
		}
		end := offset + limit
		if end > len(courses) {
			end = len(courses)
		}
		page := courses[offset:end]
		var next any
		if end < len(courses) {
			next = strconv.Itoa(end)
		}
		writeJSON(w, 200, map[string]any{"items": page, "limit": limit, "nextCursor": next})
	})
	s.mux.HandleFunc("GET /api/v1/courses/{courseID}", func(w http.ResponseWriter, r *http.Request) {
		items, e := s.items(r)
		if e != nil {
			writeError(w, 500, "internal_error", "Could not read indexed items.")
			return
		}
		for _, it := range items {
			if it.ID == r.PathValue("courseID") && it.Type == "course" {
				writeJSON(w, 200, map[string]any{"id": it.ID, "type": it.Type, "title": it.Title, "originalName": it.OriginalName, "position": it.Position, "mimeType": it.MimeType})
				return
			}
		}
		writeError(w, 404, "item_not_found", "Course not found.")
	})
	s.mux.HandleFunc("GET /api/v1/courses/{courseID}/tree", s.courseTree)
	s.mux.HandleFunc("GET /api/v1/courses/{courseID}/progress", s.courseProgress)
	s.mux.HandleFunc("PUT /api/v1/lessons/{itemID}/progress", s.putLessonProgress)
	s.mux.HandleFunc("GET /api/v1/lessons/{itemID}/progress", s.getLessonProgress)
	s.mux.HandleFunc("GET /api/v1/lessons/{itemID}/content", s.content)
	s.mux.HandleFunc("GET /api/v1/assets/{itemID}/content", s.content)
	s.mux.HandleFunc("GET /api/v1/assets/{itemID}/archive.zip", s.zipAssetDirectory)
	s.mux.HandleFunc("GET /api/v1/assets/{itemID}/preview", s.preview)
	s.mux.HandleFunc("HEAD /api/v1/lessons/{itemID}/content", s.content)
	s.mux.HandleFunc("HEAD /api/v1/assets/{itemID}/content", s.content)
	s.mux.HandleFunc("HEAD /api/v1/assets/{itemID}/preview", s.preview)
	s.mux.HandleFunc("GET /api/v1/assets/{itemID}/download", s.content)
	s.mux.HandleFunc("HEAD /api/v1/assets/{itemID}/download", s.content)
	s.frontendRoutes()
}
func (s *Server) items(r *http.Request) ([]scanner.Item, error) {
	return s.store.Items(r.Context(), s.libraryID)
}
func (s *Server) courseTree(w http.ResponseWriter, r *http.Request) {
	items, e := s.items(r)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	id := r.PathValue("courseID")
	var course *scanner.Item
	for i := range items {
		if items[i].ID == id && items[i].Type == "course" {
			course = &items[i]
			break
		}
	}
	if course == nil {
		writeError(w, 404, "item_not_found", "Course not found.")
		return
	}
	children := map[string][]scanner.Item{}
	for _, it := range items {
		children[it.ParentID] = append(children[it.ParentID], it)
	}
	var build func(scanner.Item) map[string]any
	var buildAssetChildren func(string) []map[string]any
	build = func(it scanner.Item) map[string]any {
		obj := map[string]any{"id": it.ID, "type": it.Type, "title": it.Title, "originalName": it.OriginalName, "position": it.Position, "mimeType": it.MimeType, "extension": it.Extension, "sizeBytes": it.SizeBytes}
		if it.Type == "subtitle" {
			obj["contentUrl"] = "/api/v1/assets/" + it.ID + "/content"
		}
		if it.Type == "lesson" {
			obj["mediaKind"] = it.MediaKind
			obj["mimeType"] = it.MimeType
			obj["streamUrl"] = "/api/v1/lessons/" + it.ID + "/content"
		}
		var sub, assets, sections, lessons []map[string]any
		if it.Type == "asset_directory" {
			obj["children"] = buildAssetChildren(it.ID)
			return obj
		}
		for _, ch := range children[it.ID] {
			entry := build(ch)
			switch ch.Type {
			case "section":
				sections = append(sections, entry)
			case "lesson":
				lessons = append(lessons, entry)
			case "subtitle":
				sub = append(sub, entry)
			case "asset", "asset_directory":
				assets = append(assets, entry)
			}
		}
		sort.Slice(sections, func(i, j int) bool { return sections[i]["position"].(int) < sections[j]["position"].(int) })
		sort.Slice(lessons, func(i, j int) bool { return lessons[i]["position"].(int) < lessons[j]["position"].(int) })
		sort.Slice(assets, func(i, j int) bool { return assets[i]["position"].(int) < assets[j]["position"].(int) })
		sort.Slice(sub, func(i, j int) bool { return sub[i]["position"].(int) < sub[j]["position"].(int) })
		if len(sections) > 0 {
			obj["sections"] = sections
		}
		if len(lessons) > 0 {
			obj["lessons"] = lessons
		}
		if len(sub) > 0 {
			obj["subtitles"] = sub
		}
		if len(assets) > 0 {
			obj["assets"] = assets
		}
		if it.Type == "asset" {
			obj["contentUrl"] = "/api/v1/assets/" + it.ID + "/content"
		}
		return obj
	}
	buildAssetChildren = func(parentID string) []map[string]any {
		var out []map[string]any
		for _, child := range children[parentID] {
			if child.Type == "asset" || child.Type == "asset_directory" {
				out = append(out, build(child))
			}
		}
		sort.Slice(out, func(i, j int) bool { return out[i]["position"].(int) < out[j]["position"].(int) })
		return out
	}
	tree := build(*course)
	tree["summary"] = map[string]int{"sectionCount": countTypes(items, id, "section"), "lessonCount": countTypes(items, id, "lesson")}
	writeJSON(w, 200, tree)
}
func countTypes(items []scanner.Item, root, typ string) int {
	parents := map[string][]scanner.Item{}
	for _, it := range items {
		parents[it.ParentID] = append(parents[it.ParentID], it)
	}
	var count int
	var walk func(string)
	walk = func(p string) {
		for _, it := range parents[p] {
			if it.Type == typ {
				count++
			}
			walk(it.ID)
		}
	}
	walk(root)
	return count
}

// lessonIDsUnder returns the set of lesson item IDs anywhere beneath a course,
// mirroring the parent-chain walk used by countTypes. Progress is only tracked
// for lessons, so this bounds what a course-progress response may contain.
func lessonIDsUnder(items []scanner.Item, root string) map[string]bool {
	children := map[string][]scanner.Item{}
	for _, it := range items {
		children[it.ParentID] = append(children[it.ParentID], it)
	}
	ids := map[string]bool{}
	var walk func(string)
	walk = func(p string) {
		for _, it := range children[p] {
			if it.Type == "lesson" {
				ids[it.ID] = true
			}
			walk(it.ID)
		}
	}
	walk(root)
	return ids
}

// profileID extracts the opaque client profile identifier that scopes progress.
// The server is single-tenant with no accounts; the client sends a stable UUID.
func profileID(r *http.Request) string {
	return strings.TrimSpace(r.Header.Get("X-Medina-Profile"))
}

type lessonProgressPayload struct {
	PositionSeconds float64 `json:"positionSeconds"`
	DurationSeconds float64 `json:"durationSeconds"`
	Completed       bool    `json:"completed"`
}

func lessonProgressJSON(p sqlite.LessonProgress) map[string]any {
	return map[string]any{
		"itemId":          p.ItemID,
		"positionSeconds": p.PositionSeconds,
		"durationSeconds": p.DurationSeconds,
		"completed":       p.Completed,
		"updatedAt":       p.UpdatedAt.UTC().Format(time.RFC3339Nano),
	}
}

func (s *Server) lessonExists(items []scanner.Item, id string) bool {
	for i := range items {
		if items[i].ID == id && items[i].Type == "lesson" {
			return true
		}
	}
	return false
}

func (s *Server) putLessonProgress(w http.ResponseWriter, r *http.Request) {
	profile := profileID(r)
	if profile == "" {
		writeError(w, 400, "invalid_request", "A X-Medina-Profile header is required.")
		return
	}
	var payload lessonProgressPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeError(w, 400, "invalid_request", "The request body must be a JSON progress object.")
		return
	}
	if payload.PositionSeconds < 0 || payload.DurationSeconds < 0 {
		writeError(w, 400, "invalid_request", "Progress values must not be negative.")
		return
	}
	items, e := s.items(r)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	id := r.PathValue("itemID")
	if !s.lessonExists(items, id) {
		writeError(w, 404, "item_not_found", "Lesson not found.")
		return
	}
	record := sqlite.LessonProgress{
		ItemID:          id,
		PositionSeconds: payload.PositionSeconds,
		DurationSeconds: payload.DurationSeconds,
		Completed:       payload.Completed,
		UpdatedAt:       time.Now().UTC(),
	}
	if err := s.store.UpsertLessonProgress(r.Context(), s.libraryID, profile, record); err != nil {
		writeError(w, 500, "internal_error", "Could not save lesson progress.")
		return
	}
	writeJSON(w, 200, lessonProgressJSON(record))
}

func (s *Server) getLessonProgress(w http.ResponseWriter, r *http.Request) {
	profile := profileID(r)
	if profile == "" {
		writeError(w, 400, "invalid_request", "A X-Medina-Profile header is required.")
		return
	}
	id := r.PathValue("itemID")
	record, ok, err := s.store.LessonProgressFor(r.Context(), s.libraryID, profile, id)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read lesson progress.")
		return
	}
	if !ok {
		record = sqlite.LessonProgress{ItemID: id, UpdatedAt: time.Time{}}
	}
	writeJSON(w, 200, lessonProgressJSON(record))
}

func (s *Server) courseProgress(w http.ResponseWriter, r *http.Request) {
	profile := profileID(r)
	if profile == "" {
		writeError(w, 400, "invalid_request", "A X-Medina-Profile header is required.")
		return
	}
	items, e := s.items(r)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	id := r.PathValue("courseID")
	var found bool
	for i := range items {
		if items[i].ID == id && items[i].Type == "course" {
			found = true
			break
		}
	}
	if !found {
		writeError(w, 404, "item_not_found", "Course not found.")
		return
	}
	lessonIDs := lessonIDsUnder(items, id)
	records, err := s.store.AllLessonProgress(r.Context(), s.libraryID, profile)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read lesson progress.")
		return
	}
	lessons := map[string]any{}
	completedCount := 0
	for _, p := range records {
		if !lessonIDs[p.ItemID] {
			continue
		}
		lessons[p.ItemID] = lessonProgressJSON(p)
		if p.Completed {
			completedCount++
		}
	}
	writeJSON(w, 200, map[string]any{
		"lessons":        lessons,
		"completedCount": completedCount,
		"totalCount":     len(lessonIDs),
	})
}
func (s *Server) preview(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("itemID")
	items, err := s.items(r)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not resolve asset.")
		return
	}
	var item *scanner.Item
	for i := range items {
		if items[i].ID == id && items[i].Type == "asset" {
			item = &items[i]
			break
		}
	}
	if item == nil {
		writeError(w, 404, "item_not_found", "Asset not found.")
		return
	}
	ext := strings.ToLower(filepath.Ext(item.OriginalName))
	if !previewable(item.MimeType, ext) {
		writeError(w, 415, "unsupported_operation", "This asset type is not available for inline preview.")
		return
	}
	s.contentAs(w, r, item, true)
}
func isCodeExtension(ext string) bool {
	return codeExtensions[strings.ToLower(ext)]
}

// codeExtensions are text/source files the client can render inline with syntax
// highlighting. Kept broad and in sync with the macOS client's CodeViewer so a
// recognizable source file is never rejected just because the OS mime database
// lacks an entry for it (e.g. .kt, .swift, .rb return no mime.TypeByExtension).
var codeExtensions = map[string]bool{
	".md": true, ".markdown": true, ".txt": true, ".log": true, ".text": true,
	".go": true, ".rs": true, ".py": true, ".pyw": true, ".rb": true, ".php": true,
	".js": true, ".jsx": true, ".mjs": true, ".cjs": true, ".ts": true, ".tsx": true,
	".mts": true, ".cts": true, ".java": true, ".kt": true, ".kts": true, ".scala": true,
	".swift": true, ".c": true, ".h": true, ".cc": true, ".cpp": true, ".cxx": true,
	".hpp": true, ".hh": true, ".m": true, ".mm": true, ".cs": true, ".fs": true,
	".lua": true, ".pl": true, ".pm": true, ".r": true, ".dart": true, ".groovy": true,
	".gradle": true, ".clj": true, ".ex": true, ".exs": true, ".erl": true, ".hs": true,
	".json": true, ".jsonc": true, ".yaml": true, ".yml": true, ".toml": true, ".ini": true,
	".cfg": true, ".conf": true, ".properties": true, ".env": true, ".xml": true,
	".csv": true, ".tsv": true, ".sh": true, ".bash": true, ".zsh": true, ".fish": true,
	".ps1": true, ".psm1": true, ".bat": true, ".cmd": true, ".sql": true, ".css": true,
	".scss": true, ".sass": true, ".less": true, ".graphql": true, ".gql": true,
	".proto": true, ".tf": true, ".tfvars": true, ".hcl": true, ".dockerfile": true,
	".gitignore": true, ".editorconfig": true,
}

// imageExtensions are raster/vector images the client can display inline. Used
// alongside the mime check so images with a missing or octet-stream mime type
// (the OS mime database is incomplete for .webp/.avif/.heic and others) still
// preview. SVG is handled as an active document, not here.
var imageExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true,
	".bmp": true, ".avif": true, ".tiff": true, ".tif": true, ".ico": true,
	".heic": true, ".heif": true,
}

func mediaType(value string) string {
	typ, _, err := mime.ParseMediaType(value)
	if err != nil {
		return ""
	}
	return typ
}

func activeDocument(mimeType, ext string) bool {
	switch strings.ToLower(ext) {
	case ".html", ".htm", ".xhtml", ".xht", ".svg", ".svgz":
		return true
	}
	switch mediaType(mimeType) {
	case "text/html", "application/xhtml+xml", "image/svg+xml":
		return true
	}
	return false
}

func rasterImage(typ string) bool {
	switch typ {
	case "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/avif", "image/tiff", "image/x-icon", "image/vnd.microsoft.icon":
		return true
	}
	return false
}

func previewable(mimeType, ext string) bool {
	if activeDocument(mimeType, ext) {
		return false
	}
	typ := mediaType(mimeType)
	if typ == "application/pdf" || rasterImage(typ) || strings.HasPrefix(typ, "text/") {
		return true
	}
	ext = strings.ToLower(ext)
	return imageExtensions[ext] || codeExtensions[ext]
}
func (s *Server) zipAssetDirectory(w http.ResponseWriter, r *http.Request) {
	items, err := s.items(r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "Could not resolve asset folder.")
		return
	}
	id := r.PathValue("itemID")
	var folder *scanner.Item
	for i := range items {
		if items[i].ID == id && items[i].Type == "asset_directory" {
			folder = &items[i]
			break
		}
	}
	if folder == nil {
		writeError(w, http.StatusNotFound, "item_not_found", "Asset folder not found.")
		return
	}
	root, err := os.OpenRoot(s.cfg.ContentRoot)
	if err != nil {
		writeError(w, http.StatusNotFound, "root_offline", "The content root is unavailable.")
		return
	}
	defer root.Close()
	if !safeRelativePath(folder.RelativePath) {
		writeError(w, http.StatusNotFound, "item_unavailable", "Asset folder is unavailable.")
		return
	}
	dir, err := root.OpenRoot(filepath.FromSlash(folder.RelativePath))
	if err != nil {
		writeError(w, http.StatusNotFound, "item_unavailable", "Asset folder is unavailable.")
		return
	}
	defer dir.Close()
	// Stage outside the content root. Never commit a successful response until
	// traversal, limits, compression, and the central directory all succeed.
	archive, err := os.CreateTemp("", "course-media-*.zip")
	if err != nil {
		s.logger.Error("create asset archive", "item_id", id, "error", err)
		writeError(w, 500, "internal_error", "Could not create asset archive.")
		return
	}
	defer func() {
		_ = archive.Close()
		_ = os.Remove(archive.Name())
	}()
	err = buildAssetArchive(r.Context(), dir, archive, archiveLimits{files: 10000, sourceBytes: 2 << 30, compressedBytes: 512 << 20})
	if err != nil {
		s.logger.Warn("asset archive failed", "item_id", id, "error", err)
		if errors.Is(err, errArchiveLimit) {
			writeError(w, http.StatusRequestEntityTooLarge, "archive_limit_exceeded", "Asset folder exceeds archive limits.")
		} else {
			writeError(w, 500, "internal_error", "Could not create asset archive.")
		}
		return
	}
	st, err := archive.Stat()
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read asset archive.")
		return
	}
	zipName := filepath.Base(filepath.FromSlash(folder.RelativePath)) + ".zip"
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": zipName}))
	http.ServeContent(w, r, zipName, st.ModTime(), archive)
}
func safeRelativePath(path string) bool {
	if path == "" || filepath.IsAbs(path) || strings.Contains(path, "\\") {
		return false
	}
	for _, part := range strings.Split(filepath.ToSlash(path), "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
func (s *Server) content(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("itemID")
	items, e := s.items(r)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not resolve content.")
		return
	}
	var item *scanner.Item
	wantsLesson := strings.HasPrefix(r.URL.Path, "/api/v1/lessons/")
	for i := range items {
		if items[i].ID != id {
			continue
		}
		if wantsLesson && items[i].Type == "lesson" || !wantsLesson && (items[i].Type == "asset" || items[i].Type == "subtitle") {
			item = &items[i]
			break
		}
	}
	if item == nil {
		writeError(w, 404, "item_not_found", "Content not found.")
		return
	}
	s.contentAs(w, r, item, false)
}
func (s *Server) contentAs(w http.ResponseWriter, r *http.Request, item *scanner.Item, forceInline bool) {
	root, e := os.OpenRoot(s.cfg.ContentRoot)
	if e != nil {
		writeError(w, 404, "root_offline", "The content root is unavailable.")
		return
	}
	defer root.Close()
	if item.RelativePath == "" || filepath.IsAbs(item.RelativePath) || strings.Contains(item.RelativePath, "\\") {
		writeError(w, 404, "item_unavailable", "Content is unavailable.")
		return
	}
	for _, part := range strings.Split(item.RelativePath, "/") {
		if part == "" || part == "." || part == ".." {
			writeError(w, 404, "item_unavailable", "Content is unavailable.")
			return
		}
	}
	parts := strings.Split(item.RelativePath, "/")
	for i := 1; i <= len(parts); i++ {
		name := filepath.Join(parts[:i]...)
		info, err := root.Lstat(name)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			writeError(w, 404, "item_unavailable", "Content is unavailable.")
			return
		}
	}
	f, e := root.Open(filepath.FromSlash(item.RelativePath))
	if e != nil {
		writeError(w, 404, "item_unavailable", "Content is unavailable.")
		return
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		writeError(w, 404, "item_unavailable", "Content is unavailable.")
		return
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Sandbox active text/vector content, but don't sandbox browser-native PDF or
	// media viewers: Chromium-based browsers can block their internal viewer under
	// a document-level CSP sandbox.
	if activeDocument(item.MimeType, filepath.Ext(item.OriginalName)) {
		w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
	}
	w.Header().Set("Accept-Ranges", "bytes")
	contentDisposition := disposition(item)
	if forceInline {
		contentDisposition = mime.FormatMediaType("inline", map[string]string{"filename": filepath.Base(item.OriginalName)})
	}
	if strings.HasSuffix(r.URL.Path, "/download") {
		contentDisposition = mime.FormatMediaType("attachment", map[string]string{"filename": filepath.Base(item.OriginalName)})
	}
	w.Header().Set("Content-Disposition", contentDisposition)
	etag := fmt.Sprintf("W/\"%s-%d-%d\"", item.ID, st.Size(), st.ModTime().UnixNano())
	w.Header().Set("ETag", etag)
	if forceInline && (strings.HasPrefix(item.MimeType, "text/") || isCodeExtension(strings.ToLower(filepath.Ext(item.OriginalName)))) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	} else if item.MimeType != "" {
		w.Header().Set("Content-Type", item.MimeType)
	}
	s.logger.Debug("serving content", "item_id", item.ID, "name", item.OriginalName, "relative_path", item.RelativePath, "size_bytes", st.Size(), "range", r.Header.Get("Range"), "preview", forceInline)
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if r.Header.Get("If-None-Match") == "" {
		if modifiedSince, err := http.ParseTime(r.Header.Get("If-Modified-Since")); err == nil && !st.ModTime().After(modifiedSince.Add(time.Second-time.Nanosecond)) {
			w.WriteHeader(http.StatusNotModified)
			return
		}
	}
	if ifRange := r.Header.Get("If-Range"); ifRange != "" {
		valid := ifRange == etag && !strings.HasPrefix(ifRange, "W/")
		if !strings.HasPrefix(ifRange, "W/") && !strings.HasPrefix(ifRange, "\"") {
			if date, err := http.ParseTime(ifRange); err == nil {
				valid = !st.ModTime().After(date.Add(time.Second - time.Nanosecond))
			}
		}
		if !valid {
			r = r.Clone(r.Context())
			r.Header = r.Header.Clone()
			r.Header.Del("Range")
		}
	}
	http.ServeContent(w, r, item.OriginalName, st.ModTime(), f)
}
func etagMatches(header, current string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" || strings.TrimPrefix(candidate, "W/") == strings.TrimPrefix(current, "W/") {
			return true
		}
	}
	return false
}
func disposition(it *scanner.Item) string {
	kind := "attachment"
	typ := mediaType(it.MimeType)
	if !activeDocument(it.MimeType, filepath.Ext(it.OriginalName)) &&
		(typ == "application/pdf" || typ == "text/plain" || typ == "text/vtt" ||
			rasterImage(typ) || strings.HasPrefix(typ, "audio/") || strings.HasPrefix(typ, "video/")) {
		kind = "inline"
	}
	return mime.FormatMediaType(kind, map[string]string{"filename": filepath.Base(it.OriginalName)})
}
func below(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": message, "details": nil}})
}
func (s *Server) recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.logger.Error("http panic", "error", v)
				writeError(w, 500, "internal_error", "Internal server error.")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
func (s *Server) Run(ctx context.Context) error {
	srv := &http.Server{Addr: s.cfg.BindAddress, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	ln, err := net.Listen("tcp", s.cfg.BindAddress)
	if err != nil {
		return err
	}
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdown); err != nil {
			_ = srv.Close()
		}
	}()
	err = srv.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		<-shutdownDone
		return nil
	}
	return err
}
