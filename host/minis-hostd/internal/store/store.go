// Package store keeps hostd's state in SQLite: cursors, events, batches, the outbox and status.
package store

import (
	"context"
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schema string

const schemaVersion = 1

const (
	Retention         = 30 * 24 * time.Hour
	MessageIDRingSize = 1000
)

type Source string

const (
	SourceMail   Source = "mail"
	SourceGitHub Source = "github"
)

type NoticeState string

const (
	NoticePending NoticeState = "pending"
	NoticeSent    NoticeState = "sent"
	// NoticeUncertain marks a send that may have reached Bark; it is never retried (spec §5.4).
	NoticeUncertain NoticeState = "uncertain"
	NoticeFailed    NoticeState = "failed"
)

var (
	ErrNotFound      = errors.New("store: not found")
	ErrSchemaVersion = errors.New("store: unsupported schema version")
)

// NotFoundError lists the ids that do not exist; errors.Is(err, ErrNotFound) holds.
type NotFoundError struct{ IDs []string }

func (e *NotFoundError) Error() string {
	return "store: no event " + strings.Join(e.IDs, ", ")
}

func (e *NotFoundError) Is(target error) bool { return target == ErrNotFound }

type Event struct {
	ID        string
	Key       string
	Source    Source
	CreatedAt time.Time
	Title     string
	Summary   string
	URL       string
	Body      json.RawMessage
	Decision  string
	Reason    string
	BatchID   string
	AckedAt   *time.Time
}

type Batch struct {
	ID       string
	OpenedAt time.Time
	FlushAt  time.Time
	ClosedAt *time.Time
	Events   []Event // oldest first
}

// Notice is one notification to send. Key is unique across the outbox, so a notice is enqueued at
// most once however often the same event or batch is processed.
type Notice struct {
	Key     string
	EventID string
	BatchID string
	Title   string
	Body    string
	URL     string
}

type PendingNotice struct {
	Notice
	Attempts  int
	CreatedAt time.Time
}

type NoticeOutcome struct {
	State         NoticeState
	Error         string
	NextAttemptAt time.Time // used when State is NoticePending (a retry)
}

type BatchJoin struct {
	ID      string
	FlushAt time.Time
}

// Placement is what pacing decided for a pushed event: send it now, hold it in a batch, or
// neither (stored only).
type Placement struct {
	Notice *Notice
	Batch  *BatchJoin
}

type CursorUpdate struct {
	Source string
	Value  string
}

type MessageIDEntry struct {
	Account   string
	MessageID string
}

type EventRecord struct {
	Event     Event
	Cursor    *CursorUpdate
	MessageID *MessageIDEntry
	Placement Placement
	Pacing    *string // new pacing state, opaque to the store
}

type SourceStatus struct {
	Name      string
	Kind      string
	OK        bool
	Detail    string
	LastOKAt  *time.Time
	UpdatedAt time.Time
}

type Store struct {
	db *sql.DB
}

// Open opens or creates the database. A read-only store is what the CLI uses, so a query from the
// app never blocks the daemon's writes for long.
func Open(path string, readOnly bool) (*Store, error) {
	pragmas := "_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)"
	dsn := "file:" + path + "?" + pragmas + "&_pragma=journal_mode(WAL)"
	if readOnly {
		dsn = "file:" + path + "?mode=ro&" + pragmas
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	// One connection: SQLite has one writer anyway, and it keeps transactions strictly ordered.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if readOnly {
		err = s.checkVersion()
	} else {
		err = s.migrate()
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	if _, err := s.db.Exec(schema); err != nil {
		return fmt.Errorf("store: create schema: %w", err)
	}
	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM schema_version`).Scan(&count); err != nil {
		return fmt.Errorf("store: read schema version: %w", err)
	}
	if count == 0 {
		if _, err := s.db.Exec(`INSERT INTO schema_version (version) VALUES (?)`, schemaVersion); err != nil {
			return fmt.Errorf("store: write schema version: %w", err)
		}
		return nil
	}
	if err := s.checkVersion(); err != nil {
		return err
	}
	return s.rewriteLegacyLinks()
}

// rewriteLegacyLinks moves links stored by 0.2.0 to pico://, which only the fork claims; a queued
// minis:// notice would otherwise still open an upstream Minis on the same phone (decision D22).
func (s *Store) rewriteLegacyLinks() error {
	for _, table := range []string{"events", "outbox"} {
		if _, err := s.db.Exec(`UPDATE ` + table + ` SET url = 'pico://' || substr(url, length('minis://') + 1)
			WHERE url LIKE 'minis://host-event/%'`); err != nil {
			return fmt.Errorf("store: rewrite %s links: %w", table, err)
		}
	}
	return nil
}

func (s *Store) checkVersion() error {
	var version int
	if err := s.db.QueryRow(`SELECT version FROM schema_version`).Scan(&version); err != nil {
		return fmt.Errorf("store: read schema version: %w", err)
	}
	if version != schemaVersion {
		return fmt.Errorf("%w: database has %d, this minis-hostd knows %d", ErrSchemaVersion, version, schemaVersion)
	}
	return nil
}

func millis(t time.Time) int64 { return t.UnixMilli() }

func fromMillis(ms int64) time.Time { return time.UnixMilli(ms).UTC() }

func optionalTime(ms sql.NullInt64) *time.Time {
	if !ms.Valid {
		return nil
	}
	t := fromMillis(ms.Int64)
	return &t
}

func (s *Store) inTx(fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(context.Background(), nil)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: commit: %w", err)
	}
	return nil
}

func (s *Store) Cursor(source string) (string, bool, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM cursors WHERE source = ?`, source).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("store: read cursor %s: %w", source, err)
	}
	return value, true, nil
}

