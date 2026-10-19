package daemon

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/eventbody"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/gate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

func (d *daemon) runGitHub(ctx context.Context) error {
	for {
		cursor, _, err := d.store.Cursor(GitHubSourceName)
		if err != nil {
			return err
		}
		result, pollErr := d.github.Poll(ctx, cursor)
		if ctx.Err() != nil {
			return nil
		}
		now := d.clock.Now()
		if pollErr == nil {
			if err := d.recordGitHubPoll(result); err != nil {
				return err
			}
		}
		if err := d.stamp(GitHubSourceName, GitHubSourceKind, pollErr, now); err != nil {
			return err
		}
		next := github.NextPoll(now, result.PollInterval, result.Status, result.RateRemaining, result.RateReset)
		if errors.Is(pollErr, github.ErrUnauthorized) {
			next = now.Add(LoginFailureRetry)
		}
		if pollErr != nil {
			d.log.Warn("github poll failed", "error", pollErr, "status", result.Status, "next", next)
		}
		if !sleep(ctx, d.clock, next.Sub(now)) {
			return nil
		}
	}
}

// recordGitHubPoll advances the cursor with the last candidate, so a crash part-way refetches the
// rest and the event keys make the repeats no-ops.
func (d *daemon) recordGitHubPoll(result github.PollResult) error {
	if result.NotModified {
		return nil
	}
	var cursor *store.CursorUpdate
	if result.LastModified != "" {
		cursor = &store.CursorUpdate{Source: GitHubSourceName, Value: result.LastModified}
	}
	if len(result.Candidates) == 0 {
		if cursor == nil {
			return nil
		}
		return d.locked(func() error { return d.store.SetCursor(*cursor) })
	}
	for i, n := range result.Candidates {
		var advance *store.CursorUpdate
		if i == len(result.Candidates)-1 {
			advance = cursor
		}
		err := d.recordEvent(candidateEvent{
			key:     n.Key,
			source:  store.SourceGitHub,
			title:   eventbody.GitHubTitle(n),
			summary: eventbody.GitHubSummary(n),
			body:    eventbody.FromGitHub(n).JSON(),
			cursor:  advance,
			decide: func(now time.Time) (gate.Decision, error) {
				return gate.GitHub(n, *d.cfg.GitHub, now), nil
			},
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// MailSink is what a mail source (Task 7) writes through. Every method reaches the store, and a
// failure there also stops the daemon, so the source should return as soon as one fails.
type MailSink interface {
	// Cursor returns the opaque cursor stored under MailSourceName(account).
	Cursor() (value string, found bool, err error)
	// SetCursor moves the cursor without an event: a baseline or a sweep that found nothing.
	SetCursor(value string) error
	// Record gates one message and stores it together with the cursor it advances to.
	Record(m candidate.Mail, cursor string) error
	// Stamp records the source's last success, or its current failure with a reason for `status`.
	Stamp(ok bool, detail string) error
}

// MailSource watches one account. Run reconnects on its own after a dropped connection; it
// returns nil when ctx ends and an error only when it gives up, such as a rejected app password,
// after which the daemon stamps that error and starts it again after LoginFailureRetry.
type MailSource interface {
	AccountName() string
	Run(ctx context.Context, sink MailSink) error
}

func (d *daemon) runMail(ctx context.Context, src MailSource, account config.MailAccount) error {
	name := MailSourceName(account.Name)
	for {
		sink := &mailSink{d: d, account: account, name: name}
		runErr := src.Run(ctx, sink)
		if err := sink.failure(); err != nil {
			return err
		}
		if ctx.Err() != nil {
			return nil
		}
		if runErr == nil {
			runErr = errors.New("mail source stopped without an error")
		}
		now := d.clock.Now()
		if err := d.stamp(name, MailSourceKind, runErr, now); err != nil {
			return err
		}
		d.log.Warn("mail source stopped", "account", account.Name, "error", runErr, "retry", LoginFailureRetry)
		if !sleep(ctx, d.clock, LoginFailureRetry) {
			return nil
		}
	}
}

type mailSink struct {
	d       *daemon
	account config.MailAccount
	name    string
	mu      sync.Mutex
	failed  error
}

func (s *mailSink) fail(err error) error {
	if err != nil {
		s.mu.Lock()
		if s.failed == nil {
			s.failed = err
		}
		s.mu.Unlock()
	}
	return err
}

func (s *mailSink) failure() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.failed
}

func (s *mailSink) Cursor() (string, bool, error) {
	value, found, err := s.d.store.Cursor(s.name)
	return value, found, s.fail(err)
}

func (s *mailSink) SetCursor(value string) error {
	return s.fail(s.d.locked(func() error {
		return s.d.store.SetCursor(store.CursorUpdate{Source: s.name, Value: value})
	}))
}

func (s *mailSink) Stamp(ok bool, detail string) error {
	now := s.d.clock.Now()
	return s.fail(s.d.locked(func() error {
		return s.d.store.StampSource(s.name, MailSourceKind, ok, detail, now)
	}))
}

func (s *mailSink) Record(m candidate.Mail, cursor string) error {
	var messageID *store.MessageIDEntry
	if m.MessageID != "" {
		messageID = &store.MessageIDEntry{Account: s.account.Name, MessageID: m.MessageID}
	}
	return s.fail(s.d.recordEvent(candidateEvent{
		key:       m.Key,
		source:    store.SourceMail,
		title:     eventbody.MailTitle(m),
		summary:   eventbody.MailSummary(m),
		body:      eventbody.FromMail(m).JSON(),
		cursor:    &store.CursorUpdate{Source: s.name, Value: cursor},
		messageID: messageID,
		decide: func(now time.Time) (gate.Decision, error) {
			if messageID != nil {
				seen, err := s.d.store.SeenMessageID(messageID.Account, messageID.MessageID)
				if err != nil {
					return gate.Decision{}, err
				}
				if seen {
					return gate.Decision{Action: gate.ActionDrop, Reason: ReasonDuplicateMessageID}, nil
				}
			}
			return gate.Mail(m, s.account.Allow, now), nil
		},
	}))
}
