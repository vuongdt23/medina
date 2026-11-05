package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"medina/internal/config"
	"medina/internal/httpapi"
	"medina/internal/indexer"
	"medina/internal/scanner"
	"medina/internal/store/sqlite"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("configuration error", "error", err)
		os.Exit(2)
	}
	level := slog.LevelInfo
	if cfg.LogLevel == "debug" {
		level = slog.LevelDebug
	} else if cfg.LogLevel == "warn" {
		level = slog.LevelWarn
	} else if cfg.LogLevel == "error" {
		level = slog.LevelError
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)
	logger.Info("configuration loaded",
		"bind", cfg.BindAddress,
		"content_root", cfg.ContentRoot,
		"database_path", cfg.DatabasePath,
		"library_name", cfg.LibraryName,
		"log_level", cfg.LogLevel,
	)
	if !config.IsLoopbackBind(cfg.BindAddress) {
		logger.Warn("server is exposed beyond loopback; API and file endpoints have no authentication", "bind", cfg.BindAddress)
	}
	if err := os.MkdirAll(filepath.Dir(cfg.DatabasePath), 0o750); err != nil {
		logger.Error("create database directory", "error", err)
		os.Exit(1)
	}
	store, err := sqlite.Open(cfg.DatabasePath)
	if err != nil {
		logger.Error("open database", "error", err)
		os.Exit(1)
	}
	defer store.Close()
	server, err := httpapi.New(cfg, store, logger)
	if err != nil {
		logger.Error("initialize server", "error", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var monitor *indexer.Monitor
	scanLibrary := func(scanCtx context.Context, reason string) error {
		scanStarted := time.Now()
		logger.Info("content scan started", "root", cfg.ContentRoot, "reason", reason)
		lastProgressLog := time.Now()
		generation, scanErr := store.ScanWithOptions(scanCtx, "library_default", cfg.ContentRoot, scanner.Options{
			Workers:          cfg.ScanWorkers,
			DirectoryWorkers: cfg.ScanDirectoryWorkers,
			OnDirectory:      func(path string) { monitor.WatchDirectory(path) },
			OnProgress: func(p scanner.Progress) {
				if time.Since(lastProgressLog) >= 5*time.Second {
					logger.Debug("scan progress", "reason", reason, "phase", p.Phase, "operation", p.CurrentOperation, "active_directory_reads", p.ActiveDirectoryReads, "active_metadata_reads", p.ActiveMetadataReads, "directories_read", p.DirectoriesRead, "entries_visited", p.EntriesVisited, "current_directory", p.CurrentDirectory, "duration_ms", p.ElapsedMS, "enumeration_ms", p.EnumerationMS, "metadata_ms", p.MetadataMS, "persistence_ms", p.PersistenceMS)
					lastProgressLog = time.Now()
				}
			},
		}, nil)
		if scanErr != nil {
			logger.Error("content scan failed", "error", scanErr, "reason", reason, "duration_ms", time.Since(scanStarted).Milliseconds())
			return scanErr
		}
		items, itemsErr := store.Items(scanCtx, "library_default")
		if itemsErr != nil {
			logger.Warn("read scanned item details", "error", itemsErr)
		}
		counts := make(map[string]int)
		var totalBytes int64
		for _, item := range items {
			counts[item.Type]++
			totalBytes += item.SizeBytes
		}
		logger.Info("content scan completed", "generation", generation, "reason", reason, "item_count", len(items), "type_counts", counts, "total_bytes", totalBytes, "duration_ms", time.Since(scanStarted).Milliseconds())
		return nil
	}
	coordinator := &indexer.Coordinator{RunScan: scanLibrary}
	server.SetScanSubmitter(func(reason string) bool {
		started, _ := coordinator.Submit(ctx, reason)
		return started
	})
	monitor = &indexer.Monitor{
		DisableWatching: cfg.DisableWatching,
		Root:            cfg.ContentRoot,
		Interval:        cfg.ScanInterval,
		Debounce:        cfg.ScanDebounce,
		Logger:          logger,
		Scan:            coordinator.Wait,
	}
	monitorDone := make(chan struct{})
	go func() {
		defer close(monitorDone)
		if err := monitor.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			logger.Error("library monitor stopped", "error", err)
			stop()
		}
	}()
	logger.Info("Medina listening", "bind", cfg.BindAddress, "root", strings.TrimSpace(cfg.ContentRoot), "scan_interval", cfg.ScanInterval.String(), "scan_debounce", cfg.ScanDebounce.String())
	serveErr := server.Run(ctx)
	stop()
	<-monitorDone
	coordinator.WaitForIdle() // scans may still be joining blocked filesystem calls
	if serveErr != nil && !errors.Is(serveErr, context.Canceled) {
		logger.Error("server stopped", "error", serveErr)
		_ = store.Close()
		os.Exit(1)
	}
}
