package pacing

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

const host = "mac-mini"

func mustLoad(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	return loc
}

func at(loc *time.Location, year int, month time.Month, day, hour, minute int) time.Time {
	return time.Date(year, month, day, hour, minute, 0, 0, loc)
}

var nightWindow = &config.Window{Start: 22 * 60, End: 7*60 + 30}

func mail(id, sender, subject string) EventSummary {
	return EventSummary{
		Source: store.SourceMail, Title: sender, Body: subject,
		URL: "pico://host-event/" + host + "/" + id, Key: "mail:personal:" + id, EventID: id,
	}
}

func github(id, repo, reason, subject string) EventSummary {
	return EventSummary{
		Source: store.SourceGitHub, Title: repo, Body: reason + ": " + subject,
		URL: "pico://host-event/" + host + "/" + id, Key: "github:" + id, EventID: id,
	}
}

func TestLoneEventAfterQuietSpellSendsNow(t *testing.T) {
	loc := time.UTC
	now := at(loc, 2026, 10, 19, 9, 0)
	prior := State{LastPushAt: now.Add(-10 * time.Minute), Day: "2026-10-19", PushesToday: 3}
	d, s := Decide(prior, now, nil, loc, "B1")
	if d.Kind != SendNow {
		t.Fatalf("kind %v, want SendNow", d.Kind)
	}
	if !s.LastPushAt.Equal(now) || s.PushesToday != 4 || s.OpenBatchID != "" {
		t.Errorf("state %+v", s)
	}
	p := d.Placement(mail("01A", "Alice Chen", "Lunch?"))
	if p.Batch != nil || p.Notice == nil {
		t.Fatalf("placement %+v", p)
	}
	want := store.Notice{Key: "mail:personal:01A", EventID: "01A", Title: "Alice Chen", Body: "Lunch?", URL: "pico://host-event/mac-mini/01A"}
	if *p.Notice != want {
		t.Errorf("notice %+v, want %+v", *p.Notice, want)
	}
}

func TestFirstEventEverSendsNow(t *testing.T) {
	d, s := Decide(State{}, at(time.UTC, 2026, 10, 19, 9, 0), nil, time.UTC, "B1")
	if d.Kind != SendNow || s.PushesToday != 1 || s.Day != "2026-10-19" {
		t.Errorf("decision %+v state %+v", d, s)
	}
}

func TestSecondEventWithinHoldJoinsBatch(t *testing.T) {
	loc := time.UTC
	first := at(loc, 2026, 10, 19, 9, 0)
	_, s := Decide(State{}, first, nil, loc, "unused")
	d, s := Decide(s, first.Add(30*time.Second), nil, loc, "B1")
	if d.Kind != JoinBatch || d.BatchID != "B1" || !d.FlushAt.Equal(first.Add(Hold)) {
		t.Fatalf("decision %+v", d)
	}
	if s.OpenBatchID != "B1" || !s.BatchFlushAt.Equal(first.Add(Hold)) || s.PushesToday != 1 {
		t.Errorf("state %+v", s)
	}
	p := d.Placement(mail("01B", "Bob Li", "Hi"))
	if p.Notice != nil || p.Batch == nil || *p.Batch != (store.BatchJoin{ID: "B1", FlushAt: first.Add(Hold)}) {
		t.Errorf("placement %+v", p)
	}

	d, s = Decide(s, first.Add(90*time.Second), nil, loc, "B2")
	if d.Kind != JoinBatch || d.BatchID != "B1" || !d.FlushAt.Equal(first.Add(Hold)) {
		t.Errorf("third event %+v, want to join B1", d)
	}
	if s.OpenBatchID != "B1" {
		t.Errorf("open batch %q", s.OpenBatchID)
	}
}

