package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "state.db")
	s, err := Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, path
}

func event(id, key string) Event {
	return Event{
		ID: id, Key: key, Source: SourceMail, CreatedAt: t0,
		Title: "Alice Chen", Summary: "Re: 合同 “第三版”", URL: "minis://host-event/mac-mini/" + id,
		Body: json.RawMessage(`{"text":"hi"}`), Decision: "push", Reason: "allowed",
	}
}

func cursor(value string) *CursorUpdate { return &CursorUpdate{Source: "mail:personal", Value: value} }

func singleNotice(e Event) Placement {
	return Placement{Notice: &Notice{Key: e.Key, EventID: e.ID, Title: e.Title, Body: e.Summary, URL: e.URL}}
}

func strPtr(s string) *string { return &s }

func TestEventCursorNoticeAndPacingCommitTogether(t *testing.T) {
	s, _ := openTemp(t)
	e := event("01A", "mail:personal:7:100")
	inserted, err := s.RecordEvent(EventRecord{
		Event: e, Cursor: cursor("7:100"), MessageID: &MessageIDEntry{Account: "personal", MessageID: "<a@x>"},
		Placement: singleNotice(e), Pacing: strPtr(`{"last":1}`),
	}, t0)
	if err != nil || !inserted {
		t.Fatalf("inserted %v err %v", inserted, err)
	}
	if value, ok, _ := s.Cursor("mail:personal"); !ok || value != "7:100" {
		t.Errorf("cursor %q %v", value, ok)
	}
	if seen, _ := s.SeenMessageID("personal", "<a@x>"); !seen {
		t.Error("message id not remembered")
	}
	if value, _, _ := s.Pacing(); value != `{"last":1}` {
		t.Errorf("pacing %q", value)
	}
	pending, err := s.PendingNotices(t0, 10)
	if err != nil || len(pending) != 1 || pending[0].Key != e.Key || pending[0].Body != e.Summary {
		t.Fatalf("pending %+v err %v", pending, err)
	}
	got, err := s.GetEvent("01A")
	if err != nil || got.Title != e.Title || string(got.Body) != string(e.Body) || !got.CreatedAt.Equal(t0) {
		t.Fatalf("event %+v err %v", got, err)
	}
}

func TestDuplicateKeyAdvancesCursorButEnqueuesNothing(t *testing.T) {
	s, _ := openTemp(t)
	e := event("01A", "mail:personal:7:100")
	if _, err := s.RecordEvent(EventRecord{Event: e, Cursor: cursor("7:100"), Placement: singleNotice(e)}, t0); err != nil {
		t.Fatal(err)
	}
	again := event("01B", e.Key)
	inserted, err := s.RecordEvent(EventRecord{
		Event: again, Cursor: cursor("7:101"), Placement: singleNotice(again), Pacing: strPtr("changed"),
	}, t0)
	if err != nil || inserted {
		t.Fatalf("inserted %v err %v", inserted, err)
	}
	if value, _, _ := s.Cursor("mail:personal"); value != "7:101" {
		t.Errorf("cursor %q, want it advanced", value)
	}
	if _, ok, _ := s.Pacing(); ok {
		t.Error("pacing written for a duplicate")
	}
	if pending, _ := s.PendingNotices(t0, 10); len(pending) != 1 {
		t.Errorf("%d notices, want 1", len(pending))
	}
	if _, err := s.GetEvent("01B"); !errors.Is(err, ErrNotFound) {
		t.Errorf("duplicate stored: %v", err)
	}
}

func TestFailedNoticeRollsBackTheWholeEvent(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.db.Exec(`DROP TABLE outbox`); err != nil {
		t.Fatal(err)
	}
	e := event("01A", "mail:personal:7:100")
	if _, err := s.RecordEvent(EventRecord{Event: e, Cursor: cursor("7:100"), Placement: singleNotice(e)}, t0); err == nil {
		t.Fatal("want error")
	}
	if _, ok, _ := s.Cursor("mail:personal"); ok {
		t.Error("cursor committed without its event")
	}
	if _, err := s.GetEvent("01A"); !errors.Is(err, ErrNotFound) {
		t.Errorf("event committed: %v", err)
	}
}

func TestNoticeKeyIsEnqueuedOnce(t *testing.T) {
	s, _ := openTemp(t)
	n := Notice{Key: "cap:2026-10-19", Title: "Daily cap reached"}
	for range 3 {
		if err := s.EnqueueNotice(n, nil, t0); err != nil {
			t.Fatal(err)
		}
	}
	if pending, _ := s.PendingNotices(t0, 10); len(pending) != 1 {
		t.Fatalf("%d notices", len(pending))
	}
}

