package config

import (
	"testing"
)

func TestScanSettings(t *testing.T) {
	t.Setenv("CONTENT_ROOT", t.TempDir())
	t.Setenv("SCAN_WORKERS", "8")
	t.Setenv("SCAN_WATCH", "true")
	t.Setenv("SCAN_DIRECTORY_WORKERS", "4")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ScanWorkers != 8 || cfg.ScanDirectoryWorkers != 4 || cfg.DisableWatching {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	for _, raw := range []string{"0", "65", "invalid"} {
		t.Setenv("SCAN_DIRECTORY_WORKERS", raw)
		if _, err = Load(); err == nil {
			t.Fatalf("accepted SCAN_DIRECTORY_WORKERS=%s", raw)
		}
	}
	t.Setenv("SCAN_DIRECTORY_WORKERS", "4")
	t.Setenv("SCAN_WATCH", "false")
	cfg, err = Load()
	if err != nil || !cfg.DisableWatching {
		t.Fatalf("disabled watcher: %+v, %v", cfg, err)
	}
	for _, raw := range []string{"0", "65", "not-a-number"} {
		t.Setenv("SCAN_WORKERS", raw)
		if _, err = Load(); err == nil {
			t.Fatalf("accepted SCAN_WORKERS=%s", raw)
		}
	}
	t.Setenv("SCAN_WORKERS", "1")
	t.Setenv("SCAN_WATCH", "invalid")
	if _, err = Load(); err == nil {
		t.Fatal("accepted invalid SCAN_WATCH")
	}
}