func TestBatchOfOneClosesAsSingleNotice(t *testing.T) {
	loc := time.UTC
	first := at(loc, 2026, 10, 19, 9, 0)
	_, s := Decide(State{}, first, nil, loc, "unused")
	_, s = Decide(s, first.Add(time.Minute), nil, loc, "B1")
	closeAt := first.Add(Hold)
	e := mail("01B", "Bob Li", "Invoice")
	n, s, err := Close(s, "B1", []EventSummary{e}, closeAt, loc, host)
	if err != nil {
		t.Fatal(err)
	}
	want := store.Notice{Key: e.Key, EventID: "01B", BatchID: "B1", Title: "Bob Li", Body: "Invoice", URL: e.URL}
	if n != want {
		t.Errorf("notice %+v, want %+v", n, want)
	}
	if s.OpenBatchID != "" || !s.LastPushAt.Equal(closeAt) || s.PushesToday != 2 {
		t.Errorf("state %+v", s)
	}
	d, _ := Decide(s, closeAt.Add(time.Minute), nil, loc, "B2")
	if d.Kind != JoinBatch || !d.FlushAt.Equal(closeAt.Add(Hold)) {
		t.Errorf("close did not open the next hold: %+v", d)
	}
}

func TestLargerBatchClosesAsBatchNotice(t *testing.T) {
	loc := time.UTC
	now := at(loc, 2026, 10, 19, 9, 2)
	s := State{OpenBatchID: "B1", BatchFlushAt: now, LastPushAt: now.Add(-Hold), Day: "2026-10-19", PushesToday: 1}
	events := []EventSummary{mail("01B", "Bob Li", "a"), github("01C", "owner/repo", "mention", "Fix")}
	n, _, err := Close(s, "B1", events, now, loc, host)
	if err != nil {
		t.Fatal(err)
	}
	want := store.Notice{Key: "batch:B1", BatchID: "B1", Title: "2 new: 1 mail, 1 GitHub", Body: "Bob Li, owner/repo", URL: "pico://host-event/mac-mini/batch/B1"}
	if n != want {
		t.Errorf("notice %+v, want %+v", n, want)
	}
}

func TestCloseRejectsEmptyBatch(t *testing.T) {
	_, _, err := Close(State{OpenBatchID: "B1"}, "B1", nil, at(time.UTC, 2026, 10, 19, 9, 0), time.UTC, host)
	if err == nil {
		t.Fatal("closing an empty batch must fail")
	}
}

func TestQuietHoursHoldUntilWindowEnd(t *testing.T) {
	loc := mustLoad(t, "Europe/Berlin")
	evening := at(loc, 2026, 10, 19, 23, 15)
	d, s := Decide(State{LastPushAt: evening.Add(-time.Hour)}, evening, nightWindow, loc, "B1")
	morning := at(loc, 2026, 10, 20, 7, 30)
	if d.Kind != JoinBatch || !d.FlushAt.Equal(morning) {
		t.Fatalf("decision %+v, want JoinBatch flushing at %v", d, morning)
	}
	d, s = Decide(s, at(loc, 2026, 10, 20, 3, 0), nightWindow, loc, "B2")
	if d.Kind != JoinBatch || d.BatchID != "B1" || !d.FlushAt.Equal(morning) {
		t.Errorf("after midnight %+v", d)
	}
	n, s, err := Close(s, "B1", []EventSummary{mail("01A", "Alice Chen", "x"), mail("01B", "Bob Li", "y")}, morning, loc, host)
	if err != nil {
		t.Fatal(err)
	}
	if n.Key != "batch:B1" || s.Day != "2026-10-20" || s.PushesToday != 1 {
		t.Errorf("notice %+v state %+v", n, s)
	}
}

func TestHoldThatRunsIntoQuietHoursExtendsToWindowEnd(t *testing.T) {
	loc := time.UTC
	lastPush := at(loc, 2026, 10, 19, 21, 59)
	_, s := Decide(State{LastPushAt: lastPush.Add(-time.Hour)}, lastPush, nightWindow, loc, "unused")
	d, s := Decide(s, lastPush.Add(30*time.Second), nightWindow, loc, "B1")
	if d.Kind != JoinBatch || !d.FlushAt.Equal(lastPush.Add(Hold)) {
		t.Fatalf("before the window %+v", d)
	}
	d, _ = Decide(s, at(loc, 2026, 10, 19, 22, 0), nightWindow, loc, "B2")
	if d.BatchID != "B1" || !d.FlushAt.Equal(at(loc, 2026, 10, 20, 7, 30)) {
		t.Errorf("inside the window %+v, want B1 flushing at 07:30", d)
	}
}