func TestBatchCollectsEventsAndClosesOnce(t *testing.T) {
	s, _ := openTemp(t)
	flush := t0.Add(2 * time.Minute)
	for i, id := range []string{"01A", "01B", "01C"} {
		e := event(id, fmt.Sprintf("mail:personal:7:%d", 100+i))
		placement := Placement{Batch: &BatchJoin{ID: "01BATCH", FlushAt: flush}}
		if _, err := s.RecordEvent(EventRecord{Event: e, Placement: placement}, t0); err != nil {
			t.Fatal(err)
		}
	}
	if due, _ := s.DueBatches(flush.Add(-time.Second)); len(due) != 0 {
		t.Fatalf("batch due before its flush time")
	}
	due, err := s.DueBatches(flush)
	if err != nil || len(due) != 1 || len(due[0].Events) != 3 || due[0].Events[0].ID != "01A" {
		t.Fatalf("due %+v err %v", due, err)
	}
	notice := Notice{Key: "batch:01BATCH", BatchID: "01BATCH", Title: "3 new"}
	if err := s.CloseBatch("01BATCH", notice, strPtr("after"), flush); err != nil {
		t.Fatal(err)
	}
	if err := s.CloseBatch("01BATCH", notice, nil, flush); !errors.Is(err, ErrNotFound) {
		t.Errorf("second close: %v", err)
	}
	if due, _ := s.DueBatches(flush.Add(time.Hour)); len(due) != 0 {
		t.Error("closed batch still due")
	}
	if pending, _ := s.PendingNotices(flush, 10); len(pending) != 1 || pending[0].BatchID != "01BATCH" {
		t.Errorf("pending %+v", pending)
	}
}

func TestOpenBatchSurvivesReopen(t *testing.T) {
	s, path := openTemp(t)
	e := event("01A", "mail:personal:7:100")
	flush := t0.Add(2 * time.Minute)
	if _, err := s.RecordEvent(EventRecord{Event: e, Placement: Placement{Batch: &BatchJoin{ID: "01BATCH", FlushAt: flush}}}, t0); err != nil {
		t.Fatal(err)
	}
	s.Close()
	reopened, err := Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if due, _ := reopened.DueBatches(flush); len(due) != 1 {
		t.Fatalf("batch lost across reopen")
	}
}

func TestMarkNoticeOutcomes(t *testing.T) {
	s, _ := openTemp(t)
	for _, key := range []string{"a", "b", "c"} {
		if err := s.EnqueueNotice(Notice{Key: key}, nil, t0); err != nil {
			t.Fatal(err)
		}
	}
	retryAt := t0.Add(time.Minute)
	steps := map[string]NoticeOutcome{
		"a": {State: NoticeSent},
		"b": {State: NoticePending, Error: "HTTP 500", NextAttemptAt: retryAt},
		"c": {State: NoticeUncertain, Error: "timeout after write"},
	}
	for key, outcome := range steps {
		if err := s.MarkNotice(key, outcome); err != nil {
			t.Fatal(err)
		}
	}
	if pending, _ := s.PendingNotices(t0, 10); len(pending) != 0 {
		t.Errorf("retry due early: %+v", pending)
	}
	pending, _ := s.PendingNotices(retryAt, 10)
	if len(pending) != 1 || pending[0].Key != "b" || pending[0].Attempts != 1 {
		t.Errorf("pending %+v", pending)
	}
	if err := s.MarkNotice("missing", NoticeOutcome{State: NoticeSent}); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown notice: %v", err)
	}
}

func TestListEventsNewestFirstWithCursor(t *testing.T) {
	s, _ := openTemp(t)
	for i, id := range []string{"01A", "01B", "01C"} {
		if _, err := s.RecordEvent(EventRecord{Event: event(id, fmt.Sprint("k", i))}, t0); err != nil {
			t.Fatal(err)
		}
	}
	page, _ := s.ListEvents(2, "")
	if len(page) != 2 || page[0].ID != "01C" || page[1].ID != "01B" {
		t.Fatalf("page 1 %+v", page)
	}
	page, _ = s.ListEvents(2, "01B")
	if len(page) != 1 || page[0].ID != "01A" {
		t.Fatalf("page 2 %+v", page)
	}
}

func TestAckUnknownIDFailsWithoutAckingOthers(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.RecordEvent(EventRecord{Event: event("01A", "k")}, t0); err != nil {
		t.Fatal(err)
	}
	err := s.Ack([]string{"01A", "01Z"}, t0)
	var notFound *NotFoundError
	if !errors.As(err, &notFound) || len(notFound.IDs) != 1 || notFound.IDs[0] != "01Z" {
		t.Fatalf("err %v", err)
	}
	if e, _ := s.GetEvent("01A"); e.AckedAt != nil {
		t.Error("ack committed despite the unknown id")
	}
	if err := s.Ack([]string{"01A"}, t0); err != nil {
		t.Fatal(err)
	}
	if e, _ := s.GetEvent("01A"); e.AckedAt == nil || !e.AckedAt.Equal(t0) {
		t.Errorf("acked %v", e.AckedAt)
	}
}

