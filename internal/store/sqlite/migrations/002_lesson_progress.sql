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