func TestHoldLongerThanWindowEndKeepsTheLaterTime(t *testing.T) {
	loc := time.UTC
	window := &config.Window{Start: 8 * 60, End: 9 * 60}
	lastPush := at(loc, 2026, 10, 19, 8, 59)
	d, _ := Decide(State{LastPushAt: lastPush, Day: "2026-10-19", PushesToday: 1}, lastPush.Add(10*time.Second), window, loc, "B1")
	if !d.FlushAt.Equal(lastPush.Add(Hold)) {
		t.Errorf("flush %v, want the hold end %v", d.FlushAt, lastPush.Add(Hold))
	}
}

func TestQuietHoursWrapAndDST(t *testing.T) {
	berlin := mustLoad(t, "Europe/Berlin")
	shanghai := mustLoad(t, "Asia/Shanghai")
	earlyWindow := &config.Window{Start: 60, End: 2*60 + 30}
	dayWindow := &config.Window{Start: 9 * 60, End: 17 * 60}
	cases := []struct {
		name    string
		loc     *time.Location
		window  *config.Window
		now     time.Time
		inside  bool
		nextEnd time.Time
	}{
		// 2026-03-29: Berlin springs forward 02:00 -> 03:00, so the night is one hour shorter.
		{"berlin spring night before", berlin, nightWindow, at(berlin, 2026, 3, 28, 23, 0), true, at(berlin, 2026, 3, 29, 7, 30)},
		{"berlin spring inside after jump", berlin, nightWindow, at(berlin, 2026, 3, 29, 3, 30), true, at(berlin, 2026, 3, 29, 7, 30)},
		{"berlin spring after end", berlin, nightWindow, at(berlin, 2026, 3, 29, 7, 30), false, at(berlin, 2026, 3, 30, 7, 30)},
		{"berlin spring end in missing hour", berlin, earlyWindow, at(berlin, 2026, 3, 29, 1, 30), true, time.Date(2026, 3, 29, 1, 30, 0, 0, time.UTC)},
		// 2026-10-25: Berlin falls back 03:00 -> 02:00, so the night is one hour longer.
		{"berlin autumn night before", berlin, nightWindow, at(berlin, 2026, 10, 24, 22, 0), true, at(berlin, 2026, 10, 25, 7, 30)},
		{"berlin autumn day after", berlin, nightWindow, at(berlin, 2026, 10, 25, 12, 0), false, at(berlin, 2026, 10, 26, 7, 30)},
		{"berlin no wrap before start", berlin, dayWindow, at(berlin, 2026, 10, 25, 8, 59), false, at(berlin, 2026, 10, 25, 17, 0)},
		{"berlin no wrap inside", berlin, dayWindow, at(berlin, 2026, 10, 25, 9, 0), true, at(berlin, 2026, 10, 25, 17, 0)},
		{"shanghai wrap evening", shanghai, nightWindow, at(shanghai, 2026, 3, 28, 22, 0), true, at(shanghai, 2026, 3, 29, 7, 30)},
		{"shanghai wrap morning", shanghai, nightWindow, at(shanghai, 2026, 10, 25, 7, 29), true, at(shanghai, 2026, 10, 25, 7, 30)},
		{"shanghai outside", shanghai, nightWindow, at(shanghai, 2026, 10, 25, 21, 59), false, at(shanghai, 2026, 10, 26, 7, 30)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := InQuietHours(c.now, *c.window, c.loc); got != c.inside {
				t.Errorf("inside = %v, want %v", got, c.inside)
			}
			if got := NextWindowEnd(c.now, *c.window, c.loc); !got.Equal(c.nextEnd) {
				t.Errorf("next end = %v, want %v", got.In(c.loc), c.nextEnd.In(c.loc))
			}
		})
	}

	springNight := at(berlin, 2026, 3, 29, 7, 30).Sub(at(berlin, 2026, 3, 28, 22, 0))
	autumnNight := at(berlin, 2026, 10, 25, 7, 30).Sub(at(berlin, 2026, 10, 24, 22, 0))
	if springNight != 8*time.Hour+30*time.Minute || autumnNight != 10*time.Hour+30*time.Minute {
		t.Errorf("spring night %v, autumn night %v", springNight, autumnNight)
	}

	d, _ := Decide(State{}, at(berlin, 2026, 10, 25, 2, 30), nightWindow, berlin, "B1")
	if d.Kind != JoinBatch || !d.FlushAt.Equal(at(berlin, 2026, 10, 25, 7, 30)) {
		t.Errorf("autumn decide %+v", d)
	}
}

