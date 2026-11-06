package scanner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Item struct {
	ID           string    `json:"id"`
	ParentID     string    `json:"parentId,omitempty"`
	Type         string    `json:"type"`
	Title        string    `json:"title"`
	OriginalName string    `json:"originalName"`
	RelativePath string    `json:"relativePath"`
	SortKey      string    `json:"sortKey"`
	Position     int       `json:"position"`
	Depth        int       `json:"depth"`
	SizeBytes    int64     `json:"sizeBytes,omitempty"`
	ModifiedAt   time.Time `json:"modifiedAt,omitempty"`
	MimeType     string    `json:"mimeType,omitempty"`
	Extension    string    `json:"extension,omitempty"`
	MediaKind    string    `json:"mediaKind,omitempty"`
	SubtitleFor  string    `json:"subtitleFor,omitempty"`
	LessonID     string    `json:"lessonId,omitempty"`
	Available    bool      `json:"available"`
}

type Result struct {
	Items   []Item
	Ignored []string
}
type candidate struct {
	path, rel, name string
	isDir           bool
	info            os.FileInfo
}

var ignoredNames = map[string]bool{".DS_Store": true, "Thumbs.db": true, "desktop.ini": true, ".git": true, ".svn": true, "@eaDir": true}
var tempSuffixes = []string{".part", ".partial", ".tmp", ".crdownload", ".!qb"}

func isIgnoredName(name string) bool {
	return ignoredNames[name] || strings.HasPrefix(name, "._") // macOS AppleDouble metadata
}

var subtitleExt = map[string]bool{".srt": true, ".vtt": true, ".ass": true, ".ssa": true, ".sub": true, ".idx": true, ".sup": true}

func Scan(root string) (Result, error) {
	return ScanWithProgress(root, nil)
}

// ScanWithProgress emits provisional batches while walking, then canonical
// batches after section inference, subtitle association, and ordering finish.
// Callers can expose provisional items immediately and update them in place
// when canonical records arrive.
func ScanWithProgress(root string, onBatch func([]Item, bool) error) (Result, error) {
	return ScanWithOptions(context.Background(), root, Options{}, onBatch)
}

