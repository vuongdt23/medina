package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	BindAddress          string
	DatabasePath         string
	ContentRoot          string
	LibraryName          string
	LogLevel             string
	ScanInterval         time.Duration
	ScanDebounce         time.Duration
	ScanWorkers          int
	ScanDirectoryWorkers int
	DisableWatching      bool
	ThumbnailsEnabled    bool
	ThumbnailMaxDim      int
	ThumbnailCacheDir    string
}

func Load() (Config, error) {
	cfg := Config{
		BindAddress:  env("BIND_ADDRESS", "127.0.0.1:17843"),
		DatabasePath: env("DATABASE_PATH", "./data/course-media.sqlite"),
		ContentRoot:  os.Getenv("CONTENT_ROOT"),
		LibraryName:  env("LIBRARY_NAME", "Courses"),
		LogLevel:     strings.ToLower(env("LOG_LEVEL", "info")),
		ScanInterval: 6 * time.Hour,
		ScanDebounce: 2 * time.Second,
	}
	if cfg.ContentRoot == "" {
		return Config{}, fmt.Errorf("CONTENT_ROOT is required")
	}
	if _, _, err := net.SplitHostPort(cfg.BindAddress); err != nil {
		return Config{}, fmt.Errorf("invalid BIND_ADDRESS: %w", err)
	}
	if cfg.DatabasePath == "" {
		return Config{}, fmt.Errorf("DATABASE_PATH cannot be empty")
	}
	if cfg.LibraryName == "" {
		return Config{}, fmt.Errorf("LIBRARY_NAME cannot be empty")
	}
	var err error
	if cfg.ScanInterval, err = time.ParseDuration(env("SCAN_INTERVAL", "6h")); err != nil || cfg.ScanInterval <= 0 {
		return Config{}, fmt.Errorf("SCAN_INTERVAL must be a positive duration, e.g. 6h")
	}
	if cfg.ScanDebounce, err = time.ParseDuration(env("SCAN_DEBOUNCE", "2s")); err != nil || cfg.ScanDebounce <= 0 {
		return Config{}, fmt.Errorf("SCAN_DEBOUNCE must be a positive duration, e.g. 2s")
	}
	if cfg.ScanWorkers, err = strconv.Atoi(env("SCAN_WORKERS", "8")); err != nil || cfg.ScanWorkers < 1 || cfg.ScanWorkers > 64 {
		return Config{}, fmt.Errorf("SCAN_WORKERS must be an integer between 1 and 64")
	}
	if cfg.ScanDirectoryWorkers, err = strconv.Atoi(env("SCAN_DIRECTORY_WORKERS", "4")); err != nil || cfg.ScanDirectoryWorkers < 1 || cfg.ScanDirectoryWorkers > 64 {
		return Config{}, fmt.Errorf("SCAN_DIRECTORY_WORKERS must be an integer between 1 and 64")
	}
	watchEnabled, err := strconv.ParseBool(env("SCAN_WATCH", "true"))
	if err != nil {
		return Config{}, fmt.Errorf("SCAN_WATCH must be true or false")
	}
	cfg.DisableWatching = !watchEnabled
	switch cfg.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return Config{}, fmt.Errorf("invalid LOG_LEVEL %q", cfg.LogLevel)
	}
	root, err := filepath.Abs(cfg.ContentRoot)
	if err != nil {
		return Config{}, fmt.Errorf("resolve CONTENT_ROOT: %w", err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return Config{}, fmt.Errorf("resolve CONTENT_ROOT: %w", err)
	}
	st, err := os.Stat(root)
	if err != nil {
		return Config{}, fmt.Errorf("stat CONTENT_ROOT: %w", err)
	}
	if !st.IsDir() {
		return Config{}, fmt.Errorf("CONTENT_ROOT is not a directory")
	}
	cfg.ContentRoot = root
	if !filepath.IsAbs(cfg.DatabasePath) {
		cfg.DatabasePath, err = filepath.Abs(cfg.DatabasePath)
		if err != nil {
			return Config{}, err
		}
	}
	thumbnailEnabled, err := strconv.ParseBool(env("THUMBNAILS", "true"))
	if err != nil {
		return Config{}, fmt.Errorf("THUMBNAILS must be true or false")
	}
	cfg.ThumbnailsEnabled = thumbnailEnabled
	if cfg.ThumbnailMaxDim, err = strconv.Atoi(env("THUMBNAIL_MAX_DIM", "320")); err != nil || cfg.ThumbnailMaxDim < 16 || cfg.ThumbnailMaxDim > 4096 {
		return Config{}, fmt.Errorf("THUMBNAIL_MAX_DIM must be an integer between 16 and 4096")
	}
	cacheDir := env("THUMBNAIL_CACHE_DIR", filepath.Join(filepath.Dir(cfg.DatabasePath), "thumbnails"))
	if !filepath.IsAbs(cacheDir) {
		cacheDir, err = filepath.Abs(cacheDir)
		if err != nil {
			return Config{}, err
		}
	}
	cacheDir, err = resolveFuturePath(cacheDir)
	if err != nil {
		return Config{}, fmt.Errorf("resolve THUMBNAIL_CACHE_DIR: %w", err)
	}
	if rel, relErr := filepath.Rel(cfg.ContentRoot, cacheDir); relErr == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return Config{}, fmt.Errorf("THUMBNAIL_CACHE_DIR must be outside CONTENT_ROOT")
	}
	cfg.ThumbnailCacheDir = cacheDir
	return cfg, nil
}

func resolveFuturePath(path string) (string, error) {
	path, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return "", err
	}
	current := path
	var suffix []string
	for {
		if _, statErr := os.Lstat(current); statErr == nil {
			resolved, err := filepath.EvalSymlinks(current)
			if err != nil {
				return "", err
			}
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return filepath.Clean(resolved), nil
		} else if !os.IsNotExist(statErr) {
			return "", statErr
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("no existing parent for %s", path)
		}
		suffix = append(suffix, filepath.Base(current))
		current = parent
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func IsLoopbackBind(address string) bool {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	if _, err := strconv.Atoi(port); err != nil {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
