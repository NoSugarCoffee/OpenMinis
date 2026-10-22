package daemon

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

var t0 = time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)

const (
	testHost      = "mac-mini"
	realTimeLimit = 10 * time.Second
	// The heartbeat, pruner, batch closer and outbox each wait on the clock between rounds.
	backgroundLoops = 4
)

type fakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeTimer
}

type fakeTimer struct {
	clock *fakeClock
	at    time.Time
	ch    chan time.Time
}

func newFakeClock(now time.Time) *fakeClock { return &fakeClock{now: now} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) NewTimer(d time.Duration) Timer {
	c.mu.Lock()
	defer c.mu.Unlock()
	t := &fakeTimer{clock: c, at: c.now.Add(d), ch: make(chan time.Time, 1)}
	if d <= 0 {
		t.ch <- c.now
		return t
	}
	c.timers = append(c.timers, t)
	return t
}

func (t *fakeTimer) C() <-chan time.Time { return t.ch }

func (t *fakeTimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	i := slices.Index(t.clock.timers, t)
	if i < 0 {
		return false
	}
	t.clock.timers = slices.Delete(t.clock.timers, i, i+1)
	return true
}

func (c *fakeClock) waiting() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.timers)
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
	kept := c.timers[:0]
	for _, t := range c.timers {
		if t.at.After(c.now) {
			kept = append(kept, t)
			continue
		}
		t.ch <- c.now
	}
	c.timers = kept
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(realTimeLimit)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(200 * time.Microsecond)
	}
}

// settle waits until every loop has finished its round and waits on the clock again.
func settle(t *testing.T, c *fakeClock, loops int) {
	t.Helper()
	eventually(t, fmt.Sprintf("%d loops waiting on the clock", loops), func() bool { return c.waiting() == loops })
}

// advance moves the clock in steps so that every loop gets each of its rounds.
func advance(t *testing.T, c *fakeClock, loops int, total, step time.Duration) {
	t.Helper()
	for moved := time.Duration(0); moved < total; moved += step {
		settle(t, c, loops)
		c.advance(min(step, total-moved))
	}
	settle(t, c, loops)
}

type pollResponse struct {
	result github.PollResult
	err    error
}

type fakeGitHub struct {
	mu        sync.Mutex
	responses []pollResponse
	cursors   []string
}

func (f *fakeGitHub) Poll(ctx context.Context, ifModifiedSince string) (github.PollResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cursors = append(f.cursors, ifModifiedSince)
	if len(f.responses) == 0 {
		return github.PollResult{Status: http.StatusNotModified, NotModified: true, PollInterval: "60"}, nil
	}
	next := f.responses[0]
	f.responses = f.responses[1:]
	return next.result, next.err
}

func (f *fakeGitHub) polls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.cursors)
}

func ok(candidates ...candidate.GitHub) pollResponse {
	return pollResponse{result: github.PollResult{
		Candidates: candidates, LastModified: "Mon, 19 Oct 2026 09:00:00 GMT", PollInterval: "60", Status: http.StatusOK,
	}}
}

func notification(thread, reason string) candidate.GitHub {
	return candidate.GitHub{
		Key: "gh:" + thread + ":2026-10-19T08:59:00Z", ThreadID: thread, Repo: "owner/repo", Reason: reason,
		SubjectType: "PullRequest", SubjectTitle: "Fix " + thread, HTMLURL: "https://github.com/owner/repo/pull/" + thread,
		UpdatedAt: t0.Add(-time.Minute),
	}
}

type recordingNotifier struct {
	mu     sync.Mutex
	sent   []notify.Notice
	result func(notify.Notice) error
}

func (n *recordingNotifier) Send(ctx context.Context, notice notify.Notice) error {
	n.mu.Lock()
	n.sent = append(n.sent, notice)
	result := n.result
	n.mu.Unlock()
	if result == nil {
		return nil
	}
	return result(notice)
}

func (n *recordingNotifier) notices() []notify.Notice {
	n.mu.Lock()
	defer n.mu.Unlock()
	return slices.Clone(n.sent)
}

type fakeMail struct {
	account string
	run     func(ctx context.Context, sink MailSink) error
}

func (f *fakeMail) AccountName() string { return f.account }

func (f *fakeMail) Run(ctx context.Context, sink MailSink) error { return f.run(ctx, sink) }

func allowedMail(uid uint32, messageID string, now time.Time) candidate.Mail {
	return candidate.Mail{
		Key: fmt.Sprintf("mail:personal:1:%d", uid), Account: "personal", UIDValidity: 1, UID: uid, MessageID: messageID,
		From:    []candidate.Address{{Name: "Alice Chen", Address: "alice@example.com"}},
		To:      []candidate.Address{{Address: "me@gmail.com"}},
		Subject: fmt.Sprintf("Hello %d", uid), Date: now, InternalDate: now, Text: "Hi",
	}
}

func testConfig(withGitHub bool) config.Config {
	cfg := config.Config{
		HostName: testHost,
		Timezone: time.UTC,
		Mail: []config.MailAccount{{
			Name: "personal", Address: "me@gmail.com", AppPassword: "x",
			Allow: []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: false}},
		}},
		Bark: &config.Bark{Server: "https://bark.invalid", DeviceKey: "device", EncryptionKey: "unused"},
	}
	if withGitHub {
		cfg.GitHub = &config.GitHubSource{Token: "x", Reasons: config.DefaultGitHubReasons}
	}
	return cfg
}

func openStore(t *testing.T, path string) *store.Store {
	t.Helper()
	st, err := store.Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

func tempStorePath(t *testing.T) string { return filepath.Join(t.TempDir(), "state.db") }

var idCounter atomic.Int64

func sequentialIDs() func() string {
	return func() string { return fmt.Sprintf("01TEST%020d", idCounter.Add(1)) }
}

type harness struct {
	clock    *fakeClock
	store    *store.Store
	path     string
	github   *fakeGitHub
	notifier *recordingNotifier
	deps     Deps
}

func newHarness(t *testing.T, withGitHub bool) *harness {
	t.Helper()
	path := tempStorePath(t)
	h := &harness{
		clock: newFakeClock(t0), path: path, store: openStore(t, path),
		github: &fakeGitHub{}, notifier: &recordingNotifier{},
	}
	h.deps = Deps{
		Config: testConfig(withGitHub), Store: h.store, Notifier: h.notifier, Clock: h.clock,
		NewID: sequentialIDs(), Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), ShutdownGrace: 2 * time.Second,
	}
	if withGitHub {
		h.deps.GitHub = h.github
	}
	return h
}

type running struct {
	cancel context.CancelFunc
	done   chan error
}

func start(t *testing.T, deps Deps) *running {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	r := &running{cancel: cancel, done: make(chan error, 1)}
	go func() { r.done <- Run(ctx, deps) }()
	t.Cleanup(func() {
		cancel()
		<-r.done
	})
	return r
}

func (r *running) stop(t *testing.T) error {
	t.Helper()
	r.cancel()
	select {
	case err := <-r.done:
		r.done <- err
		return err
	case <-time.After(realTimeLimit):
		t.Fatal("Run did not return after cancel")
		return nil
	}
}

type outboxRow struct {
	State    string
	Attempts int
	Error    string
}

func outbox(t *testing.T, path string) map[string]outboxRow {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT notice_key, state, attempts, last_error FROM outbox`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]outboxRow{}
	for rows.Next() {
		var key string
		var row outboxRow
		if err := rows.Scan(&key, &row.State, &row.Attempts, &row.Error); err != nil {
			t.Fatal(err)
		}
		got[key] = row
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return got
}
