//go:build !no_frontend

package httpapi

import (
	"embed"
	"io/fs"
	"net/http"
)

const frontendBundled = true

//go:embed webdist/*
var web embed.FS

//go:embed swagger.html
var swaggerHTML []byte

func (s *Server) frontendRoutes() {
	s.mux.HandleFunc("GET /api-docs", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/api-docs/", http.StatusTemporaryRedirect)
	})
	s.mux.HandleFunc("GET /api-docs/", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/swagger/", http.StatusTemporaryRedirect)
	})
	s.mux.HandleFunc("GET /swagger/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(swaggerHTML)
	})
	s.mux.HandleFunc("GET /swagger-ui.css", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		data, err := web.ReadFile("webdist/swagger-ui.css")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	})
	s.mux.HandleFunc("GET /swagger-ui-bundle.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		data, err := web.ReadFile("webdist/swagger-ui-bundle.js")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	})
	static, err := fs.Sub(web, "webdist")
	if err == nil {
		s.mux.Handle("GET /", http.FileServer(http.FS(static)))
	} else {
		s.mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "web client not built; run make web", http.StatusServiceUnavailable)
		})
	}
}
