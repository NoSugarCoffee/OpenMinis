// Package daemon runs `minis-hostd run`: one goroutine per source, a batch closer, an outbox
// drainer, a heartbeat and a daily pruner, all sharing one store whose writes are serialised.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/gate"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/pacing"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

const (
	BatchCloseInterval = 5 * time.Second
	DrainInterval      = 1 * time.Second
	HeartbeatInterval  = 60 * time.Second
	PruneInterval      = 24 * time.Hour
	LoginFailureRetry  = 30 * time.Minute
	FirstSendRetry     = 10 * time.Second
	SendRetryWindow    = 1 * time.Hour

	drainBatchSize = 20
	sendTimeout    = 30 * time.Second
)

// Names under which sources stamp their status; `status --json` shows them as is.
const (
	GitHubSourceName = "github"
	GitHubSourceKind = "github"
	MailSourceKind   = "imap"
)

// Reasons the daemon adds on top of the gate's.
const (
	ReasonDailyCap           = "daily_cap"
	ReasonDuplicateMessageID = "duplicate_message_id"
)

// claimDetail is what a notice shows if hostd dies while sending it: the claim marks it uncertain
// before the request goes out, so a restart never sends it again.
const claimDetail = "hostd stopped while sending; the notice may have been delivered"

func MailSourceName(account string) string { return "mail:" + account }

type GitHubPoller interface {
	Poll(ctx context.Context, ifModifiedSince string) (github.PollResult, error)
}

type Deps struct {
	Config   config.Config
	Store    *store.Store
	Notifier notify.Notifier
	Clock    Clock
	NewID    func() string
	GitHub   GitHubPoller // nil exactly when Config.GitHub is nil
	Mail     []MailSource // one per Config.Mail account that should run
	Logger   *slog.Logger
	// ShutdownGrace bounds how long Run waits for an in-flight send after ctx ends.
	ShutdownGrace time.Duration
}

// ULIDs returns the production id generator. Ids sort by time, which `events list` relies on.
func ULIDs(now func() time.Time) func() string {
	return func() string { return ulid.MustNew(ulid.Timestamp(now()), ulid.DefaultEntropy()).String() }
}

type daemon struct {
	cfg      config.Config
	store    *store.Store
	notifier notify.Notifier
	clock    Clock
	newID    func() string
	github   GitHubPoller
	log      *slog.Logger
	// writeMu serialises store writes and keeps each pacing read-modify-write atomic with them.
	writeMu sync.Mutex
}

// Run returns nil after ctx ends, or the first store failure: a locked or corrupt database
// cannot be worked around, so the service manager should restart the process.
func Run(ctx context.Context, deps Deps) error {
	if err := validate(deps); err != nil {
		return err
	}
	d := &daemon{
		cfg: deps.Config, store: deps.Store, notifier: deps.Notifier, clock: deps.Clock,
		newID: deps.NewID, github: deps.GitHub, log: deps.Logger,
	}
	accounts := map[string]config.MailAccount{}
	for _, account := range deps.Config.Mail {
		accounts[account.Name] = account
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		wg        sync.WaitGroup
		fatalOnce sync.Once
		fatal     error
	)
	start := func(name string, loop func(context.Context) error) {
		wg.Go(func() {
			if err := loop(runCtx); err != nil {
				fatalOnce.Do(func() { fatal = fmt.Errorf("daemon: %s: %w", name, err) })
				cancel()
			}
		})
	}
	start("heartbeat", d.runHeartbeat)
	start("pruner", d.runPruner)
	start("batch closer", d.runBatchCloser)
	start("outbox", d.runOutbox)
	if d.github != nil {
		start("github", d.runGitHub)
	}
	for _, src := range deps.Mail {
		account := accounts[src.AccountName()]
		start(MailSourceName(account.Name), func(ctx context.Context) error { return d.runMail(ctx, src, account) })
	}
	d.log.Info("daemon started", "host", d.cfg.HostName, "github", d.github != nil, "mail", len(deps.Mail))

	<-runCtx.Done()
	stopped := make(chan struct{})
	go func() {
		wg.Wait()
		close(stopped)
	}()
	grace := time.NewTimer(deps.ShutdownGrace)
	defer grace.Stop()
	select {
	case <-stopped:
	case <-grace.C:
		d.log.Warn("shutdown grace ended with work still running", "grace", deps.ShutdownGrace)
	}
	// Seals fatal against loops that outlived the grace, so reading it below cannot race.
	fatalOnce.Do(func() {})
	if fatal != nil {
		d.log.Error("daemon stopped", "error", fatal)
		return fatal
	}
	d.log.Info("daemon stopped")
	return nil
}

