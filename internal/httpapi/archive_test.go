package httpapi

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

type failingArchiveWriter struct{ err error }

func (w failingArchiveWriter) Write([]byte) (int, error) { return 0, w.err }

func TestArchiveLimitsAndErrors(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "file.txt"), bytes.Repeat([]byte("a"), 4096), 0644); err != nil {
		t.Fatal(err)
	}
	directory, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer directory.Close()
	limits := archiveLimits{files: 1, sourceBytes: 4096, compressedBytes: 512}
	var output bytes.Buffer
	if err := buildAssetArchive(context.Background(), directory, &output, limits); err != nil {
		t.Fatal(err)
	}
	// A 4 KiB source fits a 512-byte archive cap because compressed bytes,
	// including ZIP headers and the central directory, are counted separately.
	archive, err := zip.NewReader(bytes.NewReader(output.Bytes()), int64(output.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if len(archive.File) != 1 {
		t.Fatalf("entries=%d", len(archive.File))
	}
	file, err := archive.File[0].Open()
	if err != nil {
		t.Fatal(err)
	}
	content, err := io.ReadAll(file)
	file.Close()
	if err != nil || len(content) != 4096 {
		t.Fatalf("content=%d error=%v", len(content), err)
	}
	for _, limited := range []archiveLimits{{files: 0, sourceBytes: 4096, compressedBytes: 512}, {files: 1, sourceBytes: 4095, compressedBytes: 512}, {files: 1, sourceBytes: 4096, compressedBytes: 10}} {
		if err := buildAssetArchive(context.Background(), directory, io.Discard, limited); !errors.Is(err, errArchiveLimit) {
			t.Fatalf("limits=%+v error=%v", limited, err)
		}
	}
	storageErr := errors.New("disk full")
	if err := buildAssetArchive(context.Background(), directory, failingArchiveWriter{storageErr}, limits); !errors.Is(err, storageErr) {
		t.Fatalf("write error=%v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := buildAssetArchive(ctx, directory, io.Discard, limits); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation error=%v", err)
	}
}