func ScanWithOptions(ctx context.Context, root string, options Options, onBatch func([]Item, bool) error) (Result, error) {
	started := time.Now()
	progress := Progress{Phase: "enumerating"}
	report := func() {
		progress.ElapsedMS = time.Since(started).Milliseconds()
		if options.OnProgress != nil {
			options.OnProgress(progress)
		}
	}
	report()
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return Result{}, fmt.Errorf("resolve root: %w", err)
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return Result{}, err
	}
	st, err := os.Stat(root)
	if err != nil || !st.IsDir() {
		return Result{}, fmt.Errorf("content root is unavailable or not a directory")
	}
	var files []candidate
	var dirs []candidate
	var ignored []string
	var pending []Item
	var provisionalItems []Item
	lastFlush := time.Now()
	seenProvisionalFileIDs := make(map[string]bool)
	courseByRel := make(map[string]string)
	flush := func() error {
		if onBatch == nil || len(pending) == 0 {
			return nil
		}
		batch := pending
		pending = nil
		provisionalItems = append(provisionalItems, batch...)
		start := time.Now()
		err := onBatch(batch, false)
		progress.PersistenceMS += time.Since(start).Milliseconds()
		report()
		return err
	}
	err = walkMetadata(ctx, root, options, &progress, report, func(path string, entry os.DirEntry, walkErr error) error {
		if path == root {
			return walkErr
		}
		if walkErr != nil {
			// macOS creates AppleDouble sidecar files (._*) on some volumes. Shared
			// mounts can deny even lstat on these metadata files, before WalkDir
			// gives us an entry to filter. Ignore only those known metadata names;
			// errors for course content must still fail the scan.
			if isIgnoredName(filepath.Base(path)) {
				if rel, relErr := filepath.Rel(root, path); relErr == nil {
					ignored = append(ignored, filepath.ToSlash(rel))
				}
				return nil
			}
			return walkErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			ignored = append(ignored, filepath.ToSlash(rel))
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		name := entry.Name()
		if isIgnoredName(name) {
			ignored = append(ignored, filepath.ToSlash(rel))
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		lower := strings.ToLower(name)
		for _, suffix := range tempSuffixes {
			if strings.HasSuffix(lower, suffix) {
				ignored = append(ignored, filepath.ToSlash(rel))
				if entry.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		c := candidate{path: path, rel: filepath.ToSlash(rel), name: name, isDir: entry.IsDir(), info: info}
		if c.isDir {
			dirs = append(dirs, c)
			if onBatch == nil {
				return nil
			}
			parentRel := filepath.ToSlash(filepath.Dir(filepath.FromSlash(c.rel)))
			isCourse := parentRel == "."
			kind := "asset_directory"
			parentID := ""
			if isCourse {
				kind = "course"
				courseByRel[c.rel] = c.rel
			} else if course := nearestCourse(c.rel, courseByRel); course != "" {
				parentID = stableID("directory", parentRel)
				if parentRel == course {
					parentID = stableID("course", course)
				}
			}
			item := makeItem(c.rel, c.name, kind, parentID, c.info, "")
			if !isCourse && parentID != "" {
				item.ID = stableID("directory", c.rel)
			}
			if isCourse || parentID != "" {
				pending = append(pending, item)
			}
		} else {
			files = append(files, c)
			if onBatch == nil {
				return nil
			}
			if course := nearestCourse(c.rel, courseByRel); course != "" {
				parentRel := filepath.ToSlash(filepath.Dir(filepath.FromSlash(c.rel)))
				parentID := stableID("directory", parentRel)
				if parentRel == course {
					parentID = stableID("course", course)
				}
				ext := strings.ToLower(filepath.Ext(c.name))
				kind := mediaKind(c.name)
				typ := "asset"
				if kind != "" {
					typ = "lesson"
				} else if subtitleExt[ext] {
					typ = "subtitle"
				}
				item := makeItem(c.rel, c.name, typ, parentID, c.info, c.path)
				if seenProvisionalFileIDs[item.ID] {
					item.ID = stableID("file", c.rel)
				}
				seenProvisionalFileIDs[item.ID] = true
				item.MediaKind = kind
				pending = append(pending, item)
			}
		}
		if len(pending) >= 256 || len(pending) > 0 && time.Since(lastFlush) >= time.Second {
			if err := flush(); err != nil {
				return err
			}
			lastFlush = time.Now()
		}
		return nil
	})
	if err != nil {
		if flushErr := flush(); flushErr != nil {
			return Result{Items: provisionalItems, Ignored: ignored}, fmt.Errorf("walk content root: %w (persist discovered entries: %v)", err, flushErr)
		}
		return Result{Items: provisionalItems, Ignored: ignored}, fmt.Errorf("walk content root: %w", err)
	}
	if err := flush(); err != nil {
		return Result{}, fmt.Errorf("emit provisional scan batch: %w", err)
	}
	progress.Phase = "canonicalizing"
	report()
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	// Establish course roots: direct child directories of configured root.
	idByRel := map[string]string{}
	for _, d := range dirs {
		if filepath.ToSlash(filepath.Dir(filepath.FromSlash(d.rel))) == "." {
			idByRel[d.rel] = stableID("course", d.rel)
			courseByRel[d.rel] = idByRel[d.rel]
		}
	}
	// Cache whether each directory has descendant media; drives recursive section inference.
	videoUnder := map[string]bool{}
	for _, f := range files {
		if mediaKind(f.name) != "" {
			dir := filepath.ToSlash(filepath.Dir(filepath.FromSlash(f.rel)))
			for dir != "." {
				videoUnder[dir] = true
				dir = filepath.ToSlash(filepath.Dir(filepath.FromSlash(dir)))
			}
		}
	}
	// Directories under each course with video descendants become sections. Others are asset directories.
	for _, d := range dirs {
		if _, ok := idByRel[d.rel]; ok {
			continue
		}
		course := nearestCourse(d.rel, courseByRel)
		if course == "" {
			continue
		}
		idByRel[d.rel] = stableID("directory", d.rel)
	}
	items := make([]Item, 0, len(files)+len(dirs))
	for _, d := range dirs {
		course := d.rel
		if _, isCourse := courseByRel[d.rel]; !isCourse {
			course = nearestCourse(d.rel, courseByRel)
		}
		if course == "" {
			continue
		}
		typ := "asset_directory"
		if d.rel == course {
			typ = "course"
		} else if videoUnder[d.rel] {
			typ = "section"
		}
		parentRel := filepath.ToSlash(filepath.Dir(filepath.FromSlash(d.rel)))
		parentID := idByRel[parentRel]
		item := makeItem(d.rel, d.name, typ, parentID, d.info, "")
		if typ != "course" {
			item.ID = stableID("directory", d.rel)
		}
		items = append(items, item)
	}
	seenFileIDs := map[string]bool{}
	for _, f := range files {
		course := nearestCourse(f.rel, courseByRel)
		if course == "" {
			continue
		}
		ext := strings.ToLower(filepath.Ext(f.name))
		kind := mediaKind(f.name)
		typ := "asset"
		if kind != "" {
			typ = "lesson"
		} else if subtitleExt[ext] {
			typ = "subtitle"
		}
		parentRel := filepath.ToSlash(filepath.Dir(filepath.FromSlash(f.rel)))
		parentID := idByRel[parentRel]
		item := makeItem(f.rel, f.name, typ, parentID, f.info, f.path)
		if seenFileIDs[item.ID] {
			item.ID = stableID("file", f.rel)
		}
		seenFileIDs[item.ID] = true
		item.MediaKind = kind
		items = append(items, item)
	}
	// Associate sidecars only with lessons in the same physical directory; require an exact, unambiguous basename match.
	lessons := map[string][]Item{}
	for _, it := range items {
		if it.Type == "lesson" {
			lessons[normalizeBase(it.RelativePath)] = append(lessons[normalizeBase(it.RelativePath)], it)
		}
	}
	for i := range items {
		it := &items[i]
		if it.Type != "subtitle" && it.Type != "asset" {
			continue
		}
		stem := normalizeBase(it.RelativePath)
		candidates := lessons[stem]
		if it.Type == "subtitle" && len(candidates) != 1 {
			candidates = lessons[subtitleBase(it.RelativePath)]
		}
		if len(candidates) != 1 {
			continue
		}
		lesson := candidates[0]
		if filepath.ToSlash(filepath.Dir(filepath.FromSlash(lesson.RelativePath))) != filepath.ToSlash(filepath.Dir(filepath.FromSlash(it.RelativePath))) {
			continue
		}
		it.LessonID = lesson.ID
		it.ParentID = lesson.ID
		if it.Type == "subtitle" {
			it.SubtitleFor = lesson.ID
		}
	}
	// Ordering is natural within each parent; course/section/asset structure is preserved.
	byParent := map[string][]int{}
	for i := range items {
		byParent[items[i].ParentID] = append(byParent[items[i].ParentID], i)
	}
	for _, indices := range byParent {
		sort.Slice(indices, func(i, j int) bool {
			a, b := items[indices[i]], items[indices[j]]
			if naturalLess(a.OriginalName, b.OriginalName) {
				return true
			}
			if naturalLess(b.OriginalName, a.OriginalName) {
				return false
			}
			return a.ID < b.ID
		})
		for position, idx := range indices {
			items[idx].Position = position
		}
	}
	sort.Slice(items, func(i, j int) bool {
		a, b := items[i], items[j]
		aDepth, bDepth := a.Depth, b.Depth
		if a.LessonID != "" {
			aDepth++ // sidecars/assets link under the lesson and must be inserted after it
		}
		if b.LessonID != "" {
			bDepth++
		}
		if aDepth != bDepth {
			return aDepth < bDepth
		}
		aDirectory := a.Type == "course" || a.Type == "section" || a.Type == "asset_directory"
		bDirectory := b.Type == "course" || b.Type == "section" || b.Type == "asset_directory"
		if aDirectory != bDirectory {
			return aDirectory
		}
		if a.RelativePath == b.RelativePath {
			return a.ID < b.ID
		}
		return a.RelativePath < b.RelativePath
	})
	sort.Strings(ignored)
	if onBatch != nil {
		// Canonicalization can change parent links (sidecar → lesson) and entry
		// types (directory → section). Re-emit bounded batches to correct the
		// provisional records without holding a library-wide write transaction.
		progress.Phase = "persisting"
		report()
		for start := 0; start < len(items); start += 256 {
			if err := ctx.Err(); err != nil {
				return Result{}, err
			}
			end := start + 256
			if end > len(items) {
				end = len(items)
			}
			batchStarted := time.Now()
			if err := onBatch(items[start:end], true); err != nil {
				return Result{}, fmt.Errorf("emit canonical scan batch: %w", err)
			}
			progress.PersistenceMS += time.Since(batchStarted).Milliseconds()
			report()
		}
	}
	return Result{Items: items, Ignored: ignored}, nil
}

func makeItem(rel, name, typ, parent string, info os.FileInfo, path string) Item {
	idKind := typ
	if typ == "section" || typ == "asset_directory" {
		idKind = "directory"
	}
	id := stableID(idKind, rel)
	ext := strings.ToLower(filepath.Ext(name))
	titleName := name
	if info == nil || !info.IsDir() {
		titleName = strings.TrimSuffix(name, filepath.Ext(name))
	}
	title := cleanTitle(titleName)
	mt := mime.TypeByExtension(ext)
	if mt == "" {
		mt = "application/octet-stream"
	}
	it := Item{ID: id, ParentID: parent, Type: typ, Title: title, OriginalName: name, RelativePath: rel, SortKey: strings.ToLower(name), Depth: strings.Count(rel, "/"), Available: true, MimeType: mt, Extension: strings.TrimPrefix(ext, ".")}
	if info != nil {
		it.ModifiedAt = info.ModTime()
		if !info.IsDir() {
			it.SizeBytes = info.Size()
		}
	}
	if path != "" && info != nil && !info.IsDir() {
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			sum := sha256.Sum256([]byte(fmt.Sprintf("%x:%x", uint64(stat.Dev), uint64(stat.Ino))))
			it.ID = "item_" + hex.EncodeToString(sum[:16])
		}
	}
	return it
}
func stableID(kind, rel string) string {
	sum := sha256.Sum256([]byte(kind + "\x00" + filepath.ToSlash(rel)))
	return kind + "_" + hex.EncodeToString(sum[:16])
}
func publicItemID(internal string) string {
	if strings.HasPrefix(internal, "item_") {
		return "item_" + strings.TrimPrefix(internal, "item_")
	}
	return internal
}
func mediaKind(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".m4v", ".mkv", ".mov", ".avi", ".webm", ".mpeg", ".mpg", ".mts", ".m2ts", ".wmv", ".flv":
		return "video"
	case ".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".flac", ".wma":
		return "audio"
	}
	return ""
}
func nearestCourse(rel string, courses map[string]string) string {
	dir := filepath.ToSlash(filepath.Dir(filepath.FromSlash(rel)))
	for {
		if _, ok := courses[dir]; ok {
			return dir
		}
		if dir == "." || dir == "/" {
			break
		}
		next := filepath.ToSlash(filepath.Dir(filepath.FromSlash(dir)))
		if next == dir {
			break
		}
		dir = next
	}
	return ""
}
func cleanTitle(stem string) string {
	fields := strings.Fields(stem)
	if len(fields) == 0 {
		return stem
	}
	prefix := strings.Trim(fields[0], "._- ")
	if _, err := strconv.Atoi(prefix); err == nil {
		if trimmed := strings.TrimLeft(strings.TrimPrefix(stem, fields[0]), " ._-\t"); trimmed != "" {
			stem = trimmed
		}
	} else {
		trimmed := strings.TrimLeft(stem, " \t")
		digits := 0
		for digits < len(trimmed) && trimmed[digits] >= '0' && trimmed[digits] <= '9' {
			digits++
		}
		if digits > 0 && digits < len(trimmed) && (trimmed[digits] == '-' || trimmed[digits] == '_') {
			if rest := strings.TrimLeft(trimmed[digits:], " ._-\t"); rest != "" {
				stem = rest
			}
		}
	}
	return strings.Join(strings.Fields(stem), " ")
}
func naturalLess(a, b string) bool {
	aa, bb := strings.ToLower(a), strings.ToLower(b)
	i, j := 0, 0
	for i < len(aa) && j < len(bb) {
		if aa[i] >= '0' && aa[i] <= '9' && bb[j] >= '0' && bb[j] <= '9' {
			x, y := i, j
			for x < len(aa) && aa[x] >= '0' && aa[x] <= '9' {
				x++
			}
			for y < len(bb) && bb[y] >= '0' && bb[y] <= '9' {
				y++
			}
			an, _ := strconv.ParseUint(aa[i:x], 10, 64)
			bn, _ := strconv.ParseUint(bb[j:y], 10, 64)
			if an != bn {
				return an < bn
			}
			if x-i != y-j {
				return x-i < y-j
			}
			i, j = x, y
			continue
		}
		if aa[i] != bb[j] {
			return aa[i] < bb[j]
		}
		i++
		j++
	}
	return len(aa) < len(bb)
}
func normalizeBase(rel string) string {
	return strings.TrimSuffix(filepath.ToSlash(rel), filepath.Ext(rel))
}
func subtitleBase(rel string) string {
	stem := normalizeBase(rel)
	for {
		if next, ok := trimSubtitleSuffix(stem, "."); ok {
			stem = next
			continue
		}
		if next, ok := trimSubtitleSuffix(stem, "_"); ok {
			stem = next
			continue
		}
		break
	}
	return stem
}

func isSubtitleTag(tag string) bool {
	tag = strings.ToLower(tag)
	if tag == "forced" || tag == "sdh" || tag == "cc" || tag == "hi" || len(tag) == 2 {
		return true
	}
	return len(tag) == 5 && (tag[2] == '-' || tag[2] == '_')
}

func trimSubtitleSuffix(stem, sep string) (string, bool) {
	idx := strings.LastIndex(stem, sep)
	if idx <= 0 || strings.Contains(stem[idx+len(sep):], "/") {
		return stem, false
	}
	if isSubtitleTag(stem[idx+len(sep):]) {
		return stem[:idx], true
	}
	return stem, false
}
