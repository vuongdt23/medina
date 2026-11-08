package sqlite

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"sort"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"medina/internal/scanner"
)

//go:embed migrations/*.sql
var migrations embed.FS

type Store struct {
	DB         *sql.DB
	scanMu     sync.Mutex
	progressMu sync.RWMutex
	progress   map[string]scanner.Progress
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	for _, q := range []string{"PRAGMA foreign_keys=ON", "PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000"} {
		if _, err = db.Exec(q); err != nil {
			db.Close()
			return nil, err
		}
	}
	s := &Store{DB: db}
	if err = s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.DB.ExecContext(ctx, "CREATE TABLE IF NOT EXISTS schema_migrations(version TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"); err != nil {
		return err
	}
	files, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name() < files[j].Name() })
	for _, f := range files {
		version := f.Name()
		var exists int
		if err = s.DB.QueryRowContext(ctx, "SELECT count(*) FROM schema_migrations WHERE version=?", version).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			continue
		}
		content, err := migrations.ReadFile("migrations/" + version)
		if err != nil {
			return err
		}
		tx, err := s.DB.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, string(content)); err == nil {
			_, err = tx.ExecContext(ctx, "INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)", version, time.Now().UTC().Format(time.RFC3339Nano))
		}
		if err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", version, err)
		}
		if err = tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
func (s *Store) Close() error { return s.DB.Close() }
func (s *Store) EnsureLibrary(ctx context.Context, id, name, path string) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO library_roots(id,name,canonical_path,scan_state) VALUES(?,?,?,'idle') ON CONFLICT(id) DO UPDATE SET name=excluded.name,canonical_path=excluded.canonical_path`, id, name, path)
	return err
}
func (s *Store) Status(ctx context.Context, id string) (map[string]any, error) {
	var state string
	var started, completed, errText, gen sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT scan_state,last_scan_started_at,last_scan_completed_at,last_scan_error,active_generation_id FROM library_roots WHERE id=?`, id).Scan(&state, &started, &completed, &errText, &gen)
	if err != nil {
		return nil, err
	}
	var itemCount int
	if gen.Valid {
		if err := s.DB.QueryRowContext(ctx, "SELECT count(*) FROM entry_snapshots WHERE generation_id=?", gen.String).Scan(&itemCount); err != nil {
			return nil, err
		}
	}
	s.progressMu.RLock()
	progress, hasProgress := s.progress[id]
	s.progressMu.RUnlock()
	status := map[string]any{"libraryId": id, "state": state, "lastScanStartedAt": nullable(started), "lastScanCompletedAt": nullable(completed), "lastScanError": nullable(errText), "activeGenerationId": nullable(gen), "itemCount": itemCount}
	if hasProgress {
		if state == "scanning" && started.Valid {
			if start, err := time.Parse(time.RFC3339Nano, started.String); err == nil {
				progress.ElapsedMS = time.Since(start).Milliseconds()
			}
		}
		status["progress"] = progress
	}
	return status, nil
}
func nullable(n sql.NullString) any {
	if !n.Valid {
		return nil
	}
	return n.String
}
func (s *Store) Scan(ctx context.Context, libraryID, root string) (string, error) {
	return s.ScanWithProgress(ctx, libraryID, root, nil)
}

// ScanWithProgress reconciles the library incrementally and reports the number
// of staged snapshot records written so far after each persisted batch.
func (s *Store) ScanWithProgress(ctx context.Context, libraryID, root string, progress func(int) error) (string, error) {
	return s.ScanWithOptions(ctx, libraryID, root, scanner.Options{}, progress)
}

func (s *Store) setProgress(id string, progress scanner.Progress) {
	s.progressMu.Lock()
	defer s.progressMu.Unlock()
	if s.progress == nil {
		s.progress = make(map[string]scanner.Progress)
	}
	s.progress[id] = progress
}

func sameItem(a, b scanner.Item) bool {
	if !a.ModifiedAt.Equal(b.ModifiedAt) {
		return false
	}
	a.ModifiedAt, b.ModifiedAt = time.Time{}, time.Time{}
	return a == b
}

