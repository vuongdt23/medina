package httpapi

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

var errArchiveLimit = errors.New("archive limit exceeded")

type archiveLimits struct {
	files                        int
	sourceBytes, compressedBytes int64
}

type limitedArchiveWriter struct {
	writer    io.Writer
	remaining int64
}

func (w *limitedArchiveWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		return 0, fmt.Errorf("%w: compressed size", errArchiveLimit)
	}
	n, err := w.writer.Write(p)
	w.remaining -= int64(n)
	return n, err
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

func buildAssetArchive(ctx context.Context, directory *os.Root, output io.Writer, limits archiveLimits) error {
	zipWriter := zip.NewWriter(&limitedArchiveWriter{writer: output, remaining: limits.compressedBytes})
	var entries int
	var totalBytes int64
	err := fs.WalkDir(directory.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if walkErr != nil {
			return walkErr
		}
		if name == "." || entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if !safeRelativePath(name) {
			return fmt.Errorf("unsafe archive path")
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		entries++
		if entries > limits.files {
			return fmt.Errorf("%w: file count", errArchiveLimit)
		}
		remaining := limits.sourceBytes - totalBytes
		if info.Size() > remaining {
			return fmt.Errorf("%w: source size", errArchiveLimit)
		}
		file, err := directory.Open(name)
		if err != nil {
			return err
		}
		defer file.Close()
		header := &zip.FileHeader{Name: filepath.ToSlash(name), Method: zip.Deflate}
		header.SetModTime(info.ModTime())
		entryWriter, err := zipWriter.CreateHeader(header)
		if err != nil {
			return err
		}
		// Count actual bytes too: source files can grow after their metadata is read.
		written, err := io.Copy(entryWriter, io.LimitReader(contextReader{ctx, file}, remaining+1))
		totalBytes += written
		if err != nil {
			return err
		}
		if totalBytes > limits.sourceBytes {
			return fmt.Errorf("%w: source size", errArchiveLimit)
		}
		return file.Close()
	})
	closeErr := zipWriter.Close() // Includes the final entry and central directory.
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return ctx.Err()
}
