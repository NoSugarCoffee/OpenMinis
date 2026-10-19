package imap

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

type stamp struct {
	ok     bool
	detail string
}

type recorded struct {
	mail   candidate.Mail
	cursor string
}

// fakeSink stands in for the daemon's store. Dropping duplicate Message-IDs is the daemon's job,
// so it keeps every record.
type fakeSink struct {
	mu      sync.Mutex
	cursor  string
	found   bool
	records []recorded
	stamps  []stamp
}

func (s *fakeSink) Cursor() (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cursor, s.found, nil
}

func (s *fakeSink) SetCursor(value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cursor, s.found = value, true
	return nil
}

func (s *fakeSink) Record(m candidate.Mail, cursor string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records = append(s.records, recorded{mail: m, cursor: cursor})
	s.cursor, s.found = cursor, true
	return nil
}

func (s *fakeSink) Stamp(ok bool, detail string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stamps = append(s.stamps, stamp{ok: ok, detail: detail})
	return nil
}

func (s *fakeSink) state() (cursor string, records []recorded, stamps []stamp) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cursor, slices.Clone(s.records), slices.Clone(s.stamps)
}

func (s *fakeSink) okStamps() int {
	_, _, stamps := s.state()
	count := 0
	for _, st := range stamps {
		if st.ok {
			count++
		}
	}
	return count
}

func (s *fakeSink) storedCursor(t *testing.T) Cursor {
	t.Helper()
	value, _, _ := s.state()
	c, err := DecodeCursor(value)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func eventually(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func testAccount() config.MailAccount {
	return config.MailAccount{
		Name: "personal", Address: testAddress, AppPassword: testPassword,
		Allow: []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: true}},
	}
}

// quietTiming leaves only EXISTS and reconnects to wake the source, unless a test shortens it.
func quietTiming() Timing {
	return Timing{IdleReissue: time.Hour, ReconcileEvery: time.Hour, BackoffFirst: 5 * time.Second, BackoffMax: 5 * time.Minute}
}

type sleeps struct {
	mu     sync.Mutex
	got    []time.Duration
	before func(n int)
}

func (s *sleeps) sleep(ctx context.Context, d time.Duration) bool {
	s.mu.Lock()
	s.got = append(s.got, d)
	n := len(s.got)
	before := s.before
	s.mu.Unlock()
	if before != nil {
		before(n)
	}
	return ctx.Err() == nil
}

func (s *sleeps) durations() []time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.got)
}

type running struct {
	cancel context.CancelFunc
	done   chan struct{}
	err    error
}

func start(t *testing.T, src *Source, sink *fakeSink) *running {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	r := &running{cancel: cancel, done: make(chan struct{})}
	go func() {
		r.err = src.Run(ctx, sink)
		close(r.done)
	}()
	t.Cleanup(func() { r.stop(t) })
	return r
}

