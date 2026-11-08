package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
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
	cfg            config.Config
	store          *sqlite.Store
	logger         *slog.Logger
	mux            *http.ServeMux
	libraryID      string
	submitScan     func(string) bool
	thumbnailReady bool
}

var searchTokenPattern = regexp.MustCompile(`[\pL\pN_]+`)

func New(cfg config.Config, store *sqlite.Store, logger *slog.Logger) (*Server, error) {
	canonicalRoot, err := filepath.EvalSymlinks(cfg.ContentRoot)
	if err != nil {
		return nil, fmt.Errorf("resolve content root: %w", err)
	}
	cfg.ContentRoot = canonicalRoot
	if cfg.ThumbnailCacheDir == "" {
		cfg.ThumbnailCacheDir = filepath.Join(filepath.Dir(cfg.DatabasePath), "thumbnails")
		cfg.ThumbnailsEnabled = true // zero-value Configs retain the documented default
	}
	if cfg.ThumbnailMaxDim <= 0 {
		cfg.ThumbnailMaxDim = 320
	}
	s := &Server{cfg: cfg, store: store, logger: logger, mux: http.NewServeMux(), libraryID: "library_default", thumbnailReady: cfg.ThumbnailsEnabled && sqlite.ThumbnailToolsAvailable()}
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
	return s.logRequests(s.recover(s.securityHeaders(gzipCourseTree(s.mux))))
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
		writeJSON(w, 200, map[string]any{"name": "Medina", "version": "0.1.0", "apiVersion": "1", "capabilities": map[string]bool{"authentication": false, "transcoding": false, "progress": true, "fileWatching": !s.cfg.DisableWatching, "thumbnails": s.thumbnailReady}})
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
		courseItems, e := s.store.Courses(r.Context(), s.libraryID)
		if e != nil {
			writeError(w, 500, "internal_error", "Could not read indexed items.")
			return
		}
		profile := profileID(r)
		var profileProgress []sqlite.LessonProgress
		if profile != "" {
			profileProgress, e = s.store.AllLessonProgress(r.Context(), s.libraryID, profile)
			if e != nil {
				writeError(w, 500, "internal_error", "Could not read lesson progress.")
				return
			}
		}
		metadataItems := courseItems
		if profile != "" || s.thumbnailReady {
			metadataItems, e = s.items(r)
			if e != nil {
				writeError(w, 500, "internal_error", "Could not read indexed items.")
				return
			}
		}
		var courses []map[string]any
		for _, it := range courseItems {
			if it.Type == "course" {
				entry := map[string]any{"id": it.ID, "title": it.Title, "originalName": it.OriginalName, "position": it.Position}
				if url := s.courseThumbnail(metadataItems, it.ID); url != "" {
					entry["thumbnailUrl"] = url
				}
				if profile != "" {
					entry["progress"] = courseSummary(metadataItems, it.ID, profileProgress)
				}
				courses = append(courses, entry)
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
				entry := map[string]any{"id": it.ID, "type": it.Type, "title": it.Title, "originalName": it.OriginalName, "position": it.Position, "mimeType": it.MimeType}
				if url := s.courseThumbnail(items, it.ID); url != "" {
					entry["thumbnailUrl"] = url
				}
				if profile := profileID(r); profile != "" {
					records, err := s.store.AllLessonProgress(r.Context(), s.libraryID, profile)
					if err != nil {
						writeError(w, 500, "internal_error", "Could not read lesson progress.")
						return
					}
					entry["progress"] = courseSummary(items, it.ID, records)
				}
				writeJSON(w, 200, entry)
				return
			}
		}
		writeError(w, 404, "item_not_found", "Course not found.")
	})
	s.mux.HandleFunc("GET /api/v1/lessons/{itemID}/thumbnail", s.thumbnail)
	s.mux.HandleFunc("HEAD /api/v1/lessons/{itemID}/thumbnail", s.thumbnail)
	s.mux.HandleFunc("GET /api/v1/assets/{itemID}/thumbnail", s.thumbnail)
	s.mux.HandleFunc("HEAD /api/v1/assets/{itemID}/thumbnail", s.thumbnail)
	s.mux.HandleFunc("GET /api/v1/search", s.search)
	s.mux.HandleFunc("GET /api/v1/progress/recent", s.recentProgress)
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
	id := r.PathValue("courseID")
	items, e := s.store.CourseItems(r.Context(), s.libraryID, id)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
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
	sectionCount, lessonCount := 0, 0
	build = func(it scanner.Item) map[string]any {
		if it.Type == "section" {
			sectionCount++
		} else if it.Type == "lesson" {
			lessonCount++
		}
		obj := map[string]any{"id": it.ID, "type": it.Type, "title": it.Title, "originalName": it.OriginalName, "position": it.Position, "mimeType": it.MimeType, "extension": it.Extension, "sizeBytes": it.SizeBytes}
		if it.Type == "lesson" || it.Type == "asset" {
			if url := s.thumbnailURL(it); url != "" {
				obj["thumbnailUrl"] = url
			}
		}
		if it.Type == "course" {
			if url := s.courseThumbnail(items, it.ID); url != "" {
				obj["thumbnailUrl"] = url
			}
		}
		if it.Type == "subtitle" {
			obj["contentUrl"] = "/api/v1/assets/" + it.ID + "/content"
		}
		if it.Type == "lesson" {
			obj["mediaKind"] = it.MediaKind
			obj["mimeType"] = it.MimeType
			obj["streamUrl"] = "/api/v1/lessons/" + it.ID + "/content"
			if it.DurationSeconds > 0 {
				obj["durationSeconds"] = it.DurationSeconds
			}
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
	tree["summary"] = map[string]int{"sectionCount": sectionCount, "lessonCount": lessonCount}
	writeJSON(w, 200, tree)
}

func (s *Server) thumbnailURL(item scanner.Item) string {
	if !s.thumbnailReady || !thumbnailable(item) {
		return ""
	}
	if item.Type != "lesson" && item.Type != "asset" {
		return ""
	}
	path := sqlite.ThumbnailPath(s.cfg.ThumbnailCacheDir, item)
	if st, err := os.Stat(path); err != nil || !st.Mode().IsRegular() {
		return ""
	}
	if item.Type == "lesson" {
		return "/api/v1/lessons/" + item.ID + "/thumbnail"
	}
	return "/api/v1/assets/" + item.ID + "/thumbnail"
}

func thumbnailable(item scanner.Item) bool {
	if item.Type == "lesson" {
		return item.MediaKind == "video"
	}
	if item.Type != "asset" || activeDocument(item.MimeType, filepath.Ext(item.OriginalName)) {
		return false
	}
	return rasterImage(mediaType(item.MimeType)) || imageExtensions[strings.ToLower(filepath.Ext(item.OriginalName))]
}

func (s *Server) courseThumbnail(items []scanner.Item, courseID string) string {
	children := make(map[string][]scanner.Item)
	for _, item := range items {
		children[item.ParentID] = append(children[item.ParentID], item)
	}
	for parent := range children {
		sort.Slice(children[parent], func(i, j int) bool { return children[parent][i].Position < children[parent][j].Position })
	}
	var first func(string) string
	first = func(parent string) string {
		for _, child := range children[parent] {
			if child.Type == "lesson" {
				if url := s.thumbnailURL(child); url != "" {
					return url
				}
			}
			if child.Type == "section" {
				if url := first(child.ID); url != "" {
					return url
				}
			}
		}
		return ""
	}
	return first(courseID)
}

func percent(completed, total int) int {
	if total == 0 {
		return 0
	}
	return (completed*100 + total/2) / total
}

func courseSummary(items []scanner.Item, courseID string, records []sqlite.LessonProgress) map[string]int {
	ids := lessonIDsUnder(items, courseID)
	completed := 0
	for _, record := range records {
		if ids[record.ItemID] && record.Completed {
			completed++
		}
	}
	return map[string]int{"completedCount": completed, "totalCount": len(ids), "percent": percent(completed, len(ids))}
}

func (s *Server) thumbnail(w http.ResponseWriter, r *http.Request) {
	if !s.thumbnailReady {
		writeError(w, 404, "item_not_found", "Thumbnail not found.")
		return
	}
	id := r.PathValue("itemID")
	items, err := s.items(r)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not resolve thumbnail.")
		return
	}
	wantedType := "asset"
	if strings.HasPrefix(r.URL.Path, "/api/v1/lessons/") {
		wantedType = "lesson"
	}
	var item *scanner.Item
	for i := range items {
		if items[i].ID == id && items[i].Type == wantedType {
			item = &items[i]
			break
		}
	}
	if item == nil || !thumbnailable(*item) {
		writeError(w, 404, "item_not_found", "Thumbnail not found.")
		return
	}
	path := sqlite.ThumbnailPath(s.cfg.ThumbnailCacheDir, *item)
	f, err := os.Open(path)
	if err != nil {
		writeError(w, 404, "item_not_found", "Thumbnail not found.")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		writeError(w, 404, "item_not_found", "Thumbnail not found.")
		return
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, f); err != nil {
		writeError(w, 500, "internal_error", "Could not read thumbnail.")
		return
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		writeError(w, 500, "internal_error", "Could not read thumbnail.")
		return
	}
	etag := `"` + hex.EncodeToString(digest.Sum(nil)) + `"`
	w.Header().Set("Content-Type", "image/webp")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Header().Set("ETag", etag)
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	http.ServeContent(w, r, filepath.Base(path), st.ModTime(), f)
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeError(w, 400, "invalid_request", "q is required.")
		return
	}
	if len(query) > 512 {
		writeError(w, 400, "invalid_request", "q must be at most 512 bytes.")
		return
	}
	var tokens []string
	for _, token := range searchTokenPattern.FindAllString(query, -1) {
		tokens = append(tokens, token)
	}
	if len(tokens) == 0 {
		writeJSON(w, 200, map[string]any{"query": query, "items": []any{}})
		return
	}
	entryType := r.URL.Query().Get("type")
	if entryType != "" && entryType != "lesson" && entryType != "section" && entryType != "course" && entryType != "asset" {
		writeError(w, 400, "invalid_request", "type must be lesson, section, course, or asset.")
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, e := strconv.Atoi(raw)
		if e != nil || n < 1 {
			writeError(w, 400, "invalid_request", "limit must be an integer from 1 to 100.")
			return
		}
		limit = min(n, 100)
	}
	hits, err := s.store.SearchEntries(r.Context(), s.libraryID, sqlite.PrefixQuery(strings.Join(tokens, " ")), entryType, limit)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not search the library.")
		return
	}
	all, err := s.items(r)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	byID := make(map[string]scanner.Item, len(all))
	for _, item := range all {
		byID[item.ID] = item
	}
	var out []map[string]any
	for _, hit := range hits {
		item, ok := byID[hit.ItemID]
		if !ok {
			continue
		}
		courseID, coursePath := courseBreadcrumb(all, item.ID)
		entry := map[string]any{"id": hit.ItemID, "type": hit.Type, "title": hit.Title, "originalName": hit.OriginalName, "courseId": courseID, "coursePath": coursePath}
		if hit.Type == "lesson" {
			entry["streamUrl"] = "/api/v1/lessons/" + hit.ItemID + "/content"
		}
		thumbnailURL := s.thumbnailURL(item)
		if hit.Type == "course" {
			thumbnailURL = s.courseThumbnail(all, item.ID)
		}
		if thumbnailURL != "" {
			entry["thumbnailUrl"] = thumbnailURL
		}
		out = append(out, entry)
	}
	if out == nil {
		out = []map[string]any{}
	}
	writeJSON(w, 200, map[string]any{"query": query, "items": out})
}