// SetCursor moves a cursor without an event: a baseline, a reconcile that found nothing, a 304.
func (s *Store) SetCursor(update CursorUpdate) error {
	return s.inTx(func(tx *sql.Tx) error { return setCursor(tx, update) })
}

func setCursor(tx *sql.Tx, update CursorUpdate) error {
	_, err := tx.Exec(`INSERT INTO cursors (source, value) VALUES (?, ?)
		ON CONFLICT (source) DO UPDATE SET value = excluded.value`, update.Source, update.Value)
	if err != nil {
		return fmt.Errorf("store: write cursor %s: %w", update.Source, err)
	}
	return nil
}

func (s *Store) SeenMessageID(account, messageID string) (bool, error) {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM message_ids WHERE account = ? AND message_id = ?`, account, messageID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("store: read message id: %w", err)
	}
	return true, nil
}

func (s *Store) Pacing() (string, bool, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM pacing WHERE id = 1`).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("store: read pacing: %w", err)
	}
	return value, true, nil
}

func setPacing(tx *sql.Tx, value string) error {
	_, err := tx.Exec(`INSERT INTO pacing (id, value) VALUES (1, ?)
		ON CONFLICT (id) DO UPDATE SET value = excluded.value`, value)
	if err != nil {
		return fmt.Errorf("store: write pacing: %w", err)
	}
	return nil
}

// RecordEvent writes everything one candidate causes in a single transaction (spec §5.4). An event
// whose key exists is not written again, and its placement and pacing are skipped, but the cursor
// and message id still advance so the source does not refetch it forever.
func (s *Store) RecordEvent(record EventRecord, now time.Time) (inserted bool, err error) {
	err = s.inTx(func(tx *sql.Tx) error {
		if record.Cursor != nil {
			if err := setCursor(tx, *record.Cursor); err != nil {
				return err
			}
		}
		if record.MessageID != nil {
			if err := rememberMessageID(tx, *record.MessageID, now); err != nil {
				return err
			}
		}
		e := record.Event
		result, err := tx.Exec(`INSERT INTO events
			(id, key, source, created_at, title, summary, url, body, decision, reason)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (key) DO NOTHING`,
			e.ID, e.Key, string(e.Source), millis(e.CreatedAt), e.Title, e.Summary, e.URL, string(e.Body), e.Decision, e.Reason)
		if err != nil {
			return fmt.Errorf("store: insert event %s: %w", e.Key, err)
		}
		rows, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: insert event %s: %w", e.Key, err)
		}
		if rows == 0 {
			return nil
		}
		inserted = true
		if join := record.Placement.Batch; join != nil {
			if _, err := tx.Exec(`INSERT INTO batches (id, opened_at, flush_at) VALUES (?, ?, ?)
				ON CONFLICT (id) DO UPDATE SET flush_at = excluded.flush_at`,
				join.ID, millis(now), millis(join.FlushAt)); err != nil {
				return fmt.Errorf("store: open batch %s: %w", join.ID, err)
			}
			if _, err := tx.Exec(`UPDATE events SET batch_id = ? WHERE id = ?`, join.ID, e.ID); err != nil {
				return fmt.Errorf("store: join batch %s: %w", join.ID, err)
			}
		}
		if notice := record.Placement.Notice; notice != nil {
			if err := enqueue(tx, *notice, now); err != nil {
				return err
			}
		}
		if record.Pacing != nil {
			return setPacing(tx, *record.Pacing)
		}
		return nil
	})
	if err != nil {
		return false, err
	}
	return inserted, nil
}

