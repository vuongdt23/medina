package sqlite

import (
	"context"
	"math"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"medina/internal/scanner"
)

const durationProbeTimeout = 15 * time.Second

// reuseLessonDuration keeps metadata across library scans when the indexed
// file identity and filesystem metadata are unchanged. This avoids launching
// ffprobe for every lesson on every periodic scan.
func reuseLessonDuration(item *scanner.Item, previous map[string]scanner.Item) {
	if item.Type != "lesson" {
		return
	}
	old, ok := previous[item.ID]
	if !ok || old.Type != "lesson" || old.SizeBytes != item.SizeBytes || !old.ModifiedAt.Equal(item.ModifiedAt) {
		return
	}
	item.DurationSeconds = old.DurationSeconds
}

// probeMissingLessonDurations reads container metadata locally using ffprobe.
// Probe work is bounded and optional: servers without ffprobe keep returning
// lessons without duration metadata rather than failing the library scan.
func probeMissingLessonDurations(ctx context.Context, root string, items []scanner.Item, previous map[string]scanner.Item) {
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		return
	}
	var candidates []int
	for i := range items {
		if items[i].Type != "lesson" {
			continue
		}
		reuseLessonDuration(&items[i], previous)
		if items[i].DurationSeconds <= 0 || math.IsNaN(items[i].DurationSeconds) || math.IsInf(items[i].DurationSeconds, 0) {
			candidates = append(candidates, i)
		}
	}
	if len(candidates) == 0 {
		return
	}
	workers := min(4, min(runtime.GOMAXPROCS(0), len(candidates)))
	jobs := make(chan int)
	var wg sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			defer wg.Done()
			for i := range jobs {
				probeCtx, cancel := context.WithTimeout(ctx, durationProbeTimeout)
				path := filepath.Join(root, filepath.FromSlash(items[i].RelativePath))
				items[i].DurationSeconds = readMediaDuration(probeCtx, ffprobe, path)
				cancel()
			}
		}()
	}
	for _, i := range candidates {
		select {
		case jobs <- i:
		case <-ctx.Done():
			close(jobs)
			wg.Wait()
			return
		}
	}
	close(jobs)
	wg.Wait()
}

func readMediaDuration(ctx context.Context, ffprobe, path string) float64 {
	cmd := exec.CommandContext(ctx, ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path)
	output, err := cmd.Output()
	if err != nil {
		return 0
	}
	return parseMediaDuration(output)
}

func parseMediaDuration(output []byte) float64 {
	seconds, err := strconv.ParseFloat(strings.TrimSpace(string(output)), 64)
	if err != nil || seconds <= 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return 0
	}
	return seconds
}
