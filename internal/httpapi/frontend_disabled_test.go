//go:build no_frontend

package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAPIOnlyBuildDoesNotServeFrontend(t *testing.T) {
	server, _, _ := regressionServer(t, nil)
	for _, path := range []string{
		"/", "/index.html", "/assets/index.js", "/swagger", "/swagger/",
		"/swagger-ui.css", "/swagger-ui-bundle.js", "/api-docs", "/api-docs/",
	} {
		for _, method := range []string{http.MethodGet, http.MethodHead} {
			rec := httptest.NewRecorder()
			server.Handler().ServeHTTP(rec, httptest.NewRequest(method, path, nil))
			if rec.Code != http.StatusNotFound {
				t.Errorf("%s %s: status=%d want 404", method, path, rec.Code)
			}
		}
	}
	for _, path := range []string{"/openapi.yaml", "/api-docs/openapi.yaml", "/api/v1/health", "/api/v1/system/info", "/api/v1/libraries", "/api/v1/index/status"} {
		rec := httptest.NewRecorder()
		server.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s: status=%d want 200", path, rec.Code)
		}
	}
	server.SetScanSubmitter(func(string) bool { return true })
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/index/scan", nil))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("manual scan status=%d want 202", rec.Code)
	}
}
