package daemon

import (
	"context"
	"time"
)

// Clock is the daemon's only source of time, so tests drive every loop with a fake one.
type Clock interface {
	Now() time.Time
	NewTimer(d time.Duration) Timer
}

type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

type systemClock struct{}

type systemTimer struct{ timer *time.Timer }

func SystemClock() Clock { return systemClock{} }

func (systemClock) Now() time.Time { return time.Now() }

func (systemClock) NewTimer(d time.Duration) Timer { return systemTimer{timer: time.NewTimer(d)} }

func (t systemTimer) C() <-chan time.Time { return t.timer.C }

func (t systemTimer) Stop() bool { return t.timer.Stop() }

// sleep reports false when ctx ended first.
func sleep(ctx context.Context, clock Clock, d time.Duration) bool {
	timer := clock.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C():
		return true
	}
}

// every runs fn at once and then each interval until ctx ends or fn fails.
func every(ctx context.Context, clock Clock, interval time.Duration, fn func(now time.Time) error) error {
	for {
		if err := fn(clock.Now()); err != nil {
			return err
		}
		if !sleep(ctx, clock, interval) {
			return nil
		}
	}
}