func TestGetUnknownEventAndBatch(t *testing.T) {
	s, _ := openTemp(t)
	if _, err := s.GetEvent("nope"); !errors.Is(err, ErrNotFound) {
		t.Errorf("event: %v", err)
	}
	if _, err := s.GetBatch("nope"); !errors.Is(err, ErrNotFound) {
		t.Errorf("batch: %v", err)
	}
}

func TestMessageIDRingKeepsTheNewest(t *testing.T) {
	s, _ := openTemp(t)
	for i := range MessageIDRingSize + 5 {
		e := event(fmt.Sprintf("%05d", i), fmt.Sprint("k", i))
		record := EventRecord{Event: e, MessageID: &MessageIDEntry{Account: "personal", MessageID: fmt.Sprint("<", i, ">")}}
		if _, err := s.RecordEvent(record, t0.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	if seen, _ := s.SeenMessageID("personal", "<0>"); seen {
		t.Error("oldest id kept past the ring size")
	}
	if seen, _ := s.SeenMessageID("personal", fmt.Sprint("<", MessageIDRingSize+4, ">")); !seen {
		t.Error("newest id dropped")
	}
	var count int
	s.db.QueryRow(`SELECT COUNT(*) FROM message_ids`).Scan(&count)
	if count != MessageIDRingSize {
		t.Errorf("%d ids kept", count)
	}
}

func TestPruneDropsHistoryAndKeepsState(t *testing.T) {
	s, _ := openTemp(t)
	old := event("01OLD", "old")
	old.CreatedAt = t0.Add(-31 * 24 * time.Hour)
	if _, err := s.RecordEvent(EventRecord{
		Event: old, Cursor: cursor("7:1"), Placement: singleNotice(old),
		MessageID: &MessageIDEntry{Account: "personal", MessageID: "<old>"},
	}, old.CreatedAt); err != nil {
		t.Fatal(err)
	}
	fresh := event("01NEW", "new")
	if _, err := s.RecordEvent(EventRecord{Event: fresh}, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Prune(t0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetEvent("01OLD"); !errors.Is(err, ErrNotFound) {
		t.Error("old event kept")
	}
	if _, err := s.GetEvent("01NEW"); err != nil {
		t.Error("fresh event pruned")
	}
	if pending, _ := s.PendingNotices(t0, 10); len(pending) != 0 {
		t.Error("old outbox row kept")
	}
	if seen, _ := s.SeenMessageID("personal", "<old>"); seen {
		t.Error("old message id kept")
	}
	if _, ok, _ := s.Cursor("mail:personal"); !ok {
		t.Error("cursor pruned")
	}
}

func TestReadOnlyStoreRefusesWrites(t *testing.T) {
	_, path := openTemp(t)
	ro, err := Open(path, true)
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	if err := ro.Ack([]string{"x"}, t0); err == nil || errors.Is(err, ErrNotFound) {
		t.Errorf("write on read-only store: %v", err)
	}
	if _, err := ro.ListEvents(1, ""); err != nil {
		t.Errorf("read on read-only store: %v", err)
	}
}

func TestNewerSchemaIsRefused(t *testing.T) {
	s, path := openTemp(t)
	if _, err := s.db.Exec(`UPDATE schema_version SET version = 2`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	for _, readOnly := range []bool{false, true} {
		if _, err := Open(path, readOnly); !errors.Is(err, ErrSchemaVersion) {
			t.Errorf("readOnly=%v: %v", readOnly, err)
		}
	}
}

func TestSourceStatusKeepsLastSuccess(t *testing.T) {
	s, _ := openTemp(t)
	if err := s.StampSource("mail:personal", "imap", true, "", t0); err != nil {
		t.Fatal(err)
	}
	later := t0.Add(time.Hour)
	if err := s.StampSource("mail:personal", "imap", false, "Gmail rejected the app password", later); err != nil {
		t.Fatal(err)
	}
	statuses, _ := s.Sources()
	st := statuses[0]
	if st.OK || st.Detail != "Gmail rejected the app password" || st.LastOKAt == nil || !st.LastOKAt.Equal(t0) || !st.UpdatedAt.Equal(later) {
		t.Errorf("status %+v", st)
	}
	if err := s.Beat(later); err != nil {
		t.Fatal(err)
	}
	if at, ok, _ := s.Heartbeat(); !ok || !at.Equal(later) {
		t.Errorf("heartbeat %v %v", at, ok)
	}
}