func rememberMessageID(tx *sql.Tx, entry MessageIDEntry, now time.Time) error {
	if _, err := tx.Exec(`INSERT INTO message_ids (account, message_id, seen_at) VALUES (?, ?, ?)
		ON CONFLICT DO NOTHING`, entry.Account, entry.MessageID, millis(now)); err != nil {
		return fmt.Errorf("store: remember message id: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM message_ids WHERE account = ? AND message_id NOT IN (
		SELECT message_id FROM message_ids WHERE account = ? ORDER BY seen_at DESC, message_id DESC LIMIT ?)`,
		entry.Account, entry.Account, MessageIDRingSize); err != nil {
		return fmt.Errorf("store: trim message ids: %w", err)
	}
	return nil
}

func enqueue(tx *sql.Tx, notice Notice, now time.Time) error {
	_, err := tx.Exec(`INSERT INTO outbox
		(notice_key, event_id, batch_id, title, body, url, state, next_attempt_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (notice_key) DO NOTHING`,
		notice.Key, notice.EventID, notice.BatchID, notice.Title, notice.Body, notice.URL,
		string(NoticePending), millis(now), millis(now))
	if err != nil {
		return fmt.Errorf("store: enqueue notice %s: %w", notice.Key, err)
	}
	return nil
}

// EnqueueNotice adds a notice that belongs to no single event, such as "Daily cap reached".
func (s *Store) EnqueueNotice(notice Notice, pacing *string, now time.Time) error {
	return s.inTx(func(tx *sql.Tx) error {
		if err := enqueue(tx, notice, now); err != nil {
			return err
		}
		if pacing != nil {
			return setPacing(tx, *pacing)
		}
		return nil
	})
}

// DueBatches returns open batches whose hold has ended, with their events.
func (s *Store) DueBatches(now time.Time) ([]Batch, error) {
	rows, err := s.db.Query(`SELECT id FROM batches WHERE closed_at IS NULL AND flush_at <= ? ORDER BY id`, millis(now))
	if err != nil {
		return nil, fmt.Errorf("store: list due batches: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, fmt.Errorf("store: list due batches: %w", err)
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list due batches: %w", err)
	}
	batches := make([]Batch, 0, len(ids))
	for _, id := range ids {
		batch, err := s.GetBatch(id)
		if err != nil {
			return nil, err
		}
		batches = append(batches, batch)
	}
	return batches, nil
}

// CloseBatch marks the batch closed and enqueues its notice in one transaction, so a restart
// between the two can neither lose nor repeat it.
func (s *Store) CloseBatch(id string, notice Notice, pacing *string, now time.Time) error {
	return s.inTx(func(tx *sql.Tx) error {
		result, err := tx.Exec(`UPDATE batches SET closed_at = ? WHERE id = ? AND closed_at IS NULL`, millis(now), id)
		if err != nil {
			return fmt.Errorf("store: close batch %s: %w", id, err)
		}
		rows, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: close batch %s: %w", id, err)
		}
		if rows == 0 {
			return &NotFoundError{IDs: []string{id}}
		}
		if err := enqueue(tx, notice, now); err != nil {
			return err
		}
		if pacing != nil {
			return setPacing(tx, *pacing)
		}
		return nil
	})
}

func (s *Store) PendingNotices(now time.Time, limit int) ([]PendingNotice, error) {
	rows, err := s.db.Query(`SELECT notice_key, event_id, batch_id, title, body, url, attempts, created_at
		FROM outbox WHERE state = ? AND next_attempt_at <= ? ORDER BY created_at, notice_key LIMIT ?`,
		string(NoticePending), millis(now), limit)
	if err != nil {
		return nil, fmt.Errorf("store: list pending notices: %w", err)
	}
	defer rows.Close()
	var notices []PendingNotice
	for rows.Next() {
		var n PendingNotice
		var eventID, batchID sql.NullString
		var created int64
		if err := rows.Scan(&n.Key, &eventID, &batchID, &n.Title, &n.Body, &n.URL, &n.Attempts, &created); err != nil {
			return nil, fmt.Errorf("store: list pending notices: %w", err)
		}
		n.EventID, n.BatchID, n.CreatedAt = eventID.String, batchID.String, fromMillis(created)
		notices = append(notices, n)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list pending notices: %w", err)
	}
	return notices, nil
}

func (s *Store) MarkNotice(key string, outcome NoticeOutcome) error {
	return s.inTx(func(tx *sql.Tx) error {
		result, err := tx.Exec(`UPDATE outbox SET state = ?, last_error = ?, attempts = attempts + 1,
			next_attempt_at = ? WHERE notice_key = ?`,
			string(outcome.State), outcome.Error, millis(outcome.NextAttemptAt), key)
		if err != nil {
			return fmt.Errorf("store: mark notice %s: %w", key, err)
		}
		rows, err := result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: mark notice %s: %w", key, err)
		}
		if rows == 0 {
			return &NotFoundError{IDs: []string{key}}
		}
		return nil
	})
}

const eventColumns = `id, key, source, created_at, title, summary, url, body, decision, reason, batch_id, acked_at`

type scanner interface{ Scan(dest ...any) error }

func scanEvent(row scanner) (Event, error) {
	var e Event
	var source, body string
	var created int64
	var batchID sql.NullString
	var acked sql.NullInt64
	if err := row.Scan(&e.ID, &e.Key, &source, &created, &e.Title, &e.Summary, &e.URL, &body,
		&e.Decision, &e.Reason, &batchID, &acked); err != nil {
		return Event{}, err
	}
	e.Source, e.CreatedAt, e.Body = Source(source), fromMillis(created), json.RawMessage(body)
	e.BatchID, e.AckedAt = batchID.String, optionalTime(acked)
	return e, nil
}

func (s *Store) queryEvents(query string, args ...any) ([]Event, error) {
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list events: %w", err)
	}
	defer rows.Close()
	var events []Event
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, fmt.Errorf("store: list events: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list events: %w", err)
	}
	return events, nil
}

// ListEvents returns events newest first. Ids are ULIDs, so ordering by id orders by time.
func (s *Store) ListEvents(limit int, before string) ([]Event, error) {
	if before == "" {
		return s.queryEvents(`SELECT `+eventColumns+` FROM events ORDER BY id DESC LIMIT ?`, limit)
	}
	return s.queryEvents(`SELECT `+eventColumns+` FROM events WHERE id < ? ORDER BY id DESC LIMIT ?`, before, limit)
}

func (s *Store) GetEvent(id string) (Event, error) {
	e, err := scanEvent(s.db.QueryRow(`SELECT `+eventColumns+` FROM events WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Event{}, &NotFoundError{IDs: []string{id}}
	}
	if err != nil {
		return Event{}, fmt.Errorf("store: read event %s: %w", id, err)
	}
	return e, nil
}

func (s *Store) GetBatch(id string) (Batch, error) {
	var b Batch
	var opened, flush int64
	var closed sql.NullInt64
	err := s.db.QueryRow(`SELECT id, opened_at, flush_at, closed_at FROM batches WHERE id = ?`, id).
		Scan(&b.ID, &opened, &flush, &closed)
	if errors.Is(err, sql.ErrNoRows) {
		return Batch{}, &NotFoundError{IDs: []string{id}}
	}
	if err != nil {
		return Batch{}, fmt.Errorf("store: read batch %s: %w", id, err)
	}
	b.OpenedAt, b.FlushAt, b.ClosedAt = fromMillis(opened), fromMillis(flush), optionalTime(closed)
	b.Events, err = s.queryEvents(`SELECT `+eventColumns+` FROM events WHERE batch_id = ? ORDER BY id`, id)
	if err != nil {
		return Batch{}, err
	}
	return b, nil
}

// Ack marks events seen. Unknown ids fail the whole call so the app learns about a pruned event.
func (s *Store) Ack(ids []string, now time.Time) error {
	return s.inTx(func(tx *sql.Tx) error {
		var missing []string
		for _, id := range ids {
			result, err := tx.Exec(`UPDATE events SET acked_at = COALESCE(acked_at, ?) WHERE id = ?`, millis(now), id)
			if err != nil {
				return fmt.Errorf("store: ack %s: %w", id, err)
			}
			rows, err := result.RowsAffected()
			if err != nil {
				return fmt.Errorf("store: ack %s: %w", id, err)
			}
			if rows == 0 {
				missing = append(missing, id)
			}
		}
		if len(missing) > 0 {
			return &NotFoundError{IDs: missing}
		}
		return nil
	})
}

// Prune deletes what is older than the retention period. Cursors, pacing, source status and the
// heartbeat are kept: they are state, not history.
func (s *Store) Prune(now time.Time) error {
	cutoff := millis(now.Add(-Retention))
	return s.inTx(func(tx *sql.Tx) error {
		statements := []string{
			`DELETE FROM outbox WHERE created_at < ?`,
			`DELETE FROM events WHERE created_at < ?`,
			`DELETE FROM batches WHERE closed_at < ? AND id NOT IN (SELECT batch_id FROM events WHERE batch_id IS NOT NULL)`,
			`DELETE FROM message_ids WHERE seen_at < ?`,
		}
		for _, statement := range statements {
			if _, err := tx.Exec(statement, cutoff); err != nil {
				return fmt.Errorf("store: prune: %w", err)
			}
		}
		return nil
	})
}

func (s *Store) StampSource(name, kind string, ok bool, detail string, now time.Time) error {
	return s.inTx(func(tx *sql.Tx) error {
		var lastOK any
		if ok {
			lastOK = millis(now)
		}
		_, err := tx.Exec(`INSERT INTO sources (name, kind, ok, detail, last_ok_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT (name) DO UPDATE SET kind = excluded.kind, ok = excluded.ok, detail = excluded.detail,
				last_ok_at = COALESCE(excluded.last_ok_at, sources.last_ok_at), updated_at = excluded.updated_at`,
			name, kind, ok, detail, lastOK, millis(now))
		if err != nil {
			return fmt.Errorf("store: stamp source %s: %w", name, err)
		}
		return nil
	})
}

func (s *Store) Sources() ([]SourceStatus, error) {
	rows, err := s.db.Query(`SELECT name, kind, ok, detail, last_ok_at, updated_at FROM sources ORDER BY name`)
	if err != nil {
		return nil, fmt.Errorf("store: list sources: %w", err)
	}
	defer rows.Close()
	var statuses []SourceStatus
	for rows.Next() {
		var st SourceStatus
		var lastOK sql.NullInt64
		var updated int64
		if err := rows.Scan(&st.Name, &st.Kind, &st.OK, &st.Detail, &lastOK, &updated); err != nil {
			return nil, fmt.Errorf("store: list sources: %w", err)
		}
		st.LastOKAt, st.UpdatedAt = optionalTime(lastOK), fromMillis(updated)
		statuses = append(statuses, st)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list sources: %w", err)
	}
	return statuses, nil
}

func (s *Store) Beat(now time.Time) error {
	return s.inTx(func(tx *sql.Tx) error {
		_, err := tx.Exec(`INSERT INTO heartbeat (id, at) VALUES (1, ?)
			ON CONFLICT (id) DO UPDATE SET at = excluded.at`, millis(now))
		if err != nil {
			return fmt.Errorf("store: heartbeat: %w", err)
		}
		return nil
	})
}

func (s *Store) Heartbeat() (time.Time, bool, error) {
	var at int64
	err := s.db.QueryRow(`SELECT at FROM heartbeat WHERE id = 1`).Scan(&at)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("store: read heartbeat: %w", err)
	}
	return fromMillis(at), true, nil
}
