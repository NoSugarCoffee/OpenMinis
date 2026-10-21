// Package imap watches one Gmail INBOX over IMAP. It only ever reads: the mailbox is opened with
// EXAMINE and bodies are fetched with BODY.PEEK[], so no flag changes and no message moves.
package imap

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/daemon"
)

const (
	GmailAddress = "imap.gmail.com:993"
	mailbox      = "INBOX"
	// fetchBatch bounds memory: each message in a batch can hold up to FetchCap bytes.
	fetchBatch = 10
)

// ErrLoginRejected means the server answered LOGIN with NO. Retrying at once would not help and
// could get the account locked, so Run returns it and the daemon retries after 30 minutes.
var ErrLoginRejected = errors.New("Gmail rejected the app password")

var ErrPrimaryOnlyUnsupported = errors.New(
	"gmail_primary_only = true is not supported yet (go-imap cannot send X-GM-RAW); remove it to watch the whole INBOX")

// Dialer opens a connection that has not logged in yet. options carries the handler that turns
// EXISTS into a fetch, so it must be passed on to imapclient.
type Dialer func(options *imapclient.Options) (*imapclient.Client, error)

func DialGmail(options *imapclient.Options) (*imapclient.Client, error) {
	return imapclient.DialTLS(GmailAddress, options)
}

type Timing struct {
	// IdleReissue ends and restarts IDLE well before RFC 2177's 29 minutes, since some servers
	// and NAT boxes drop quiet connections sooner.
	IdleReissue time.Duration
	// ReconcileEvery catches mail whose EXISTS was lost.
	ReconcileEvery time.Duration
	BackoffFirst   time.Duration
	BackoffMax     time.Duration
}

func ProductionTiming() Timing {
	return Timing{
		IdleReissue:    9 * time.Minute,
		ReconcileEvery: 15 * time.Minute,
		BackoffFirst:   5 * time.Second,
		BackoffMax:     5 * time.Minute,
	}
}

// Sleeper waits d, or reports false when ctx ends first.
type Sleeper func(ctx context.Context, d time.Duration) bool

