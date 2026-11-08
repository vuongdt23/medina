package sqlite

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"medina/internal/scanner"
)

// ThumbnailPath is deterministic for one durable item identity and source
// revision. The thumbnail cache is disposable and never resides in the library.
func ThumbnailPath(dir string, item scanner.Item) string {
	name := fmt.Sprintf("%s-%d-%d.webp", item.ID, item.SizeBytes, item.ModifiedAt.UnixNano())
	return filepath.Join(dir, name)
}

func ThumbnailToolsAvailable() bool {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		return false
	}
	if supportsWebPEncoder(ffmpeg) {
		return true
	}
	_, err = exec.LookPath("cwebp")
	return err == nil
}

func supportsWebPEncoder(ffmpeg string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-encoders").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 1 && fields[1] == "libwebp" {
			return true
		}
	}
	return false
}

func GenerateThumbnails(ctx context.Context, root, cacheDir string, maxDim int, items []scanner.Item) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil || cacheDir == "" {
		return
	}
	webpEncoder := supportsWebPEncoder(ffmpeg)
	cwebp, _ := exec.LookPath("cwebp")
	if !webpEncoder && cwebp == "" {
		return
	}
	if maxDim < 16 {
		maxDim = 320
	}
	if err := os.MkdirAll(cacheDir, 0o750); err != nil {
		return
	}
	var candidates []scanner.Item
	for _, item := range items {
		if item.Type == "lesson" && item.MediaKind == "video" || item.Type == "asset" && isThumbnailImage(item) {
			if _, err := os.Stat(ThumbnailPath(cacheDir, item)); err != nil {
				candidates = append(candidates, item)
			}
		}
	}
	jobs := make(chan scanner.Item)
	workers := min(4, len(candidates))
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for item := range jobs {
				if ctx.Err() != nil {
					continue
				}
				generateOneThumbnail(ctx, ffmpeg, cwebp, webpEncoder, root, cacheDir, maxDim, item)
			}
		}()
	}
	for _, item := range candidates {
		jobs <- item
	}
	close(jobs)
	wg.Wait()
}

func isThumbnailImage(item scanner.Item) bool {
	ext := strings.ToLower(filepath.Ext(item.OriginalName))
	switch ext {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".avif", ".tif", ".tiff", ".ico", ".heic", ".heif":
		return true
	case ".svg", ".svgz", ".html", ".htm", ".xhtml":
		return false
	}
	return strings.HasPrefix(item.MimeType, "image/") && item.MimeType != "image/svg+xml"
}

func generateOneThumbnail(ctx context.Context, ffmpeg, cwebp string, webpEncoder bool, root, cacheDir string, maxDim int, item scanner.Item) {
	rel := filepath.FromSlash(item.RelativePath)
	if rel == "" || filepath.IsAbs(rel) {
		return
	}
	for _, part := range strings.Split(filepath.ToSlash(item.RelativePath), "/") {
		if part == "" || part == "." || part == ".." {
			return
		}
	}
	root = filepath.Clean(root)
	current := root
	for _, part := range strings.Split(filepath.ToSlash(item.RelativePath), "/") {
		current = filepath.Join(current, filepath.FromSlash(part))
		st, err := os.Lstat(current)
		if err != nil || st.Mode()&os.ModeSymlink != 0 {
			return
		}
	}
	input := filepath.Join(root, rel)
	output := ThumbnailPath(cacheDir, item)
	tmp, err := os.CreateTemp(cacheDir, ".thumbnail-*.webp")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	_ = tmp.Close()
	_ = os.Remove(tmpName)
	defer os.Remove(tmpName)
	args := []string{"-v", "error", "-nostdin", "-y"}
	if item.Type == "lesson" && item.DurationSeconds > 0 {
		args = append(args, "-ss", fmt.Sprintf("%.3f", item.DurationSeconds*0.1))
	}
	args = append(args, "-i", input, "-frames:v", "1", "-vf", fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=decrease", maxDim, maxDim))
	if webpEncoder {
		args = append(args, "-c:v", "libwebp", "-quality", "75", tmpName)
	} else {
		png, err := os.CreateTemp(cacheDir, ".thumbnail-*.png")
		if err != nil {
			return
		}
		pngName := png.Name()
		_ = png.Close()
		_ = os.Remove(pngName)
		defer os.Remove(pngName)
		args = append(args, pngName)
		cmdCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
		if exec.CommandContext(cmdCtx, ffmpeg, args...).Run() != nil {
			cancel()
			return
		}
		cancel()
		convertCtx, convertCancel := context.WithTimeout(ctx, 30*time.Second)
		defer convertCancel()
		if exec.CommandContext(convertCtx, cwebp, "-quiet", "-q", "75", pngName, "-o", tmpName).Run() != nil {
			return
		}
		if st, err := os.Stat(tmpName); err != nil || st.Size() == 0 {
			return
		}
		_ = os.Rename(tmpName, output)
		return
	}
	cmdCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	if exec.CommandContext(cmdCtx, ffmpeg, args...).Run() != nil {
		return
	}
	if st, err := os.Stat(tmpName); err != nil || st.Size() == 0 {
		return
	}
	_ = os.Rename(tmpName, output)
}