func courseBreadcrumb(items []scanner.Item, id string) (string, string) {
	byID := make(map[string]scanner.Item, len(items))
	for _, item := range items {
		byID[item.ID] = item
	}
	var chain []scanner.Item
	current := byID[id]
	for current.ID != "" {
		if current.Type == "course" || current.Type == "section" {
			chain = append(chain, current)
		}
		current = byID[current.ParentID]
	}
	var titles []string
	courseID := ""
	for i := len(chain) - 1; i >= 0; i-- {
		titles = append(titles, chain[i].Title)
		if chain[i].Type == "course" {
			courseID = chain[i].ID
		}
	}
	return courseID, strings.Join(titles, " / ")
}

func (s *Server) recentProgress(w http.ResponseWriter, r *http.Request) {
	profile := profileID(r)
	if profile == "" {
		writeError(w, 400, "invalid_request", "A X-Medina-Profile header is required.")
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, e := strconv.Atoi(raw)
		if e != nil || n < 1 {
			writeError(w, 400, "invalid_request", "limit must be an integer from 1 to 100.")
			return
		}
		limit = min(n, 100)
	}
	include := false
	if raw := r.URL.Query().Get("includeCompleted"); raw != "" {
		value, e := strconv.ParseBool(raw)
		if e != nil {
			writeError(w, 400, "invalid_request", "includeCompleted must be true or false.")
			return
		}
		include = value
	}
	records, err := s.store.RecentLessonProgress(r.Context(), s.libraryID, profile, include, limit)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not retrieve recent progress.")
		return
	}
	items, err := s.items(r)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	byID := make(map[string]scanner.Item, len(items))
	for _, item := range items {
		byID[item.ID] = item
	}
	var out []map[string]any
	for _, record := range records {
		item, ok := byID[record.ItemID]
		if !ok {
			continue
		}
		courseID, path := courseBreadcrumb(items, item.ID)
		entry := map[string]any{"itemId": item.ID, "title": item.Title, "courseId": courseID, "coursePath": path, "positionSeconds": record.PositionSeconds, "durationSeconds": record.DurationSeconds, "completed": record.Completed, "updatedAt": record.UpdatedAt.UTC().Format(time.RFC3339Nano), "streamUrl": "/api/v1/lessons/" + item.ID + "/content"}
		if url := s.thumbnailURL(item); url != "" {
			entry["thumbnailUrl"] = url
		}
		out = append(out, entry)
	}
	if out == nil {
		out = []map[string]any{}
	}
	writeJSON(w, 200, map[string]any{"items": out})
}

