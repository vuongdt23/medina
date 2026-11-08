package httpapi

import (
	"compress/gzip"
	"net/http"
	"strconv"
	"strings"
)

// gzipCourseTree compresses the large recursive tree response without adding
// buffering or wrapper behavior to streaming lesson and asset endpoints.
func gzipCourseTree(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead || !strings.HasPrefix(r.URL.Path, "/api/v1/courses/") || !strings.HasSuffix(r.URL.Path, "/tree") || !acceptsGzip(r.Header.Values("Accept-Encoding")) {
			next.ServeHTTP(w, r)
			return
		}
		writer := &gzipResponseWriter{ResponseWriter: w}
		defer writer.Close()
		next.ServeHTTP(writer, r)
	})
}

type gzipResponseWriter struct {
	http.ResponseWriter
	gzipWriter *gzip.Writer
	started    bool
}

func (w *gzipResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *gzipResponseWriter) WriteHeader(status int) {
	if w.started {
		return
	}
	w.started = true
	w.Header().Set("Content-Encoding", "gzip")
	w.Header().Del("Content-Length")
	addVary(w.Header(), "Accept-Encoding")
	w.gzipWriter = gzip.NewWriter(w.ResponseWriter)
	w.ResponseWriter.WriteHeader(status)
}

func (w *gzipResponseWriter) Write(p []byte) (int, error) {
	if !w.started {
		w.WriteHeader(http.StatusOK)
	}
	return w.gzipWriter.Write(p)
}

func (w *gzipResponseWriter) Flush() {
	if !w.started {
		w.WriteHeader(http.StatusOK)
	}
	_ = w.gzipWriter.Flush()
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *gzipResponseWriter) Close() error {
	if w.gzipWriter == nil {
		return nil
	}
	return w.gzipWriter.Close()
}

func addVary(header http.Header, value string) {
	for _, current := range header.Values("Vary") {
		for _, part := range strings.Split(current, ",") {
			if strings.EqualFold(strings.TrimSpace(part), value) {
				return
			}
		}
	}
	header.Add("Vary", value)
}

func acceptsGzip(headers []string) bool {
	gzipQuality := -1.0
	wildcardQuality := -1.0
	for _, header := range headers {
		for _, token := range strings.Split(header, ",") {
			parts := strings.Split(token, ";")
			encoding := strings.TrimSpace(parts[0])
			quality := 1.0
			for _, parameter := range parts[1:] {
				name, value, ok := strings.Cut(strings.TrimSpace(parameter), "=")
				if !ok || !strings.EqualFold(name, "q") {
					continue
				}
				parsed, err := strconv.ParseFloat(value, 64)
				if err != nil || parsed < 0 || parsed > 1 {
					quality = 0
				} else {
					quality = parsed
				}
			}
			switch {
			case strings.EqualFold(encoding, "gzip"):
				gzipQuality = quality
			case encoding == "*":
				wildcardQuality = quality
			}
		}
	}
	if gzipQuality >= 0 {
		return gzipQuality > 0
	}
	return wildcardQuality > 0
}