func SleepContext(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

type Source struct {
	account config.MailAccount
	dial    Dialer
	timing  Timing
	sleep   Sleeper
}

var _ daemon.MailSource = (*Source)(nil)

func New(account config.MailAccount, dial Dialer, timing Timing, sleep Sleeper) (*Source, error) {
	if account.GmailPrimaryOnly {
		return nil, fmt.Errorf("mail account %q: %w", account.Name, ErrPrimaryOnlyUnsupported)
	}
	return &Source{account: account, dial: dial, timing: timing, sleep: sleep}, nil
}

func (s *Source) AccountName() string { return s.account.Name }

// fatalError ends Run instead of reconnecting: a rejected login, a store failure, or a mailbox
// state that reconnecting cannot change.
type fatalError struct{ err error }

func (e fatalError) Error() string { return e.err.Error() }

func (e fatalError) Unwrap() error { return e.err }

func fatal(err error) error {
	if err == nil {
		return nil
	}
	return fatalError{err: err}
}

func (s *Source) Run(ctx context.Context, sink daemon.MailSink) error {
	var backoff time.Duration
	for {
		err := s.watch(ctx, sink, func() { backoff = 0 })
		if ctx.Err() != nil {
			return nil
		}
		if fe := (fatalError{}); errors.As(err, &fe) {
			return fe.err
		}
		backoff = NextBackoff(backoff, s.timing)
		detail := fmt.Sprintf("lost the connection to Gmail (%v); reconnecting in %s", err, backoff)
		if stampErr := sink.Stamp(false, detail); stampErr != nil {
			return stampErr
		}
		if !s.sleep(ctx, backoff) {
			return nil
		}
	}
}

func NextBackoff(previous time.Duration, timing Timing) time.Duration {
	if previous == 0 {
		return timing.BackoffFirst
	}
	return min(previous*2, timing.BackoffMax)
}

// watch runs one connection: login, baseline or reconcile, then IDLE until something fails.
// connected is called once the first reconcile succeeded, which is when backoff starts over.
func (s *Source) watch(ctx context.Context, sink daemon.MailSink, connected func()) error {
	exists := make(chan struct{}, 1)
	options := &imapclient.Options{UnilateralDataHandler: &imapclient.UnilateralDataHandler{
		Mailbox: func(data *imapclient.UnilateralDataMailbox) {
			if data.NumMessages == nil {
				return
			}
			select {
			case exists <- struct{}{}:
			default:
			}
		},
	}}
	client, err := s.dial(options)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Close()
	// Closing the client is the only way to interrupt a blocked command when ctx ends.
	defer context.AfterFunc(ctx, func() { client.Close() })()

	if err := login(client, s.account); err != nil {
		return err
	}
	selected, err := client.Select(mailbox, &goimap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		if imapErr := (*goimap.Error)(nil); errors.As(err, &imapErr) {
			return fatal(fmt.Errorf("examine %s: %w", mailbox, err))
		}
		return fmt.Errorf("examine %s: %w", mailbox, err)
	}
	if selected.UIDNext == 0 || selected.UIDValidity == 0 {
		return fatal(fmt.Errorf("examine %s: the server reported no UIDNEXT or UIDVALIDITY", mailbox))
	}

	cursor, catchUp, err := s.start(sink, selected.UIDValidity, uint32(selected.UIDNext))
	if err != nil {
		return err
	}
	if catchUp {
		if cursor, err = s.reconcile(client, sink, cursor); err != nil {
			return err
		}
	}
	connected()
	lastReconcile := time.Now()
	for {
		woke, err := s.idle(ctx, client, exists, s.timing.ReconcileEvery-time.Since(lastReconcile))
		if err != nil || ctx.Err() != nil {
			return err
		}
		if woke == wokeReissue {
			continue
		}
		if cursor, err = s.reconcile(client, sink, cursor); err != nil {
			return err
		}
		lastReconcile = time.Now()
	}
}

func login(client *imapclient.Client, account config.MailAccount) error {
	if err := client.Login(account.Address, account.AppPassword).Wait(); err != nil {
		// RFC 5530 UNAVAILABLE is a server-side hiccup, not a verdict on the password.
		if imapErr := (*goimap.Error)(nil); errors.As(err, &imapErr) && imapErr.Type == goimap.StatusResponseTypeNo &&
			imapErr.Code != goimap.ResponseCodeUnavailable {
			return fatal(fmt.Errorf("%w for %s: %s", ErrLoginRejected, account.Address, imapErr.Text))
		}
		return fmt.Errorf("login: %w", err)
	}
	return nil
}

// start applies Plan to a fresh connection. catchUp reports that the stored cursor still holds
// and the mail received since must be fetched; otherwise a new baseline has been stored.
func (s *Source) start(sink daemon.MailSink, uidValidity, uidNext uint32) (cursor Cursor, catchUp bool, err error) {
	stored, found, err := sink.Cursor()
	if err != nil {
		return Cursor{}, false, fatal(err)
	}
	var previous *Cursor
	if found {
		decoded, err := DecodeCursor(stored)
		if err != nil {
			return Cursor{}, false, fatal(err)
		}
		previous = &decoded
	}
	fetchFrom, cursor, reset := Plan(previous, uidValidity, uidNext)
	if fetchFrom != 0 {
		return cursor, true, nil
	}
	if err := sink.SetCursor(cursor.Encode()); err != nil {
		return Cursor{}, false, fatal(err)
	}
	if reset {
		// status only shows a detail while a source is failing, so the reset is stamped as one
		// until the next reconcile succeeds.
		detail := fmt.Sprintf("%s: Gmail changed the UIDVALIDITY of %s from %d to %d; "+
			"mail that arrived while hostd was not watching was skipped", ResetDetailPrefix, mailbox, previous.UIDValidity, uidValidity)
		return cursor, false, fatal(sink.Stamp(false, detail))
	}
	return cursor, false, fatal(sink.Stamp(true, ""))
}

// ResetDetailPrefix starts the status detail recorded when UIDVALIDITY changed.
const ResetDetailPrefix = "source_reset"

type wake int

const (
	wokeExists wake = iota
	wokeReissue
	wokeReconcile
)

func (s *Source) idle(ctx context.Context, client *imapclient.Client, exists <-chan struct{}, untilReconcile time.Duration) (wake, error) {
	select {
	case <-exists:
		return wokeExists, nil
	default:
	}
	if untilReconcile <= 0 {
		return wokeReconcile, nil
	}
	command, err := client.Idle()
	if err != nil {
		return 0, fmt.Errorf("idle: %w", err)
	}
	reissue := time.NewTimer(s.timing.IdleReissue)
	defer reissue.Stop()
	reconcile := time.NewTimer(untilReconcile)
	defer reconcile.Stop()
	var woke wake
	select {
	case <-ctx.Done():
		return 0, nil
	case <-client.Closed():
		return 0, errors.New("the server closed the connection")
	case <-exists:
		woke = wokeExists
	case <-reissue.C:
		woke = wokeReissue
	case <-reconcile.C:
		woke = wokeReconcile
	}
	if err := command.Close(); err != nil {
		return 0, fmt.Errorf("end idle: %w", err)
	}
	if err := command.Wait(); err != nil {
		return 0, fmt.Errorf("end idle: %w", err)
	}
	return woke, nil
}

var bodySection = &goimap.FetchItemBodySection{Peek: true, Partial: &goimap.SectionPartial{Offset: 0, Size: FetchCap}}

// reconcile records every message after cursor, stamps the source healthy and returns the cursor
// it advanced to.
func (s *Source) reconcile(client *imapclient.Client, sink daemon.MailSink, cursor Cursor) (Cursor, error) {
	criteria := &goimap.SearchCriteria{UID: []goimap.UIDSet{{{Start: goimap.UID(cursor.LastSeenUID + 1), Stop: 0}}}}
	found, err := client.UIDSearch(criteria, nil).Wait()
	if err != nil {
		return cursor, fmt.Errorf("search: %w", err)
	}
	// UID n:* always matches the newest message, even when n is past it.
	uids := slices.DeleteFunc(found.AllUIDs(), func(uid goimap.UID) bool { return uint32(uid) <= cursor.LastSeenUID })
	slices.Sort(uids)
	for batch := range slices.Chunk(uids, fetchBatch) {
		options := &goimap.FetchOptions{UID: true, InternalDate: true, RFC822Size: true, BodySection: []*goimap.FetchItemBodySection{bodySection}}
		messages, err := client.Fetch(goimap.UIDSetNum(batch...), options).Collect()
		if err != nil {
			return cursor, fmt.Errorf("fetch: %w", err)
		}
		slices.SortFunc(messages, func(a, b *imapclient.FetchMessageBuffer) int { return cmp.Compare(a.UID, b.UID) })
		for _, msg := range messages {
			if uint32(msg.UID) <= cursor.LastSeenUID {
				continue
			}
			fetched := Fetched{
				Account: s.account.Name, UIDValidity: cursor.UIDValidity, UID: uint32(msg.UID),
				InternalDate: msg.InternalDate, Size: msg.RFC822Size, Raw: msg.FindBodySection(bodySection),
			}
			m, parseErr := Parse(fetched)
			if parseErr != nil {
				m = Unreadable(fetched, parseErr)
			}
			next := Cursor{UIDValidity: cursor.UIDValidity, LastSeenUID: fetched.UID}
			if err := sink.Record(m, next.Encode()); err != nil {
				return cursor, fatal(err)
			}
			cursor = next
		}
	}
	// A UID that vanished between SEARCH and FETCH is gone for good; move past it.
	if len(uids) > 0 && uint32(uids[len(uids)-1]) > cursor.LastSeenUID {
		cursor.LastSeenUID = uint32(uids[len(uids)-1])
		if err := sink.SetCursor(cursor.Encode()); err != nil {
			return cursor, fatal(err)
		}
	}
	return cursor, fatal(sink.Stamp(true, ""))
}
