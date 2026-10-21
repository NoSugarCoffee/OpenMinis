package daemon

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/gate"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/pacing"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

const githubLoops = backgroundLoops + 1

func listEvents(t *testing.T, st *store.Store) []store.Event {
	t.Helper()
	events, err := st.ListEvents(100, "")
	if err != nil {
		t.Fatal(err)
	}
	return events
}

func TestCrashBetweenCommitAndSendDoesNotPushTwice(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "mention"))}
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	h.notifier.result = func(notify.Notice) error {
		<-release // the request reached Bark, then the process died before recording it
		return nil
	}
	h.deps.ShutdownGrace = 50 * time.Millisecond
	first := start(t, h.deps)
	settle(t, h.clock, githubLoops)
	h.clock.advance(DrainInterval)
	eventually(t, "the first send", func() bool { return len(h.notifier.notices()) == 1 })
	if err := first.stop(t); err != nil {
		t.Fatalf("first Run = %v", err)
	}

	restarted := &recordingNotifier{}
	deps := h.deps
	deps.Store, deps.Notifier, deps.GitHub = openStore(t, h.path), restarted, &fakeGitHub{}
	deps.ShutdownGrace = 2 * time.Second
	second := start(t, deps)
	advance(t, h.clock, githubLoops, 2*time.Hour, time.Minute)
	if err := second.stop(t); err != nil {
		t.Fatalf("second Run = %v", err)
	}

	if total := len(h.notifier.notices()) + len(restarted.notices()); total != 1 {
		t.Errorf("notice pushed %d times, want exactly once", total)
	}
	row := outbox(t, h.path)[notification("1", "mention").Key]
	if row.State != string(store.NoticeUncertain) || row.Error != claimDetail {
		t.Errorf("outbox row = %+v, want uncertain with the claim detail", row)
	}
}

func TestBurstOfGitHubCandidatesYieldsOneImmediateThenOneBatchNotice(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(
		notification("1", "mention"), notification("2", "review_requested"),
		notification("3", "assign"), notification("4", "mention"),
	)}
	start(t, h.deps)
	advance(t, h.clock, githubLoops, DrainInterval, DrainInterval)
	if got := h.notifier.notices(); len(got) != 1 {
		t.Fatalf("%d notices right after the burst, want 1", len(got))
	}
	advance(t, h.clock, githubLoops, pacing.Hold+10*time.Second, time.Second)

	got := h.notifier.notices()
	if len(got) != 2 {
		t.Fatalf("%d notices, want one immediate and one batch: %+v", len(got), got)
	}
	events := listEvents(t, h.store)
	if len(events) != 4 {
		t.Fatalf("%d events", len(events))
	}
	first := events[len(events)-1]
	want := notify.Notice{Title: "owner/repo", Body: "Mentioned: Fix 1", URL: "pico://host-event/mac-mini/" + first.ID}
	if got[0] != want || first.URL != want.URL {
		t.Errorf("immediate notice %+v, event URL %q; want %+v", got[0], first.URL, want)
	}
	batchID := events[0].BatchID
	if batchID == "" {
		t.Fatal("later events joined no batch")
	}
	wantBatch := notify.Notice{Title: "3 new: 3 GitHub", Body: "owner/repo", URL: "pico://host-event/mac-mini/batch/" + batchID}
	if got[1] != wantBatch {
		t.Errorf("batch notice %+v, want %+v", got[1], wantBatch)
	}
	for _, e := range events {
		if e.Decision != string(gate.ActionPush) || e.Reason != gate.ReasonAllowed {
			t.Errorf("event %s decision %s/%s", e.Key, e.Decision, e.Reason)
		}
	}
}

func TestMaybeDeliveredIsMarkedUncertainAndNeverResent(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "mention"))}
	h.notifier.result = func(notify.Notice) error {
		return fmt.Errorf("bark: %w: read tcp: i/o timeout", notify.ErrMaybeDelivered)
	}
	start(t, h.deps)
	advance(t, h.clock, githubLoops, 2*time.Hour, time.Minute)

	if got := len(h.notifier.notices()); got != 1 {
		t.Errorf("sent %d times, want 1", got)
	}
	row := outbox(t, h.path)[notification("1", "mention").Key]
	if row.State != string(store.NoticeUncertain) || !strings.Contains(row.Error, "i/o timeout") {
		t.Errorf("outbox row = %+v", row)
	}
}