// lessonIDsUnder returns the set of lesson item IDs anywhere beneath a course.
// Progress is only tracked for lessons, so this bounds what a course-progress
// response may contain.
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
	Completed       *bool   `json:"completed"`
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
	duration := payload.DurationSeconds
	if duration <= 0 {
		for _, item := range items {
			if item.ID == id {
				duration = item.DurationSeconds
				break
			}
		}
	}
	previous, hasPrevious, err := s.store.LessonProgressFor(r.Context(), s.libraryID, profile, id)
	if err != nil {
		writeError(w, 500, "internal_error", "Could not read lesson progress.")
		return
	}
	completed := false
	if hasPrevious {
		completed = previous.Completed
	}
	if payload.Completed != nil {
		completed = *payload.Completed
	} else if duration > 0 && payload.PositionSeconds >= duration*0.95 {
		completed = true
	}
	record := sqlite.LessonProgress{
		ItemID:          id,
		PositionSeconds: payload.PositionSeconds,
		DurationSeconds: duration,
		Completed:       completed,
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
	id := r.PathValue("courseID")
	items, e := s.store.CourseItems(r.Context(), s.libraryID, id)
	if e != nil {
		writeError(w, 500, "internal_error", "Could not read indexed items.")
		return
	}
	if len(items) == 0 {
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
		"percent":        percent(completedCount, len(lessonIDs)),
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
	// A strong validator: size + mtime uniquely identify these exact bytes.
	// It must be strong (not W/) so http.ServeContent can honor If-Range for
	// range requests — libVLC seeks with Range + If-Range, and a weak ETag
	// makes every such conditional fail, collapsing the seek to a full-file
	// 200 that the demuxer rejects as "Invalid data".
	etag := fmt.Sprintf("\"%s-%d-%d\"", item.ID, st.Size(), st.ModTime().UnixNano())
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
	// http.ServeContent handles Range, If-Range, and 416 per RFC 7233 using
	// the strong ETag and modtime above. Do not pre-process If-Range here:
	// stripping Range on a conditional miss would turn a seek into a full-file
	// 200 that media demuxers reject.
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
