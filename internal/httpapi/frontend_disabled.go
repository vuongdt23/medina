//go:build no_frontend

package httpapi

const frontendBundled = false

// API-only builds embed no frontend files and register no UI routes.
func (s *Server) frontendRoutes() {}