func validate(deps Deps) error {
	switch {
	case deps.Store == nil:
		return errors.New("daemon: no store")
	case deps.Notifier == nil:
		return errors.New("daemon: no notifier")
	case deps.Clock == nil:
		return errors.New("daemon: no clock")
	case deps.NewID == nil:
		return errors.New("daemon: no id generator")
	case deps.Logger == nil:
		return errors.New("daemon: no logger")
	case deps.ShutdownGrace <= 0:
		return fmt.Errorf("daemon: shutdown grace %v must be positive", deps.ShutdownGrace)
	case deps.Config.Timezone == nil:
		return errors.New("daemon: config has no timezone")
	case deps.GitHub != nil && deps.Config.GitHub == nil:
		return errors.New("daemon: a GitHub source was given but the config has no [github] section")
	case deps.GitHub == nil && deps.Config.GitHub != nil:
		return errors.New("daemon: the config has a [github] section but no GitHub source was given")
	}
	seen := map[string]bool{}
	for _, src := range deps.Mail {
		name := src.AccountName()
		if seen[name] {
			return fmt.Errorf("daemon: two mail sources for account %q", name)
		}
		seen[name] = true
		found := false
		for _, account := range deps.Config.Mail {
			found = found || account.Name == name
		}
		if !found {
			return fmt.Errorf("daemon: mail source for account %q has no [[mail]] entry in the config", name)
		}
	}
	return nil
}

func (d *daemon) locked(fn func() error) error {
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	return fn()
}

func (d *daemon) runHeartbeat(ctx context.Context) error {
	return every(ctx, d.clock, HeartbeatInterval, func(now time.Time) error {
		return d.locked(func() error { return d.store.Beat(now) })
	})
}

func (d *daemon) runPruner(ctx context.Context) error {
	return every(ctx, d.clock, PruneInterval, func(now time.Time) error {
		return d.locked(func() error { return d.store.Prune(now) })
	})
}

func (d *daemon) stamp(name, kind string, pollErr error, now time.Time) error {
	detail := ""
	if pollErr != nil {
		detail = pollErr.Error()
	}
	return d.locked(func() error { return d.store.StampSource(name, kind, pollErr == nil, detail, now) })
}

func eventURL(host, eventID string) string { return "pico://host-event/" + host + "/" + eventID }

// candidateEvent is one candidate ready for the store; decide runs under the write lock with the
// same now the event is stored with.
type candidateEvent struct {
	key       string
	source    store.Source
	title     string
	summary   string
	body      json.RawMessage
	cursor    *store.CursorUpdate
	messageID *store.MessageIDEntry
	decide    func(now time.Time) (gate.Decision, error)
}

func (d *daemon) recordEvent(c candidateEvent) error {
	return d.locked(func() error {
		now := d.clock.Now()
		decision, err := c.decide(now)
		if err != nil {
			return err
		}
		id := d.newID()
		event := store.Event{
			ID: id, Key: c.key, Source: c.source, CreatedAt: now, Title: c.title, Summary: c.summary,
			URL: eventURL(d.cfg.HostName, id), Body: c.body, Decision: string(decision.Action), Reason: decision.Reason,
		}
		record := store.EventRecord{Cursor: c.cursor, MessageID: c.messageID}
		var placed pacing.Kind
		if decision.Action == gate.ActionPush {
			record.Placement, record.Pacing, placed, err = d.place(event, now)
			if err != nil {
				return err
			}
			if placed == pacing.StoreCapped || placed == pacing.SendCapNotice {
				event.Decision, event.Reason = string(gate.ActionStoreOnly), ReasonDailyCap
			}
		}
		record.Event = event
		inserted, err := d.store.RecordEvent(record, now)
		if err != nil {
			return err
		}
		if inserted {
			d.log.Info("event recorded", "id", id, "key", c.key, "decision", event.Decision, "reason", event.Reason, "pacing", placed)
		}
		return nil
	})
}

func (d *daemon) place(event store.Event, now time.Time) (store.Placement, *string, pacing.Kind, error) {
	state, err := d.pacingState()
	if err != nil {
		return store.Placement{}, nil, 0, err
	}
	decision, next := pacing.Decide(state, now, d.cfg.QuietHours, d.cfg.Timezone, d.newID())
	summary := pacing.EventSummary{
		Source: event.Source, Title: event.Title, Body: event.Summary, URL: event.URL, Key: event.Key, EventID: event.ID,
	}
	encoded := next.Encode()
	return decision.Placement(summary), &encoded, decision.Kind, nil
}

func (d *daemon) pacingState() (pacing.State, error) {
	raw, _, err := d.store.Pacing()
	if err != nil {
		return pacing.State{}, err
	}
	return pacing.Decode(raw)
}

func (d *daemon) runBatchCloser(ctx context.Context) error {
	return every(ctx, d.clock, BatchCloseInterval, func(now time.Time) error {
		return d.locked(func() error { return d.closeDueBatches(now) })
	})
}

func (d *daemon) closeDueBatches(now time.Time) error {
	batches, err := d.store.DueBatches(now)
	if err != nil {
		return err
	}
	for _, batch := range batches {
		state, err := d.pacingState()
		if err != nil {
			return err
		}
		summaries := make([]pacing.EventSummary, 0, len(batch.Events))
		for _, e := range batch.Events {
			summaries = append(summaries, pacing.SummaryOf(e))
		}
		notice, next, err := pacing.Close(state, batch.ID, summaries, now, d.cfg.Timezone, d.cfg.HostName)
		if err != nil {
			return err
		}
		encoded := next.Encode()
		if err := d.store.CloseBatch(batch.ID, notice, &encoded, now); err != nil {
			return err
		}
		d.log.Info("batch closed", "batch", batch.ID, "events", len(batch.Events), "notice", notice.Key)
	}
	return nil
}