func cappedDay(t *testing.T, loc *time.Location) (State, time.Time) {
	t.Helper()
	now := at(loc, 2026, 10, 19, 8, 0)
	s := State{}
	for i := range DailyCap {
		var d Decision
		d, s = Decide(s, now, nil, loc, fmt.Sprintf("B%d", i))
		if d.Kind != SendNow {
			t.Fatalf("push %d: %v", i+1, d.Kind)
		}
		now = now.Add(Hold)
	}
	return s, now
}

func TestDailyCap(t *testing.T) {
	loc := mustLoad(t, "Europe/Berlin")
	s, now := cappedDay(t, loc)
	if s.PushesToday != DailyCap {
		t.Fatalf("pushes %d", s.PushesToday)
	}
	d, s := Decide(s, now, nil, loc, "B31")
	if d.Kind != SendCapNotice || d.Day != "2026-10-19" {
		t.Fatalf("31st %+v, want SendCapNotice", d)
	}
	p := d.Placement(mail("01Z", "Alice Chen", "x"))
	if p.Batch != nil || p.Notice == nil || p.Notice.Key != "cap:2026-10-19" || p.Notice.EventID != "" {
		t.Errorf("cap placement %+v", p)
	}
	if !s.CapNoticeSent || s.PushesToday != DailyCap {
		t.Errorf("state %+v", s)
	}
	for i := range 3 {
		d, s = Decide(s, now.Add(time.Duration(i+1)*time.Hour), nil, loc, "B")
		if d.Kind != StoreCapped {
			t.Errorf("event after cap notice: %v, want StoreCapped", d.Kind)
		}
		if p := d.Placement(mail("x", "y", "z")); p.Notice != nil || p.Batch != nil {
			t.Errorf("capped placement %+v", p)
		}
	}
}

func TestCapReachedByClosingBatch(t *testing.T) {
	loc := time.UTC
	now := at(loc, 2026, 10, 19, 12, 0)
	s := State{LastPushAt: now, Day: "2026-10-19", PushesToday: DailyCap - 1}
	d, s := Decide(s, now.Add(time.Minute), nil, loc, "B1")
	if d.Kind != JoinBatch {
		t.Fatalf("29 pushes then hold: %v", d.Kind)
	}
	_, s, err := Close(s, "B1", []EventSummary{mail("01A", "a", "b"), mail("01B", "c", "d")}, now.Add(Hold), loc, host)
	if err != nil {
		t.Fatal(err)
	}
	if s.PushesToday != DailyCap {
		t.Fatalf("pushes %d", s.PushesToday)
	}
	if d, _ := Decide(s, now.Add(time.Hour), nil, loc, "B2"); d.Kind != SendCapNotice {
		t.Errorf("after the batch filled the cap: %v", d.Kind)
	}
}

func TestDayRolloverResetsCap(t *testing.T) {
	loc := mustLoad(t, "Asia/Shanghai")
	s, now := cappedDay(t, loc)
	_, s = Decide(s, now, nil, loc, "B")
	if !s.CapNoticeSent {
		t.Fatal("cap notice not recorded")
	}
	if d, _ := Decide(s, at(loc, 2026, 10, 19, 23, 59), nil, loc, "B"); d.Kind != StoreCapped {
		t.Errorf("before local midnight %v", d.Kind)
	}
	d, s := Decide(s, at(loc, 2026, 10, 20, 0, 0), nil, loc, "B")
	if d.Kind != SendNow || s.Day != "2026-10-20" || s.PushesToday != 1 || s.CapNoticeSent {
		t.Errorf("after local midnight %+v state %+v", d, s)
	}
}

