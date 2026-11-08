package httpapi

import "testing"

func TestAcceptsGzipNegotiation(t *testing.T) {
	for _, tc := range []struct {
		header string
		want   bool
	}{{"gzip", true}, {"br, gzip;q=0.8", true}, {"gzip;q=0", false}, {"br", false}, {"*;q=0.5", true}, {"gzip;q=1.2", false}} {
		if got := acceptsGzip([]string{tc.header}); got != tc.want {
			t.Errorf("acceptsGzip(%q) = %v, want %v", tc.header, got, tc.want)
		}
	}
}