func (s *Store) ScanWithOptions(ctx context.Context, libraryID, root string, options scanner.Options, progress func(int) error) (generation string, retErr error) {
	s.scanMu.Lock()
	defer s.scanMu.Unlock()
	scanStarted := time.Now()
	currentProgress := scanner.Progress{Phase: "preparing"}
	s.setProgress(libraryID, currentProgress)
	defer func() {
		currentProgress.ElapsedMS = time.Since(scanStarted).Milliseconds()
		currentProgress.Phase = "complete"
		if retErr != nil {
			currentProgress.Phase = "failed"
		}
		s.setProgress(libraryID, currentProgress)
	}()
	baseline, err := s.Items(ctx, libraryID)
	if err != nil {
		return "", err
	}
	baselineItems := make(map[string]scanner.Item, len(baseline))
	known := make(map[string]scanner.Item, len(baseline))
	knownPaths := make(map[string]bool, len(baseline))
	for _, item := range baseline {
		baselineItems[item.ID] = item
		known[item.ID] = item
		knownPaths[item.RelativePath] = true
	}
	started := scanStarted.UTC().Format(time.RFC3339Nano)
	generation = fmt.Sprintf("gen_%d", time.Now().UnixNano())
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	var previous sql.NullString
	if err := tx.QueryRowContext(ctx, "SELECT active_generation_id FROM library_roots WHERE id=?", libraryID).Scan(&previous); err != nil {
		tx.Rollback()
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO scan_generations(id,library_id,status,started_at) VALUES(?,?,'staging',?)`, generation, libraryID, started); err != nil {
		tx.Rollback()
		return "", err
	}
	if previous.Valid {
		if _, err := tx.ExecContext(ctx, `INSERT INTO entry_snapshots(generation_id,item_id,parent_item_id,entry_type,original_name,title,relative_path,sort_key,position,depth,size_bytes,modified_at,mime_type,extension,media_kind,lesson_id,subtitle_for,available,duration_seconds)
			SELECT ?,item_id,parent_item_id,entry_type,original_name,title,relative_path,sort_key,position,depth,size_bytes,modified_at,mime_type,extension,media_kind,lesson_id,subtitle_for,available,duration_seconds FROM entry_snapshots WHERE generation_id=?`, generation, previous.String); err != nil {
			tx.Rollback()
			return "", err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO entry_search(item_id,generation_id,entry_type,title,original_name) SELECT item_id,generation_id,entry_type,title,original_name FROM entry_snapshots WHERE generation_id=?`, generation); err != nil {
			tx.Rollback()
			return "", err
		}
	}
	// Publish the in-progress generation immediately. Scanner batches are
	// committed as they are discovered, so readers can query partial scan state.
	if _, err := tx.ExecContext(ctx, "UPDATE library_roots SET active_generation_id=?,scan_state='scanning',last_scan_started_at=?,last_scan_error=NULL WHERE id=?", generation, started, libraryID); err != nil {
		tx.Rollback()
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	defer func() {
		if retErr != nil {
			// If there is a previous successful snapshot, keep it active after a
			// failed reconciliation. First scans retain their discovered partial
			// entries, matching Jellyfin's incremental behavior.
			if previous.Valid {
				_, _ = s.DB.ExecContext(context.Background(), "UPDATE library_roots SET active_generation_id=?,scan_state='failed',last_scan_error=? WHERE id=?", previous.String, retErr.Error(), libraryID)
				_, _ = s.DB.ExecContext(context.Background(), "DELETE FROM entry_search WHERE generation_id=?", generation)
			} else {
				_, _ = s.DB.ExecContext(context.Background(), "UPDATE library_roots SET scan_state='failed',last_scan_error=? WHERE id=?", retErr.Error(), libraryID)
			}
			_, _ = s.DB.ExecContext(context.Background(), "UPDATE scan_generations SET status='failed' WHERE id=? AND status='staging'", generation)
		}
	}()
	var written int
	observer := options.OnProgress
	options.OnProgress = func(p scanner.Progress) {
		currentProgress = p
		currentProgress.ElapsedMS = time.Since(scanStarted).Milliseconds()
		s.setProgress(libraryID, currentProgress)
		if observer != nil {
			observer(currentProgress)
		}
	}
	result, err := scanner.ScanWithOptions(ctx, root, options, func(batch []scanner.Item, canonical bool) error {
		for i := range batch {
			reuseLessonDuration(&batch[i], baselineItems)
		}
		changed := make([]scanner.Item, 0, len(batch))
		for _, item := range batch {
			// Keep published parent links and types during enumeration. Only
			// canonical records may replace existing paths or identities.
			if !canonical && knownPaths[item.RelativePath] {
				continue
			}
			if old, ok := known[item.ID]; canonical && ok && sameItem(old, item) {
				continue
			}
			changed = append(changed, item)
		}
		if err := s.writeScanBatch(ctx, libraryID, generation, changed, canonical); err != nil {
			return err
		}
		for _, item := range changed {
			known[item.ID] = item
			knownPaths[item.RelativePath] = true
		}
		written += len(changed)
		if progress != nil {
			return progress(written)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	probeMissingLessonDurations(ctx, root, result.Items, baselineItems)
	if options.GenerateThumbnails {
		GenerateThumbnails(ctx, root, options.ThumbnailCacheDir, options.ThumbnailMaxDim, result.Items)
	}
	var durationUpdates []scanner.Item
	for _, item := range result.Items {
		if item.Type == "lesson" && item.DurationSeconds > 0 {
			prior, ok := baselineItems[item.ID]
			if !ok || prior.SizeBytes != item.SizeBytes || !prior.ModifiedAt.Equal(item.ModifiedAt) || prior.DurationSeconds != item.DurationSeconds {
				durationUpdates = append(durationUpdates, item)
			}
		}
	}
	for start := 0; start < len(durationUpdates); start += 256 {
		end := min(start+256, len(durationUpdates))
		if err := s.writeScanBatch(ctx, libraryID, generation, durationUpdates[start:end], true); err != nil {
			return "", err
		}
	}
	currentProgress.Phase = "publishing"
	s.setProgress(libraryID, currentProgress)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	tx, err = s.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	// Reconcile stale entries only after enumeration completes successfully.
	// On errors, already discovered changes remain visible, like Jellyfin's
	// incremental scan, while entries not yet visited are preserved.
	seen := make(map[string]struct{}, len(result.Items))
	for _, item := range result.Items {
		seen[item.RelativePath] = struct{}{}
	}
	rows, err := tx.QueryContext(ctx, "SELECT relative_path FROM entry_snapshots WHERE generation_id=?", generation)
	if err != nil {
		return "", err
	}
	var stale []string
	for rows.Next() {
		var path string
		if err := rows.Scan(&path); err != nil {
			rows.Close()
			return "", err
		}
		if _, exists := seen[path]; !exists {
			stale = append(stale, path)
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return "", err
	}
	rows.Close()
	for _, path := range stale {
		if _, err := tx.ExecContext(ctx, "DELETE FROM entry_search WHERE item_id=(SELECT item_id FROM entry_snapshots WHERE generation_id=? AND relative_path=?) AND generation_id=?", generation, path, generation); err != nil {
			return "", err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM entry_snapshots WHERE generation_id=? AND relative_path=?", generation, path); err != nil {
			return "", err
		}
	}
	if _, err = tx.ExecContext(ctx, "UPDATE scan_generations SET status='complete',completed_at=? WHERE id=?", now, generation); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE library_roots SET scan_state='idle',last_scan_completed_at=?,last_scan_error=NULL WHERE id=?", now, libraryID); err != nil {
		return "", err
	}
	// Retain only the current completed generation after publication; otherwise
	// each periodic reconciliation would duplicate the whole snapshot forever.
	if _, err = tx.ExecContext(ctx, "DELETE FROM entry_search WHERE generation_id IN (SELECT id FROM scan_generations WHERE library_id=? AND id<>?)", libraryID, generation); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM scan_generations WHERE library_id=? AND id<>?", libraryID, generation); err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return generation, nil
}
func (s *Store) writeScanBatch(ctx context.Context, libraryID, generation string, items []scanner.Item, canonical bool) error {
	if len(items) == 0 {
		return nil
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	statements := make(map[string]*sql.Stmt)
	defer func() {
		for _, statement := range statements {
			statement.Close()
		}
	}()
	exec := func(query string, args ...any) (sql.Result, error) {
		statement := statements[query]
		if statement == nil {
			var err error
			statement, err = tx.PrepareContext(ctx, query)
			if err != nil {
				return nil, err
			}
			statements[query] = statement
		}
		return statement.ExecContext(ctx, args...)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, it := range items {
		if _, err := exec(`INSERT INTO items(id,library_id,created_at) VALUES(?,?,?) ON CONFLICT(id) DO NOTHING`, it.ID, libraryID, now); err != nil {
			return err
		}
		// A rename can preserve file identity while changing relative_path. Remove
		// only the old path for that ID; updating an unchanged row in place avoids
		// temporarily breaking children that reference this item as their parent.
		if _, err := exec("DELETE FROM entry_snapshots WHERE generation_id=? AND item_id=? AND relative_path<>?", generation, it.ID, it.RelativePath); err != nil {
			return err
		}
		if canonical {
			rows, err := tx.QueryContext(ctx, "SELECT item_id FROM entry_snapshots WHERE generation_id=? AND relative_path=? AND item_id<>?", generation, it.RelativePath, it.ID)
			if err != nil {
				return err
			}
			var replacedIDs []string
			for rows.Next() {
				var replacedID string
				if err := rows.Scan(&replacedID); err != nil {
					rows.Close()
					return err
				}
				replacedIDs = append(replacedIDs, replacedID)
			}
			if err := rows.Err(); err != nil {
				rows.Close()
				return err
			}
			rows.Close()
			for _, replacedID := range replacedIDs {
				// Repair foreign-key references when an older index used a
				// type-derived directory ID and this scan canonicalizes it.
				if _, err := tx.ExecContext(ctx, "UPDATE entry_snapshots SET parent_item_id=? WHERE generation_id=? AND parent_item_id=?", it.ID, generation, replacedID); err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, "UPDATE entry_snapshots SET lesson_id=? WHERE generation_id=? AND lesson_id=?", it.ID, generation, replacedID); err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, "UPDATE entry_snapshots SET subtitle_for=? WHERE generation_id=? AND subtitle_for=?", it.ID, generation, replacedID); err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, "DELETE FROM entry_search WHERE generation_id=? AND item_id=?", generation, replacedID); err != nil {
					return err
				}
				if _, err := tx.ExecContext(ctx, "DELETE FROM entry_snapshots WHERE generation_id=? AND item_id=?", generation, replacedID); err != nil {
					return err
				}
			}
		}
		if _, err := exec("DELETE FROM entry_search WHERE item_id=? AND generation_id=?", it.ID, generation); err != nil {
			return err
		}
		_, err = exec(`INSERT INTO entry_snapshots(generation_id,item_id,parent_item_id,entry_type,original_name,title,relative_path,sort_key,position,depth,size_bytes,modified_at,mime_type,extension,media_kind,lesson_id,subtitle_for,available,duration_seconds)
			VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
			ON CONFLICT(generation_id,item_id) DO UPDATE SET
				parent_item_id=excluded.parent_item_id,entry_type=excluded.entry_type,
				original_name=excluded.original_name,title=excluded.title,sort_key=excluded.sort_key,
				position=excluded.position,depth=excluded.depth,size_bytes=excluded.size_bytes,
				modified_at=excluded.modified_at,mime_type=excluded.mime_type,extension=excluded.extension,
				media_kind=excluded.media_kind,lesson_id=excluded.lesson_id,subtitle_for=excluded.subtitle_for,
				available=excluded.available,duration_seconds=excluded.duration_seconds`,
			generation, it.ID, nullIfEmpty(it.ParentID), it.Type, it.OriginalName, it.Title, it.RelativePath,
			it.SortKey, it.Position, it.Depth, it.SizeBytes, it.ModifiedAt.UTC().Format(time.RFC3339Nano),
			it.MimeType, it.Extension, it.MediaKind, nullIfEmpty(it.LessonID), nullIfEmpty(it.SubtitleFor), it.Available, it.DurationSeconds)
		if err != nil {
			return err
		}
		if _, err := exec(`INSERT INTO entry_search(item_id,generation_id,entry_type,title,original_name) VALUES(?,?,?,?,?)`, it.ID, generation, it.Type, it.Title, it.OriginalName); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
func (s *Store) Items(ctx context.Context, libraryID string) ([]scanner.Item, error) {
	return s.itemsWhere(ctx, libraryID, "", nil)
}

// CourseItems returns only the indexed course and its descendants using the
// snapshot's parent index, avoiding a whole-library read for a course view.
const courseItemsQuery = `WITH RECURSIVE course_items(item_id) AS (
	SELECT item_id FROM entry_snapshots WHERE generation_id=? AND item_id=? AND entry_type='course'
	UNION
	-- CROSS JOIN preserves the parent-first loop order. Without it, SQLite may
	-- scan every snapshot row for each parent rather than using entry_parent_idx.
	SELECT child.item_id FROM course_items parent CROSS JOIN entry_snapshots child INDEXED BY entry_parent_idx
	WHERE child.generation_id=? AND child.parent_item_id=parent.item_id
)
SELECT e.item_id,e.parent_item_id,e.entry_type,e.original_name,e.title,e.relative_path,e.sort_key,e.position,e.depth,e.size_bytes,e.modified_at,e.mime_type,e.extension,e.media_kind,e.lesson_id,e.subtitle_for,e.available,e.duration_seconds
FROM entry_snapshots e JOIN course_items c ON c.item_id=e.item_id WHERE e.generation_id=?`

func (s *Store) CourseItems(ctx context.Context, libraryID, courseID string) ([]scanner.Item, error) {
	var gen sql.NullString
	if err := s.DB.QueryRowContext(ctx, "SELECT active_generation_id FROM library_roots WHERE id=?", libraryID).Scan(&gen); err != nil {
		return nil, err
	}
	if !gen.Valid {
		return []scanner.Item{}, nil
	}
	rows, err := s.DB.QueryContext(ctx, courseItemsQuery, gen.String, courseID, gen.String, gen.String)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanItems(rows)
}

// Courses avoids loading the entire library for the frequently polled sidebar.
func (s *Store) Courses(ctx context.Context, libraryID string) ([]scanner.Item, error) {
	return s.itemsWhere(ctx, libraryID, " AND entry_type=? ORDER BY position,item_id", []any{"course"})
}

func (s *Store) itemsWhere(ctx context.Context, libraryID, filter string, args []any) ([]scanner.Item, error) {
	var gen sql.NullString
	if err := s.DB.QueryRowContext(ctx, "SELECT active_generation_id FROM library_roots WHERE id=?", libraryID).Scan(&gen); err != nil {
		return nil, err
	}
	if !gen.Valid {
		return []scanner.Item{}, nil
	}
	args = append([]any{gen.String}, args...)
	rows, err := s.DB.QueryContext(ctx, `SELECT item_id,parent_item_id,entry_type,original_name,title,relative_path,sort_key,position,depth,size_bytes,modified_at,mime_type,extension,media_kind,lesson_id,subtitle_for,available,duration_seconds FROM entry_snapshots WHERE generation_id=?`+filter, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanItems(rows)
}

func scanItems(rows *sql.Rows) ([]scanner.Item, error) {
	var out []scanner.Item
	for rows.Next() {
		var it scanner.Item
		var parent, modified, mimeType, ext, kind, lesson, subtitle sql.NullString
		var size int64
		var duration float64
		var available int
		err := rows.Scan(&it.ID, &parent, &it.Type, &it.OriginalName, &it.Title, &it.RelativePath, &it.SortKey, &it.Position, &it.Depth, &size, &modified, &mimeType, &ext, &kind, &lesson, &subtitle, &available, &duration)
		if err != nil {
			return nil, err
		}
		it.ParentID = parent.String
		it.SizeBytes = size
		it.DurationSeconds = duration
		it.MimeType = mimeType.String
		it.Extension = ext.String
		it.MediaKind = kind.String
		it.LessonID = lesson.String
		it.SubtitleFor = subtitle.String
		it.Available = available != 0
		if modified.Valid {
			it.ModifiedAt, _ = time.Parse(time.RFC3339Nano, modified.String)
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// LessonProgress is a per-profile playback record for a single lesson item.
// Progress is keyed by (library, profile, item); the server is single-tenant
// and has no accounts, so the client supplies an opaque profile identifier.
type LessonProgress struct {
	ItemID          string    `json:"itemId"`
	PositionSeconds float64   `json:"positionSeconds"`
	DurationSeconds float64   `json:"durationSeconds"`
	Completed       bool      `json:"completed"`
	UpdatedAt       time.Time `json:"updatedAt"`
}

// UpsertLessonProgress stores or replaces the progress record for one lesson.
// The item must already exist in the stable items table (FK enforced).
func (s *Store) UpsertLessonProgress(ctx context.Context, libraryID, profileID string, p LessonProgress) error {
	if p.UpdatedAt.IsZero() {
		p.UpdatedAt = time.Now().UTC()
	}
	completed := 0
	if p.Completed {
		completed = 1
	}
	_, err := s.DB.ExecContext(ctx, `INSERT INTO lesson_progress(library_id,profile_id,item_id,position_seconds,duration_seconds,completed,updated_at)
VALUES(?,?,?,?,?,?,?)
ON CONFLICT(library_id,profile_id,item_id) DO UPDATE SET position_seconds=excluded.position_seconds,duration_seconds=excluded.duration_seconds,completed=excluded.completed,updated_at=excluded.updated_at`,
		libraryID, profileID, p.ItemID, p.PositionSeconds, p.DurationSeconds, completed, p.UpdatedAt.Format(time.RFC3339Nano))
	return err
}

// LessonProgressFor returns the record for one lesson, or ok=false when the
// profile has no stored progress for it.
func (s *Store) LessonProgressFor(ctx context.Context, libraryID, profileID, itemID string) (LessonProgress, bool, error) {
	var p LessonProgress
	var completed int
	var updated string
	err := s.DB.QueryRowContext(ctx, `SELECT item_id,position_seconds,duration_seconds,completed,updated_at FROM lesson_progress WHERE library_id=? AND profile_id=? AND item_id=?`, libraryID, profileID, itemID).
		Scan(&p.ItemID, &p.PositionSeconds, &p.DurationSeconds, &completed, &updated)
	if err == sql.ErrNoRows {
		return LessonProgress{}, false, nil
	}
	if err != nil {
		return LessonProgress{}, false, err
	}
	p.Completed = completed != 0
	p.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
	return p, true, nil
}

// AllLessonProgress returns every progress record for a profile in the library.
// Course scoping (restricting to a single course's lessons) is applied by the
// caller, which owns the course/lesson tree structure.
func (s *Store) AllLessonProgress(ctx context.Context, libraryID, profileID string) ([]LessonProgress, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT item_id,position_seconds,duration_seconds,completed,updated_at FROM lesson_progress WHERE library_id=? AND profile_id=?`, libraryID, profileID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LessonProgress
	for rows.Next() {
		var p LessonProgress
		var completed int
		var updated string
		if err = rows.Scan(&p.ItemID, &p.PositionSeconds, &p.DurationSeconds, &completed, &updated); err != nil {
			return nil, err
		}
		p.Completed = completed != 0
		p.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
		out = append(out, p)
	}
	return out, rows.Err()
}
