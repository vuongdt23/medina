package sqlite

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

type SearchEntry struct {
	ItemID       string
	Type         string
	Title        string
	OriginalName string
}

// SearchEntries searches the active generation using an FTS5 MATCH expression.
func (s *Store) SearchEntries(ctx context.Context, libraryID, expression, entryType string, limit int) ([]SearchEntry, error) {
	var generation sql.NullString
	if err := s.DB.QueryRowContext(ctx, "SELECT active_generation_id FROM library_roots WHERE id=?", libraryID).Scan(&generation); err != nil {
		return nil, err
	}
	if !generation.Valid {
		return []SearchEntry{}, nil
	}
	query := `SELECT e.item_id,e.entry_type,e.title,e.original_name
		FROM entry_search f JOIN entry_snapshots e ON e.generation_id=f.generation_id AND e.item_id=f.item_id
		WHERE entry_search MATCH ? AND f.generation_id=? AND e.available=1`
	args := []any{expression, generation.String}
	if entryType != "" {
		query += ` AND e.entry_type=?`
		args = append(args, entryType)
	}
	query += ` ORDER BY bm25(entry_search,0,0,0,10,2),e.title,e.item_id LIMIT ?`
	args = append(args, limit)
	rows, err := s.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SearchEntry
	for rows.Next() {
		var e SearchEntry
		if err := rows.Scan(&e.ItemID, &e.Type, &e.Title, &e.OriginalName); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// RecentLessonProgress returns only records whose lessons are present in the
// active generation. Ordering is newest first, with item ID as a stable tie break.
func (s *Store) RecentLessonProgress(ctx context.Context, libraryID, profileID string, includeCompleted bool, limit int) ([]LessonProgress, error) {
	var generation sql.NullString
	if err := s.DB.QueryRowContext(ctx, "SELECT active_generation_id FROM library_roots WHERE id=?", libraryID).Scan(&generation); err != nil {
		return nil, err
	}
	if !generation.Valid {
		return []LessonProgress{}, nil
	}
	query := `SELECT p.item_id,p.position_seconds,p.duration_seconds,p.completed,p.updated_at
		FROM lesson_progress p JOIN entry_snapshots e ON e.item_id=p.item_id AND e.generation_id=?
		WHERE p.library_id=? AND p.profile_id=? AND e.entry_type='lesson' AND e.available=1`
	args := []any{generation.String, libraryID, profileID}
	if !includeCompleted {
		query += ` AND p.completed=0`
	}
	query += ` ORDER BY julianday(p.updated_at) DESC,p.updated_at DESC,p.item_id LIMIT ?`
	args = append(args, limit)
	rows, err := s.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LessonProgress
	for rows.Next() {
		var p LessonProgress
		var completed int
		var updated string
		if err := rows.Scan(&p.ItemID, &p.PositionSeconds, &p.DurationSeconds, &completed, &updated); err != nil {
			return nil, err
		}
		p.Completed = completed != 0
		p.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
		out = append(out, p)
	}
	return out, rows.Err()
}

// FTS queries are limited to quoted tokens with a trailing prefix operator.
func PrefixQuery(query string) string {
	words := strings.Fields(query)
	for i, word := range words {
		words[i] = `"` + strings.ReplaceAll(word, `"`, `""`) + `"*`
	}
	return strings.Join(words, " AND ")
}