func TestHTTPErrorIsRetriedWithBackoffUntilOneHourThenFailed(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "mention"))}
	var attempts []time.Duration
	h.notifier.result = func(notify.Notice) error {
		attempts = append(attempts, h.clock.Now().Sub(t0))
		return errors.New("bark: HTTP 500: internal error")
	}
	start(t, h.deps)
	advance(t, h.clock, githubLoops, 90*time.Minute, 10*time.Second)

	// The first drain tick inside the first 10 s step lands at 10 s; doubling then runs from creation.
	want := []time.Duration{10, 20, 40, 80, 160, 320, 640, 1280, 2560, 3600}
	if len(attempts) != len(want) {
		t.Fatalf("attempts at %v, want seconds %v", attempts, want)
	}
	for i, seconds := range want {
		if attempts[i] != seconds*time.Second {
			t.Errorf("attempt %d at %v, want %ds", i, attempts[i], seconds)
		}
	}
	row := outbox(t, h.path)[notification("1", "mention").Key]
	if row.State != string(store.NoticeFailed) || !strings.Contains(row.Error, "HTTP 500") {
		t.Errorf("outbox row = %+v", row)
	}
}

func TestDeliveryOutcome(t *testing.T) {
	created := t0
	httpErr := errors.New("bark: HTTP 502")
	cases := []struct {
		name      string
		now       time.Time
		err       error
		wantState store.NoticeState
		wantNext  time.Time
	}{
		{"sent", created, nil, store.NoticeSent, created},
		{"maybe delivered", created, fmt.Errorf("x: %w", notify.ErrMaybeDelivered), store.NoticeUncertain, created},
		{"first failure waits 10s", created, httpErr, store.NoticePending, created.Add(10 * time.Second)},
		{"delay doubles with age", created.Add(5 * time.Minute), httpErr, store.NoticePending, created.Add(10 * time.Minute)},
		{"last attempt at the window's end", created.Add(40 * time.Minute), httpErr, store.NoticePending, created.Add(time.Hour)},
		{"failed after the window", created.Add(time.Hour), httpErr, store.NoticeFailed, created.Add(time.Hour)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := DeliveryOutcome(created, c.now, c.err)
			if got.State != c.wantState || !got.NextAttemptAt.Equal(c.wantNext) {
				t.Errorf("got %+v, want %s at %v", got, c.wantState, c.wantNext)
			}
		})
	}
}

func TestUnauthorizedGitHubStampsReasonAndRetriesAfter30MinutesWhileMailContinues(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{
		{result: github.PollResult{Status: http.StatusUnauthorized}, err: fmt.Errorf("%w: 401: Bad credentials", github.ErrUnauthorized)},
		ok(notification("1", "mention")),
	}
	h.deps.Mail = []MailSource{&fakeMail{account: "personal", run: func(ctx context.Context, sink MailSink) error {
		if err := sink.Stamp(true, ""); err != nil {
			return err
		}
		if err := sink.Record(allowedMail(10, "<a@example.com>", t0), "uid-10"); err != nil {
			return err
		}
		<-ctx.Done()
		return nil
	}}}
	start(t, h.deps)
	eventually(t, "the mail event", func() bool { return len(listEvents(t, h.store)) == 1 })
	advance(t, h.clock, githubLoops, DrainInterval, DrainInterval)
	if got := len(h.notifier.notices()); got != 1 {
		t.Fatalf("%d notices, want the mail notice", got)
	}

	statuses := sourceStatuses(t, h.store)
	gh := statuses[GitHubSourceName]
	if gh.OK || gh.Kind != GitHubSourceKind || !strings.Contains(gh.Detail, "Bad credentials") {
		t.Errorf("github status %+v", gh)
	}
	if mail := statuses["mail:personal"]; !mail.OK || mail.Kind != MailSourceKind {
		t.Errorf("mail status %+v", mail)
	}
	if got := h.notifier.notices()[0]; got.Title != "Alice Chen" || got.Body != "Hello 10" {
		t.Errorf("mail notice %+v", got)
	}
	if cursor, _, _ := h.store.Cursor("mail:personal"); cursor != "uid-10" {
		t.Errorf("mail cursor %q", cursor)
	}

	advance(t, h.clock, githubLoops, LoginFailureRetry-time.Minute-DrainInterval, time.Minute)
	if polls := len(h.github.polls()); polls != 1 {
		t.Fatalf("%d polls before 30 min passed", polls)
	}
	beat, _, _ := h.store.Heartbeat()
	if h.clock.Now().Sub(beat) > HeartbeatInterval {
		t.Errorf("heartbeat %v while github is down", beat)
	}
	advance(t, h.clock, githubLoops, time.Minute+DrainInterval, DrainInterval)
	if polls := len(h.github.polls()); polls != 2 {
		t.Fatalf("%d polls after 30 min, want 2", polls)
	}
	if gh := sourceStatuses(t, h.store)[GitHubSourceName]; !gh.OK || gh.Detail != "" {
		t.Errorf("github status after retry %+v", gh)
	}
	if got := len(h.notifier.notices()); got != 2 {
		t.Errorf("%d notices, want mail then GitHub", got)
	}
}

