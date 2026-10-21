// Package pacing decides when a pushed event becomes a notification: at once, in a coalesced
// batch, or not at all once the daily cap is reached (spec §5.3). It is pure: the clock, ids and
// state come in as values, and the caller persists the returned state with the event.
package pacing

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

const (
	Hold     = 2 * time.Minute
	DailyCap = 30
)

const dayLayout = "2006-01-02"

var ErrEmptyBatch = errors.New("pacing: batch has no events")

type State struct {
	LastPushAt    time.Time `json:"lastPushAt"`
	OpenBatchID   string    `json:"openBatchId,omitempty"`
	BatchFlushAt  time.Time `json:"batchFlushAt"`
	PushesToday   int       `json:"pushesToday"`
	Day           string    `json:"day,omitempty"`
	CapNoticeSent bool      `json:"capNoticeSent"`
}

func (s State) Encode() string {
	data, err := json.Marshal(s)
	if err != nil {
		panic(fmt.Sprintf("pacing: encode state: %v", err))
	}
	return string(data)
}

// Decode treats the empty string as a fresh install, since the store has no pacing row yet.
func Decode(raw string) (State, error) {
	if raw == "" {
		return State{}, nil
	}
	var s State
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		return State{}, fmt.Errorf("pacing: decode state %q: %w", raw, err)
	}
	return s, nil
}

type Kind int

const (
	SendNow Kind = iota + 1
	JoinBatch
	SendCapNotice
	StoreCapped
)

func (k Kind) String() string {
	switch k {
	case SendNow:
		return "SendNow"
	case JoinBatch:
		return "JoinBatch"
	case SendCapNotice:
		return "SendCapNotice"
	case StoreCapped:
		return "StoreCapped"
	}
	return fmt.Sprintf("Kind(%d)", int(k))
}

// Decision carries BatchID and FlushAt for JoinBatch, and Day for SendCapNotice.
type Decision struct {
	Kind    Kind
	BatchID string
	FlushAt time.Time
	Day     string
}

// Placement is what the store writes with the event this decision was made for.
func (d Decision) Placement(e EventSummary) store.Placement {
	switch d.Kind {
	case SendNow:
		notice := SingleNotice(e)
		return store.Placement{Notice: &notice}
	case JoinBatch:
		return store.Placement{Batch: &store.BatchJoin{ID: d.BatchID, FlushAt: d.FlushAt}}
	case SendCapNotice:
		notice := CapNotice(d.Day)
		return store.Placement{Notice: &notice}
	}
	return store.Placement{}
}

func localDay(t time.Time, loc *time.Location) string { return t.In(loc).Format(dayLayout) }

func rollDay(s State, now time.Time, loc *time.Location) State {
	day := localDay(now, loc)
	if s.Day != day {
		s.Day, s.PushesToday, s.CapNoticeSent = day, 0, false
	}
	return s
}

func later(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// Decide places one event the gate pushes. The cap is checked before joining a batch, so an open
// batch always closes below the cap and Close never has to drop one.
func Decide(s State, now time.Time, quiet *config.Window, loc *time.Location, newBatchID string) (Decision, State) {
	s = rollDay(s, now, loc)
	if s.PushesToday >= DailyCap {
		if s.CapNoticeSent {
			return Decision{Kind: StoreCapped}, s
		}
		s.CapNoticeSent = true
		return Decision{Kind: SendCapNotice, Day: s.Day}, s
	}

	holdEnd := s.LastPushAt.Add(Hold)
	inHold := now.Before(holdEnd)
	inQuiet := quiet != nil && InQuietHours(now, *quiet, loc)
	if !inHold && !inQuiet && s.OpenBatchID == "" {
		s.LastPushAt = now
		s.PushesToday++
		return Decision{Kind: SendNow}, s
	}

	flushAt := holdEnd
	if inQuiet {
		flushAt = later(flushAt, NextWindowEnd(now, *quiet, loc))
	}
	if s.OpenBatchID == "" {
		s.OpenBatchID = newBatchID
	} else {
		flushAt = later(flushAt, s.BatchFlushAt)
	}
	s.BatchFlushAt = flushAt
	return Decision{Kind: JoinBatch, BatchID: s.OpenBatchID, FlushAt: flushAt}, s
}

// Close turns a due batch into its notice. The push opens the next hold and counts once toward the
// day it is sent on. A batch other than the open one (left by an older state) is still closed but
// leaves the open batch alone.
func Close(s State, batchID string, events []EventSummary, now time.Time, loc *time.Location, host string) (store.Notice, State, error) {
	if len(events) == 0 {
		return store.Notice{}, s, fmt.Errorf("%w: %s", ErrEmptyBatch, batchID)
	}
	var notice store.Notice
	if len(events) == 1 {
		notice = SingleNotice(events[0])
		notice.BatchID = batchID
	} else {
		notice = BatchNotice(batchID, events, host)
	}
	s = rollDay(s, now, loc)
	s.LastPushAt = now
	s.PushesToday++
	if s.OpenBatchID == batchID {
		s.OpenBatchID, s.BatchFlushAt = "", time.Time{}
	}
	return notice, s, nil
}
