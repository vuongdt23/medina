package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestThumbnailConfiguration(t *testing.T) {
	root := t.TempDir()
	db := filepath.Join(t.TempDir(), "library.sqlite")
	t.Setenv("CONTENT_ROOT", root)
	t.Setenv("DATABASE_PATH", db)
	t.Setenv("THUMBNAILS", "true")
	t.Setenv("THUMBNAIL_MAX_DIM", "640")
	t.Setenv("THUMBNAIL_CACHE_DIR", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	expectedCache, err := resolveFuturePath(filepath.Join(filepath.Dir(db), "thumbnails"))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.ThumbnailsEnabled || cfg.ThumbnailMaxDim != 640 || cfg.ThumbnailCacheDir != expectedCache {
		t.Fatalf("unexpected thumbnail config: %+v", cfg)
	}

	t.Setenv("THUMBNAILS", "false")
	cfg, err = Load()
	if err != nil || cfg.ThumbnailsEnabled {
		t.Fatalf("disable thumbnails: %+v, %v", cfg, err)
	}
	for _, dim := range []string{"0", "4097", "invalid"} {
		t.Setenv("THUMBNAIL_MAX_DIM", dim)
		if _, err = Load(); err == nil {
			t.Fatalf("accepted THUMBNAIL_MAX_DIM=%q", dim)
		}
	}
	t.Setenv("THUMBNAIL_MAX_DIM", "320")
	t.Setenv("THUMBNAIL_CACHE_DIR", filepath.Join(root, "cache"))
	if _, err = Load(); err == nil {
		t.Fatal("accepted thumbnail cache inside content root")
	}
	if err := os.Mkdir(filepath.Join(root, "cache"), 0o755); err != nil {
		t.Fatal(err)
	}

	outside := t.TempDir()
	link := filepath.Join(outside, "cache-link")
	if err := os.Symlink(filepath.Join(root, "cache"), link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	t.Setenv("THUMBNAIL_CACHE_DIR", link)
	if _, err = Load(); err == nil {
		t.Fatal("accepted symlinked thumbnail cache inside content root")
	}
}

func TestDefaultBindAddressAndOverride(t *testing.T) {
	t.Setenv("CONTENT_ROOT", t.TempDir())
	t.Setenv("BIND_ADDRESS", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.BindAddress != "127.0.0.1:17843" {
		t.Fatalf("default bind address = %q", cfg.BindAddress)
	}

	t.Setenv("BIND_ADDRESS", "127.0.0.1:19001")
	cfg, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.BindAddress != "127.0.0.1:19001" {
		t.Fatalf("custom bind address = %q", cfg.BindAddress)
	}
}

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