func sourceStatuses(t *testing.T, st *store.Store) map[string]store.SourceStatus {
	t.Helper()
	list, err := st.Sources()
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]store.SourceStatus{}
	for _, s := range list {
		byName[s.Name] = s
	}
	return byName
}

func TestNotModifiedKeepsTheCursor(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok()}
	start(t, h.deps)
	advance(t, h.clock, githubLoops, 2*time.Minute, time.Minute)

	want := []string{"", "Mon, 19 Oct 2026 09:00:00 GMT", "Mon, 19 Oct 2026 09:00:00 GMT"}
	if got := h.github.polls(); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("If-Modified-Since per poll %q, want %q", got, want)
	}
	if cursor, _, _ := h.store.Cursor(GitHubSourceName); cursor != want[1] {
		t.Errorf("cursor %q after 304", cursor)
	}
	if gh := sourceStatuses(t, h.store)[GitHubSourceName]; !gh.OK || !gh.UpdatedAt.Equal(t0.Add(2*time.Minute)) {
		t.Errorf("github status %+v", gh)
	}
}

func TestCursorAdvancesWithTheLastCandidate(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "mention"), notification("2", "mention"))}
	start(t, h.deps)
	settle(t, h.clock, githubLoops)
	if cursor, _, _ := h.store.Cursor(GitHubSourceName); cursor != "Mon, 19 Oct 2026 09:00:00 GMT" {
		t.Errorf("cursor %q", cursor)
	}
}

func TestHeartbeatIsStampedEveryMinute(t *testing.T) {
	h := newHarness(t, false)
	start(t, h.deps)
	settle(t, h.clock, backgroundLoops)
	if beat, found, _ := h.store.Heartbeat(); !found || !beat.Equal(t0) {
		t.Fatalf("heartbeat %v found %v", beat, found)
	}
	advance(t, h.clock, backgroundLoops, HeartbeatInterval, HeartbeatInterval)
	if beat, _, _ := h.store.Heartbeat(); !beat.Equal(t0.Add(HeartbeatInterval)) {
		t.Errorf("heartbeat %v after a minute", beat)
	}
}

func TestShutdownReturnsNil(t *testing.T) {
	h := newHarness(t, true)
	r := start(t, h.deps)
	settle(t, h.clock, githubLoops)
	if err := r.stop(t); err != nil {
		t.Errorf("Run = %v, want nil", err)
	}
}

func TestShutdownLetsAnInFlightSendFinish(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "mention"))}
	sending := make(chan struct{})
	finish := make(chan struct{})
	h.notifier.result = func(notify.Notice) error {
		close(sending)
		<-finish
		return nil
	}
	r := start(t, h.deps)
	settle(t, h.clock, githubLoops)
	h.clock.advance(DrainInterval)
	<-sending
	r.cancel()
	close(finish)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run = %v", err)
	}
	if row := outbox(t, h.path)[notification("1", "mention").Key]; row.State != string(store.NoticeSent) {
		t.Errorf("outbox row %+v, want sent", row)
	}
}

func TestStoreFailureStopsTheDaemonWithAnError(t *testing.T) {
	h := newHarness(t, false)
	if err := h.store.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), realTimeLimit)
	defer cancel()
	err := Run(ctx, h.deps)
	if err == nil || ctx.Err() != nil {
		t.Fatalf("Run = %v (ctx %v), want a store error", err, ctx.Err())
	}
}

