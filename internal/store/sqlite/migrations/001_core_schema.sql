CREATE TABLE library_roots (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    canonical_path TEXT NOT NULL UNIQUE,
    active_generation_id TEXT,
    scan_state TEXT NOT NULL DEFAULT 'idle',
    last_scan_started_at TEXT,
    last_scan_completed_at TEXT,
    last_scan_error TEXT
);

CREATE TABLE scan_generations (
    id TEXT PRIMARY KEY,
    library_id TEXT NOT NULL REFERENCES library_roots(id),
    status TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE TABLE items (
    id TEXT PRIMARY KEY,
    library_id TEXT NOT NULL REFERENCES library_roots(id),
    created_at TEXT NOT NULL
);

CREATE TABLE entry_snapshots (
    generation_id TEXT NOT NULL REFERENCES scan_generations(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL REFERENCES items(id),
    parent_item_id TEXT,
    entry_type TEXT NOT NULL,
    original_name TEXT NOT NULL,
    title TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    sort_key TEXT NOT NULL,
    position INTEGER NOT NULL,
    depth INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    modified_at TEXT NOT NULL,
    mime_type TEXT,
    extension TEXT,
    media_kind TEXT,
    lesson_id TEXT,
    subtitle_for TEXT,
    available INTEGER NOT NULL DEFAULT 1,
    duration_seconds REAL NOT NULL DEFAULT 0,
    PRIMARY KEY(generation_id,item_id),
    UNIQUE(generation_id,relative_path),
    FOREIGN KEY(generation_id,parent_item_id) REFERENCES entry_snapshots(generation_id,item_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX entry_parent_idx ON entry_snapshots(generation_id,parent_item_id,position);
CREATE INDEX entry_type_idx ON entry_snapshots(generation_id,entry_type,available);
CREATE INDEX entry_lesson_idx ON entry_snapshots(generation_id,lesson_id);
CREATE INDEX entry_subtitle_idx ON entry_snapshots(generation_id,subtitle_for);
CREATE INDEX generation_library_idx ON scan_generations(library_id,status);

CREATE TABLE lesson_progress (
    library_id       TEXT NOT NULL REFERENCES library_roots(id),
    profile_id       TEXT NOT NULL,
    item_id          TEXT NOT NULL REFERENCES items(id),
    position_seconds REAL NOT NULL DEFAULT 0,
    duration_seconds REAL NOT NULL DEFAULT 0,
    completed        INTEGER NOT NULL DEFAULT 0,
    updated_at       TEXT NOT NULL,
    PRIMARY KEY(library_id, profile_id, item_id)
);

CREATE INDEX lesson_progress_profile_idx ON lesson_progress(library_id, profile_id);

-- Full-text search over the active generation's entries. The index is kept in
-- sync during scans. item_id/generation_id/entry_type are UNINDEXED so search
-- queries can scope hits and resolve them back to entry_snapshots.
-- Thumbnails are cached on disk, not represented in this schema.
CREATE VIRTUAL TABLE entry_search USING fts5(
    item_id UNINDEXED,
    generation_id UNINDEXED,
    entry_type UNINDEXED,
    title,
    original_name,
    tokenize = 'unicode61 remove_diacritics 2'
);