func (r *running) stop(t *testing.T) {
	t.Helper()
	r.cancel()
	select {
	case <-r.done:
		if r.err != nil {
			t.Errorf("Run after cancel: %v", r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}

func newSource(t *testing.T, server *testServer, timing Timing, sl *sleeps) *Source {
	t.Helper()
	src, err := New(testAccount(), server.dial, timing, sl.sleep)
	if err != nil {
		t.Fatal(err)
	}
	return src
}

func TestFirstRunBaselinesAndEmitsNothing(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<old1@example.com>", "Old 1"))
	server.deliver(t, textMessage("<old2@example.com>", "Old 2"))
	sink := &fakeSink{}
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)

	eventually(t, "the baseline stamp", func() bool { return sink.okStamps() == 1 })
	if got := sink.storedCursor(t); got != (Cursor{UIDValidity: server.uidValidity(t), LastSeenUID: 2}) {
		t.Errorf("baseline %+v", got)
	}
	if _, records, _ := sink.state(); len(records) != 0 {
		t.Errorf("first run emitted %d messages", len(records))
	}
	server.assertUntouched(t)
}

func TestSameUIDValidityResumesWithMailReceivedOffline(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<seen@example.com>", "Seen"))
	sink := &fakeSink{}
	first := start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	first.stop(t)

	uidA := server.deliver(t, textMessage("<a@example.com>", "Offline A"))
	uidB := server.deliver(t, textMessage("<b@example.com>", "Offline B"))
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "two records", func() bool { _, records, _ := sink.state(); return len(records) == 2 })

	_, records, _ := sink.state()
	validity := server.uidValidity(t)
	for i, uid := range []uint32{uidA, uidB} {
		m := records[i].mail
		if m.UID != uid || m.Key != EventKey("personal", validity, uid) || m.Account != "personal" {
			t.Errorf("record %d: %s uid %d", i, m.Key, m.UID)
		}
		if records[i].cursor != (Cursor{UIDValidity: validity, LastSeenUID: uid}).Encode() {
			t.Errorf("record %d advances the cursor to %s", i, records[i].cursor)
		}
	}
	if records[0].mail.Subject != "Offline A" || records[0].mail.Text != "Hello from Offline A\r\n" ||
		records[0].mail.InternalDate.IsZero() || records[0].mail.Truncated {
		t.Errorf("first record %+v", records[0].mail)
	}
	eventually(t, "a stamp after the reconcile", func() bool { return sink.okStamps() == 2 })
	server.assertUntouched(t)
}

func TestChangedUIDValidityRebaselinesAndStampsReset(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<x@example.com>", "Before"))
	sink := &fakeSink{cursor: Cursor{UIDValidity: server.uidValidity(t), LastSeenUID: 1}.Encode(), found: true}
	server.recreateInbox(t)
	server.deliver(t, textMessage("<y@example.com>", "After 1"))
	server.deliver(t, textMessage("<z@example.com>", "After 2"))

	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the reset stamp", func() bool { _, _, stamps := sink.state(); return len(stamps) == 1 })
	_, records, stamps := sink.state()
	if stamps[0].ok || !strings.HasPrefix(stamps[0].detail, "source_reset:") {
		t.Errorf("stamp %+v", stamps[0])
	}
	if len(records) != 0 {
		t.Errorf("a reset emitted %d messages", len(records))
	}
	if got := sink.storedCursor(t); got != (Cursor{UIDValidity: server.uidValidity(t), LastSeenUID: 2}) {
		t.Errorf("new baseline %+v", got)
	}

	server.deliver(t, textMessage("<new@example.com>", "New"))
	eventually(t, "the new mail", func() bool { _, records, _ := sink.state(); return len(records) == 1 })
	eventually(t, "the healthy stamp", func() bool { return sink.okStamps() == 1 })
}

func TestIdleExistsTriggersAnImmediateFetch(t *testing.T) {
	server := newTestServer(t)
	sink := &fakeSink{}
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the source to idle", func() bool { _, idles, _ := server.guard.snapshot(); return idles == 1 })

	uid := server.deliver(t, textMessage("<live@example.com>", "Live"))
	eventually(t, "the live mail", func() bool { _, records, _ := sink.state(); return len(records) == 1 })
	if _, records, _ := sink.state(); records[0].mail.UID != uid || records[0].mail.Subject != "Live" {
		t.Errorf("record %+v", records[0].mail)
	}
	eventually(t, "the source to idle again", func() bool { _, idles, _ := server.guard.snapshot(); return idles == 2 })
	server.assertUntouched(t)
}

func TestFetchUsesPeekAndNeverStores(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<old@example.com>", "Old"))
	sink := &fakeSink{}
	r := start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	server.deliver(t, textMessage("<new@example.com>", "New"))
	server.deliver(t, bigMessage(2<<20))
	eventually(t, "two records", func() bool { _, records, _ := sink.state(); return len(records) == 2 })
	server.listener.dropAll()
	eventually(t, "the reconnect", func() bool { return sink.okStamps() >= 3 })
	r.stop(t)

	server.assertUntouched(t)
	client, err := server.dial(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.Login(testAddress, testPassword).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Select(mailbox, &goimap.SelectOptions{ReadOnly: true}).Wait(); err != nil {
		t.Fatal(err)
	}
	messages, err := client.Fetch(goimap.SeqSetNum(1, 2, 3), &goimap.FetchOptions{Flags: true}).Collect()
	if err != nil {
		t.Fatal(err)
	}
	for _, msg := range messages {
		if len(msg.Flags) != 0 {
			t.Errorf("message %d has flags %v", msg.SeqNum, msg.Flags)
		}
	}
}

// The guard has to catch the commands it fences, or TestFetchUsesPeekAndNeverStores proves nothing.
func TestGuardCatchesEveryMutation(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<m@example.com>", "M"))
	client, err := server.dial(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.Login(testAddress, testPassword).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Select(mailbox, nil).Wait(); err != nil {
		t.Fatal(err)
	}
	all := goimap.SeqSetNum(1)
	_, _ = client.Fetch(all, &goimap.FetchOptions{BodySection: []*goimap.FetchItemBodySection{{}}}).Collect()
	_, _ = client.Store(all, &goimap.StoreFlags{Op: goimap.StoreFlagsAdd, Flags: []goimap.Flag{goimap.FlagSeen}}, nil).Collect()
	_, _ = client.Copy(all, "Archive").Wait()
	_, _ = client.Move(all, "Archive").Wait()
	_, _ = client.Expunge().Collect()
	violations, _, _ := server.guard.snapshot()
	want := []string{"SELECT INBOX without read-only (EXAMINE)", "FETCH BODY[] without PEEK", "STORE", "COPY", "MOVE", "EXPUNGE"}
	if !slices.Equal(violations, want) {
		t.Errorf("violations %q, want %q", violations, want)
	}
}

func TestDroppedConnectionReconnectsWithBackoffAndReconciles(t *testing.T) {
	server := newTestServer(t)
	var (
		mu       sync.Mutex
		failNext int
	)
	dial := func(options *imapclient.Options) (*imapclient.Client, error) {
		mu.Lock()
		defer mu.Unlock()
		if failNext > 0 {
			failNext--
			return nil, errors.New("network is unreachable")
		}
		return server.dial(options)
	}
	sl := &sleeps{}
	var offlineUID uint32
	sl.before = func(n int) {
		if n == 1 {
			offlineUID = server.deliver(t, textMessage("<offline@example.com>", "Offline"))
		}
	}
	src, err := New(testAccount(), dial, quietTiming(), sl.sleep)
	if err != nil {
		t.Fatal(err)
	}
	sink := &fakeSink{}
	start(t, src, sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	eventually(t, "the source to idle", func() bool { _, idles, _ := server.guard.snapshot(); return idles == 1 })

	mu.Lock()
	failNext = 2
	mu.Unlock()
	server.listener.dropAll()
	eventually(t, "the offline mail", func() bool { _, records, _ := sink.state(); return len(records) == 1 })
	if got := sl.durations(); !slices.Equal(got, []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second}) {
		t.Errorf("backoff %v", got)
	}
	if _, records, _ := sink.state(); records[0].mail.UID != offlineUID {
		t.Errorf("record uid %d, want %d", records[0].mail.UID, offlineUID)
	}
	_, _, stamps := sink.state()
	failures := 0
	for _, st := range stamps {
		if !st.ok {
			failures++
			if !strings.Contains(st.detail, "lost the connection to Gmail") {
				t.Errorf("failure stamp %q", st.detail)
			}
		}
	}
	if failures != 3 {
		t.Errorf("%d failure stamps, want one per wait", failures)
	}
	eventually(t, "a healthy stamp after the reconnect", func() bool { return sink.okStamps() == 2 })

	eventually(t, "the source to idle again", func() bool { _, idles, _ := server.guard.snapshot(); return idles >= 2 })
	server.listener.dropAll()
	eventually(t, "the second reconnect", func() bool { return len(sl.durations()) == 4 })
	if got := sl.durations()[3]; got != 5*time.Second {
		t.Errorf("backoff after a good connection starts at %v", got)
	}
	server.assertUntouched(t)
}

func TestRejectedLoginIsReturned(t *testing.T) {
	server := newTestServer(t)
	account := testAccount()
	account.AppPassword = "wrong"
	sl := &sleeps{}
	src, err := New(account, server.dial, quietTiming(), sl.sleep)
	if err != nil {
		t.Fatal(err)
	}
	err = src.Run(context.Background(), &fakeSink{})
	if !errors.Is(err, ErrLoginRejected) || !strings.Contains(err.Error(), testAddress) {
		t.Errorf("Run = %v", err)
	}
	if got := sl.durations(); len(got) != 0 {
		t.Errorf("waited %v before giving up", got)
	}
}

func TestTwoMiBMessageIsTruncated(t *testing.T) {
	server := newTestServer(t)
	sink := &fakeSink{}
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	server.deliver(t, bigMessage(2<<20))
	eventually(t, "the big mail", func() bool { _, records, _ := sink.state(); return len(records) == 1 })
	_, records, _ := sink.state()
	m := records[0].mail
	if !m.Truncated || m.Subject != "Big" || !strings.HasPrefix(m.Text, "line 0\r\nline 1\r\n") || len(m.Text) > TextCap {
		t.Errorf("truncated %v subject %q text %d bytes", m.Truncated, m.Subject, len(m.Text))
	}
}

func TestDuplicateMessageIDsAreLeftToTheDaemon(t *testing.T) {
	server := newTestServer(t)
	sink := &fakeSink{}
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	server.deliver(t, textMessage("<same@example.com>", "First"))
	server.deliver(t, textMessage("<same@example.com>", "Moved back"))
	eventually(t, "both copies", func() bool { _, records, _ := sink.state(); return len(records) == 2 })
	_, records, _ := sink.state()
	if records[0].mail.MessageID != "<same@example.com>" || records[1].mail.MessageID != "<same@example.com>" ||
		records[0].mail.Key == records[1].mail.Key {
		t.Errorf("records %s %s", records[0].mail.Key, records[1].mail.Key)
	}
}

func TestUnreadableMessageIsRecordedOnce(t *testing.T) {
	server := newTestServer(t)
	sink := &fakeSink{}
	start(t, newSource(t, server, quietTiming(), &sleeps{}), sink)
	eventually(t, "the baseline", func() bool { return sink.okStamps() == 1 })
	broken := server.deliver(t, []byte("From: <<<broken\r\nSubject: Broken sender\r\n\r\nBody\r\n"))
	good := server.deliver(t, textMessage("<good@example.com>", "Good"))
	eventually(t, "both messages", func() bool { _, records, _ := sink.state(); return len(records) == 2 })
	_, records, _ := sink.state()
	if m := records[0].mail; m.UID != broken || len(m.From) != 0 || m.Subject != "Broken sender" ||
		!strings.Contains(m.Text, "could not read") {
		t.Errorf("unreadable record %+v", m)
	}
	if records[1].mail.UID != good {
		t.Errorf("second record uid %d", records[1].mail.UID)
	}

	server.listener.dropAll()
	eventually(t, "the reconnect", func() bool { return sink.okStamps() == 3 })
	if _, records, _ := sink.state(); len(records) != 2 {
		t.Errorf("%d records after reconnecting, want the same 2", len(records))
	}
}

func TestIdleIsReissuedAndReconcileRunsOnSchedule(t *testing.T) {
	server := newTestServer(t)
	sink := &fakeSink{}
	timing := quietTiming()
	timing.IdleReissue = 20 * time.Millisecond
	start(t, newSource(t, server, timing, &sleeps{}), sink)
	eventually(t, "three IDLE commands", func() bool { _, idles, _ := server.guard.snapshot(); return idles >= 3 })
	if _, _, searches := server.guard.snapshot(); searches != 0 {
		t.Errorf("re-issuing IDLE ran %d searches", searches)
	}

	server = newTestServer(t)
	sink = &fakeSink{}
	timing = quietTiming()
	timing.ReconcileEvery = 20 * time.Millisecond
	start(t, newSource(t, server, timing, &sleeps{}), sink)
	eventually(t, "three scheduled reconciles", func() bool { return sink.okStamps() >= 4 })
	if _, _, searches := server.guard.snapshot(); searches < 3 {
		t.Errorf("%d searches", searches)
	}
}

func TestPrimaryOnlyIsRefused(t *testing.T) {
	account := testAccount()
	account.GmailPrimaryOnly = true
	if _, err := New(account, DialGmail, ProductionTiming(), SleepContext); !errors.Is(err, ErrPrimaryOnlyUnsupported) ||
		!strings.Contains(err.Error(), "gmail_primary_only") {
		t.Errorf("New = %v", err)
	}
}
