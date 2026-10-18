CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);

-- Opaque per-source cursor: IMAP stores {uidValidity, lastSeenUid}, GitHub its Last-Modified.
CREATE TABLE IF NOT EXISTS cursors (
    source TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS batches (
    id        TEXT PRIMARY KEY,
    opened_at INTEGER NOT NULL,
    flush_at  INTEGER NOT NULL,
    closed_at INTEGER
);

CREATE TABLE IF NOT EXISTS events (
    id         TEXT PRIMARY KEY,
    key        TEXT NOT NULL UNIQUE,
    source     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    title      TEXT NOT NULL,
    summary    TEXT NOT NULL,
    url        TEXT NOT NULL,
    body       TEXT NOT NULL,
    decision   TEXT NOT NULL,
    reason     TEXT NOT NULL,
    batch_id   TEXT REFERENCES batches(id),
    acked_at   INTEGER
);
CREATE INDEX IF NOT EXISTS events_batch ON events(batch_id);

CREATE TABLE IF NOT EXISTS outbox (
    notice_key      TEXT PRIMARY KEY,
    event_id        TEXT,
    batch_id        TEXT,
    title           TEXT NOT NULL,
    body            TEXT NOT NULL,
    url             TEXT NOT NULL,
    state           TEXT NOT NULL,
    attempts        INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL,
    last_error      TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(state, next_attempt_at);

CREATE TABLE IF NOT EXISTS message_ids (
    account    TEXT NOT NULL,
    message_id TEXT NOT NULL,
    seen_at    INTEGER NOT NULL,
    PRIMARY KEY (account, message_id)
);

-- One row: the pacing state, written in the same transaction as the event it was decided for.
CREATE TABLE IF NOT EXISTS pacing (
    id    INTEGER PRIMARY KEY CHECK (id = 1),
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sources (
    name       TEXT PRIMARY KEY,
    kind       TEXT NOT NULL,
    ok         INTEGER NOT NULL,
    detail     TEXT NOT NULL,
    last_ok_at INTEGER,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS heartbeat (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    at INTEGER NOT NULL
);