func TestDayIsLocalNotUTC(t *testing.T) {
	loc := mustLoad(t, "Asia/Shanghai")
	// 16:30 UTC on the 19th is 00:30 on the 20th in Shanghai.
	_, s := Decide(State{}, time.Date(2026, 10, 19, 16, 30, 0, 0, time.UTC), nil, loc, "B")
	if s.Day != "2026-10-20" {
		t.Errorf("day %q", s.Day)
	}
}

func TestBatchTextListsDistinctTitlesInArrivalOrder(t *testing.T) {
	events := []EventSummary{
		mail("1", "Alice Chen", "a"),
		github("2", "owner/repo", "mention", "b"),
		mail("3", "Bob Li", "c"),
		mail("4", "Alice Chen", "d"),
		github("5", "owner/repo", "review_requested", "e"),
		github("6", "other/thing", "assign", "f"),
	}
	n := BatchNotice("B9", events, host)
	if n.Title != "6 new: 3 mail, 3 GitHub" {
		t.Errorf("title %q", n.Title)
	}
	if n.Body != "Alice Chen, owner/repo, Bob Li, other/thing" {
		t.Errorf("body %q", n.Body)
	}

	mailOnly := BatchNotice("B1", []EventSummary{mail("1", "A", "x"), mail("2", "B", "y"), mail("3", "C", "z")}, host)
	if mailOnly.Title != "3 new: 3 mail" {
		t.Errorf("mail-only title %q", mailOnly.Title)
	}
	githubOnly := BatchNotice("B2", []EventSummary{github("1", "o/r", "mention", "x"), github("2", "o/r", "assign", "y")}, host)
	if githubOnly.Title != "2 new: 2 GitHub" || githubOnly.Body != "o/r" {
		t.Errorf("github-only %+v", githubOnly)
	}
}

func TestTruncatesAt120RunesWithCJK(t *testing.T) {
	subject := strings.Repeat("合同第三版", 30)
	n := SingleNotice(mail("1", strings.Repeat("陈", 130), subject))
	for _, text := range []string{n.Title, n.Body} {
		if utf8.RuneCountInString(text) != NoticeTextLimit || !strings.HasSuffix(text, "…") || !utf8.ValidString(text) {
			t.Errorf("%d runes, valid %v: %q", utf8.RuneCountInString(text), utf8.ValidString(text), text)
		}
	}
	if want := string([]rune(subject)[:NoticeTextLimit-1]) + "…"; n.Body != want {
		t.Errorf("body %q, want %q", n.Body, want)
	}

	exact := strings.Repeat("字", NoticeTextLimit)
	if got := SingleNotice(mail("1", exact, "x")).Title; got != exact {
		t.Errorf("text of exactly the limit was cut: %q", got)
	}

	var many []EventSummary
	for i := range 40 {
		many = append(many, mail(fmt.Sprint(i), fmt.Sprintf("发件人%02d", i), "x"))
	}
	if body := BatchNotice("B", many, host).Body; utf8.RuneCountInString(body) != NoticeTextLimit {
		t.Errorf("batch body %d runes", utf8.RuneCountInString(body))
	}
}

func TestStateRoundTrip(t *testing.T) {
	loc := mustLoad(t, "Europe/Berlin")
	s := State{
		LastPushAt:    at(loc, 2026, 10, 19, 9, 0).Add(123 * time.Millisecond),
		OpenBatchID:   "01JBATCH",
		BatchFlushAt:  at(loc, 2026, 10, 20, 7, 30),
		PushesToday:   17,
		Day:           "2026-10-19",
		CapNoticeSent: true,
	}
	got, err := Decode(s.Encode())
	if err != nil {
		t.Fatal(err)
	}
	if !got.LastPushAt.Equal(s.LastPushAt) || !got.BatchFlushAt.Equal(s.BatchFlushAt) ||
		got.OpenBatchID != s.OpenBatchID || got.PushesToday != s.PushesToday || got.Day != s.Day ||
		got.CapNoticeSent != s.CapNoticeSent {
		t.Errorf("round trip %+v, want %+v", got, s)
	}
	if !json.Valid([]byte(s.Encode())) {
		t.Error("encoded state is not JSON")
	}

	zero, err := Decode("")
	if err != nil || zero != (State{}) {
		t.Errorf("empty decodes to %+v, %v", zero, err)
	}
	if _, err := Decode("{not json"); err == nil {
		t.Error("corrupt state must fail to decode")
	}
}