func TestStoreOnlyAndDropEventsAreStoredWithReasonAndNoNotice(t *testing.T) {
	h := newHarness(t, true)
	h.github.responses = []pollResponse{ok(notification("1", "subscribed"))}
	automated := allowedMail(20, "<news@example.com>", t0)
	automated.From = []candidate.Address{{Name: "Shop", Address: "noreply@shop.example"}}
	stranger := allowedMail(21, "<s@example.net>", t0)
	stranger.From = []candidate.Address{{Name: "Stranger", Address: "s@example.net"}}
	duplicate := allowedMail(22, "<news@example.com>", t0)
	h.deps.Mail = []MailSource{&fakeMail{account: "personal", run: func(ctx context.Context, sink MailSink) error {
		for i, m := range []candidate.Mail{automated, stranger, duplicate} {
			if err := sink.Record(m, fmt.Sprint(i)); err != nil {
				return err
			}
		}
		<-ctx.Done()
		return nil
	}}}
	start(t, h.deps)
	eventually(t, "four events", func() bool { return len(listEvents(t, h.store)) == 4 })
	advance(t, h.clock, githubLoops, 5*time.Minute, time.Second)

	if got := h.notifier.notices(); len(got) != 0 {
		t.Errorf("notices %+v, want none", got)
	}
	want := map[string]string{
		notification("1", "subscribed").Key: "store_only/" + gate.ReasonReasonNotKept,
		automated.Key:                       "drop/" + gate.ReasonAutomated,
		stranger.Key:                        "store_only/" + gate.ReasonSenderNotAllowed,
		duplicate.Key:                       "drop/" + ReasonDuplicateMessageID,
	}
	for _, e := range listEvents(t, h.store) {
		if got := e.Decision + "/" + e.Reason; got != want[e.Key] {
			t.Errorf("event %s = %s, want %s", e.Key, got, want[e.Key])
		}
		if e.BatchID != "" {
			t.Errorf("event %s joined batch %s", e.Key, e.BatchID)
		}
		if e.URL != "pico://host-event/mac-mini/"+e.ID {
			t.Errorf("event %s URL %q", e.Key, e.URL)
		}
	}
	if rows := outbox(t, h.path); len(rows) != 0 {
		t.Errorf("outbox %+v, want empty", rows)
	}
}

func TestDailyCapSendsOneCapNoticeAndStoresTheRest(t *testing.T) {
	h := newHarness(t, true)
	capped := pacing.State{LastPushAt: t0.Add(-time.Hour), PushesToday: pacing.DailyCap, Day: "2026-10-19"}.Encode()
	if err := h.store.EnqueueNotice(store.Notice{Key: "seed", Title: "seed"}, &capped, t0); err != nil {
		t.Fatal(err)
	}
	h.github.responses = []pollResponse{ok(notification("1", "mention"), notification("2", "mention"))}
	start(t, h.deps)
	advance(t, h.clock, githubLoops, 5*time.Second, time.Second)

	got := h.notifier.notices()
	capNotices := 0
	for _, n := range got {
		if n.Title == "Daily cap reached" && n.URL == "" {
			capNotices++
		}
	}
	if len(got) != 2 || capNotices != 1 {
		t.Fatalf("notices %+v, want the seed and one cap notice", got)
	}
	for _, e := range listEvents(t, h.store) {
		if e.Decision != string(gate.ActionStoreOnly) || e.Reason != ReasonDailyCap {
			t.Errorf("event %s = %s/%s", e.Key, e.Decision, e.Reason)
		}
	}
}

func TestMailSourceThatGivesUpIsStampedAndRestartedAfter30Minutes(t *testing.T) {
	h := newHarness(t, false)
	runs := 0
	h.deps.Mail = []MailSource{&fakeMail{account: "personal", run: func(ctx context.Context, sink MailSink) error {
		runs++
		if runs == 1 {
			return errors.New("Gmail rejected the app password")
		}
		if err := sink.Stamp(true, ""); err != nil {
			return err
		}
		<-ctx.Done()
		return nil
	}}}
	start(t, h.deps)
	settle(t, h.clock, backgroundLoops+1)
	if st := sourceStatuses(t, h.store)["mail:personal"]; st.OK || st.Detail != "Gmail rejected the app password" {
		t.Errorf("status %+v", st)
	}
	advance(t, h.clock, backgroundLoops+1, LoginFailureRetry-time.Second, time.Minute)
	if runs != 1 {
		t.Fatalf("restarted after %d runs before 30 min", runs)
	}
	h.clock.advance(time.Second)
	settle(t, h.clock, backgroundLoops)
	eventually(t, "the restarted source's stamp", func() bool { return sourceStatuses(t, h.store)["mail:personal"].OK })
}

func TestRunRejectsInconsistentDeps(t *testing.T) {
	h := newHarness(t, true)
	h.deps.GitHub = nil
	if err := Run(context.Background(), h.deps); err == nil || !strings.Contains(err.Error(), "[github]") {
		t.Errorf("missing GitHub source: %v", err)
	}
	h = newHarness(t, false)
	h.deps.Mail = []MailSource{&fakeMail{account: "work"}}
	if err := Run(context.Background(), h.deps); err == nil || !strings.Contains(err.Error(), `"work"`) {
		t.Errorf("unknown mail account: %v", err)
	}
}

func TestULIDsSortByTime(t *testing.T) {
	clock := newFakeClock(t0)
	next := ULIDs(clock.Now)
	a := next()
	clock.advance(time.Millisecond)
	b := next()
	if len(a) != 26 || a >= b {
		t.Errorf("ids %q then %q", a, b)
	}
}
