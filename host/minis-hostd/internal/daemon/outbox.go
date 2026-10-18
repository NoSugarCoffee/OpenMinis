package daemon

import (
	"context"
	"errors"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

// runOutbox waits before its first round so that round never races the sources' start-up writes:
// a notice goes out at the first tick after it was enqueued, which keeps retry timing exact.
func (d *daemon) runOutbox(ctx context.Context) error {
	for sleep(ctx, d.clock, DrainInterval) {
		if err := d.drain(ctx, d.clock.Now()); err != nil {
			return err
		}
	}
	return nil
}

// drain sends due notices one by one. Each is claimed as uncertain before it is sent, so a crash
// mid-send leaves it uncertain rather than pending: at most once beats at least once (spec §5.4).
func (d *daemon) drain(ctx context.Context, now time.Time) error {
	notices, err := d.store.PendingNotices(now, drainBatchSize)
	if err != nil {
		return err
	}
	for _, n := range notices {
		if ctx.Err() != nil {
			return nil
		}
		claim := store.NoticeOutcome{State: store.NoticeUncertain, Error: claimDetail, NextAttemptAt: now}
		if err := d.locked(func() error { return d.store.MarkNotice(n.Key, claim) }); err != nil {
			return err
		}
		// The send outlives ctx so a shutdown lets a request on the wire finish and be recorded.
		sendCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sendTimeout)
		sendErr := d.notifier.Send(sendCtx, notify.Notice{Title: n.Title, Body: n.Body, URL: n.URL})
		cancel()
		outcome := DeliveryOutcome(n.CreatedAt, d.clock.Now(), sendErr)
		if err := d.locked(func() error { return d.store.MarkNotice(n.Key, outcome) }); err != nil {
			return err
		}
		d.log.Info("notice sent", "key", n.Key, "state", outcome.State, "error", outcome.Error)
	}
	return nil
}

// DeliveryOutcome applies the retry rule: a definite failure is retried with doubling delays
// (10 s, 20 s, 40 s, …, measured from creation) until SendRetryWindow after the notice was
// created, the last attempt landing exactly at the window's end; a send that may have been
// delivered is never retried.
func DeliveryOutcome(createdAt, now time.Time, sendErr error) store.NoticeOutcome {
	switch {
	case sendErr == nil:
		return store.NoticeOutcome{State: store.NoticeSent, NextAttemptAt: now}
	case errors.Is(sendErr, notify.ErrMaybeDelivered):
		return store.NoticeOutcome{State: store.NoticeUncertain, Error: sendErr.Error(), NextAttemptAt: now}
	}
	deadline := createdAt.Add(SendRetryWindow)
	if !now.Before(deadline) {
		return store.NoticeOutcome{State: store.NoticeFailed, Error: sendErr.Error(), NextAttemptAt: now}
	}
	delay := max(FirstSendRetry, now.Sub(createdAt))
	next := now.Add(delay)
	if next.After(deadline) {
		next = deadline
	}
	return store.NoticeOutcome{State: store.NoticePending, Error: sendErr.Error(), NextAttemptAt: next}
}