func summaries(events []store.Event) []EventSummary {
	out := make([]EventSummary, 0, len(events))
	for _, e := range events {
		out = append(out, SummaryOf(e))
	}
	return out
}

func TestOpenBatchSurvivesRestart(t *testing.T) {
	loc := mustLoad(t, "Europe/Berlin")
	path := filepath.Join(t.TempDir(), "state.db")
	st, err := store.Open(path, false)
	if err != nil {
		t.Fatal(err)
	}

	record := func(s State, e store.Event, now time.Time, batchID string) State {
		t.Helper()
		d, next := Decide(s, now, nightWindow, loc, batchID)
		encoded := next.Encode()
		if _, err := st.RecordEvent(store.EventRecord{Event: e, Placement: d.Placement(SummaryOf(e)), Pacing: &encoded}, now); err != nil {
			t.Fatal(err)
		}
		return next
	}
	mailEvent := func(id, sender, subject string, created time.Time) store.Event {
		return store.Event{
			ID: id, Key: "mail:personal:" + id, Source: store.SourceMail, CreatedAt: created,
			Title: sender, Summary: subject, URL: "pico://host-event/" + host + "/" + id,
			Body: json.RawMessage(`{}`), Decision: "push", Reason: "allowed",
		}
	}

	first := at(loc, 2026, 10, 19, 21, 0)
	s := record(State{}, mailEvent("01A", "Alice Chen", "Dinner", first), first, "unused")
	late := at(loc, 2026, 10, 19, 23, 10)
	s = record(s, mailEvent("01B", "Bob Li", "合同", late), late, "01BATCH")
	if s.OpenBatchID != "01BATCH" {
		t.Fatalf("state %+v", s)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = store.Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	raw, ok, err := st.Pacing()
	if err != nil || !ok {
		t.Fatalf("pacing %q %v %v", raw, ok, err)
	}
	restored, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	morning := at(loc, 2026, 10, 20, 7, 30)
	if restored.OpenBatchID != "01BATCH" || !restored.BatchFlushAt.Equal(morning) {
		t.Fatalf("restored %+v", restored)
	}
	if due, err := st.DueBatches(morning.Add(-time.Second)); err != nil || len(due) != 0 {
		t.Fatalf("due before the window ends: %v %v", due, err)
	}
	due, err := st.DueBatches(morning)
	if err != nil || len(due) != 1 || due[0].ID != "01BATCH" {
		t.Fatalf("due %+v %v", due, err)
	}

	notice, after, err := Close(restored, due[0].ID, summaries(due[0].Events), morning, loc, host)
	if err != nil {
		t.Fatal(err)
	}
	want := store.Notice{Key: "mail:personal:01B", EventID: "01B", BatchID: "01BATCH", Title: "Bob Li", Body: "合同", URL: "pico://host-event/mac-mini/01B"}
	if notice != want {
		t.Errorf("notice %+v, want %+v", notice, want)
	}
	encoded := after.Encode()
	if err := st.CloseBatch(due[0].ID, notice, &encoded, morning); err != nil {
		t.Fatal(err)
	}
	pending, err := st.PendingNotices(morning, 10)
	if err != nil || len(pending) != 2 || pending[1].Key != want.Key {
		t.Fatalf("pending %+v %v", pending, err)
	}
	if after.OpenBatchID != "" || after.Day != "2026-10-20" || after.PushesToday != 1 {
		t.Errorf("after close %+v", after)
	}
}
