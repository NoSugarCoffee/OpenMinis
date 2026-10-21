package cli

import (
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

const maxListLimit = 200

const (
	usageEventsList = "minis-hostd events list --limit N [--before <id>] --json"
	usageEventsGet  = "minis-hostd events get <id> --json"
	usageEventsAck  = "minis-hostd events ack <id>... --json"
	usageBatchesGet = "minis-hostd batches get <id> --json"
)

type eventSummary struct {
	ID        string  `json:"id"`
	Source    string  `json:"source"`
	CreatedAt string  `json:"createdAt"`
	Title     string  `json:"title"`
	Summary   string  `json:"summary"`
	Decision  string  `json:"decision"`
	Reason    string  `json:"reason"`
	AckedAt   *string `json:"ackedAt"`
}

type eventDetail struct {
	eventSummary
	URL  string          `json:"url"`
	Body json.RawMessage `json:"body"`
}

type eventsListOutput struct {
	SchemaVersion int            `json:"schemaVersion"`
	Events        []eventSummary `json:"events"`
}

type eventGetOutput struct {
	SchemaVersion int         `json:"schemaVersion"`
	Event         eventDetail `json:"event"`
}

type batchDetail struct {
	ID        string        `json:"id"`
	CreatedAt string        `json:"createdAt"`
	Events    []eventDetail `json:"events"`
}

type batchGetOutput struct {
	SchemaVersion int         `json:"schemaVersion"`
	Batch         batchDetail `json:"batch"`
}

type ackOutput struct {
	SchemaVersion int  `json:"schemaVersion"`
	OK            bool `json:"ok"`
}

func summarize(e store.Event) eventSummary {
	return eventSummary{
		ID: e.ID, Source: string(e.Source), CreatedAt: formatTime(e.CreatedAt), Title: e.Title,
		Summary: e.Summary, Decision: e.Decision, Reason: e.Reason, AckedAt: formatOptionalTime(e.AckedAt),
	}
}

func detail(e store.Event) eventDetail {
	return eventDetail{eventSummary: summarize(e), URL: e.URL, Body: e.Body}
}

func encodeEventsList(events []store.Event) eventsListOutput {
	summaries := make([]eventSummary, 0, len(events))
	for _, e := range events {
		summaries = append(summaries, summarize(e))
	}
	return eventsListOutput{SchemaVersion: SchemaVersion, Events: summaries}
}

func encodeBatch(b store.Batch) batchGetOutput {
	events := make([]eventDetail, 0, len(b.Events))
	for _, e := range b.Events {
		events = append(events, detail(e))
	}
	return batchGetOutput{
		SchemaVersion: SchemaVersion,
		Batch:         batchDetail{ID: b.ID, CreatedAt: formatTime(b.OpenedAt), Events: events},
	}
}

func runEvents(env Env, args []string) int {
	if len(args) == 0 {
		return fail(env, CodeBadRequest, "usage: minis-hostd events list|get|ack ... --json")
	}
	switch args[0] {
	case "list":
		return eventsList(env, args[1:])
	case "get":
		return eventsGet(env, args[1:])
	case "ack":
		return eventsAck(env, args[1:])
	default:
		return fail(env, CodeBadRequest, fmt.Sprintf("unknown command \"events %s\"", args[0]))
	}
}

func runBatches(env Env, args []string) int {
	if len(args) == 0 || args[0] != "get" {
		return fail(env, CodeBadRequest, "usage: "+usageBatchesGet)
	}
	return batchesGet(env, args[1:])
}

func parseLimit(value string) (int, error) {
	limit, err := strconv.Atoi(value)
	if err != nil || limit < 1 || limit > maxListLimit {
		return 0, &commandError{
			Code:    CodeBadRequest,
			Message: fmt.Sprintf("--limit must be a whole number from 1 to %d, got %q", maxListLimit, value),
		}
	}
	return limit, nil
}

func eventsList(env Env, args []string) int {
	parsed, err := parseArgs(args, []string{"--limit", "--before"}, usageEventsList)
	if err != nil {
		return failWith(env, err)
	}
	limitValue, hasLimit := parsed.Values["--limit"]
	if len(parsed.Positional) != 0 || !hasLimit {
		return failWith(env, badRequest(usageEventsList))
	}
	limit, err := parseLimit(limitValue)
	if err != nil {
		return failWith(env, err)
	}
	s, err := openStore(env, true)
	if err != nil {
		return failWith(env, err)
	}
	defer s.Close()
	events, err := s.ListEvents(limit, parsed.Values["--before"])
	if err != nil {
		return failWith(env, err)
	}
	return emit(env, encodeEventsList(events))
}

func eventsGet(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageEventsGet)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) != 1 {
		return failWith(env, badRequest(usageEventsGet))
	}
	s, err := openStore(env, true)
	if err != nil {
		return failWith(env, err)
	}
	defer s.Close()
	e, err := s.GetEvent(parsed.Positional[0])
	if err != nil {
		return failWith(env, notFound("event", err))
	}
	return emit(env, eventGetOutput{SchemaVersion: SchemaVersion, Event: detail(e)})
}

func batchesGet(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageBatchesGet)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) != 1 {
		return failWith(env, badRequest(usageBatchesGet))
	}
	s, err := openStore(env, true)
	if err != nil {
		return failWith(env, err)
	}
	defer s.Close()
	b, err := s.GetBatch(parsed.Positional[0])
	if err != nil {
		return failWith(env, notFound("batch", err))
	}
	return emit(env, encodeBatch(b))
}

func eventsAck(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageEventsAck)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) == 0 {
		return failWith(env, badRequest(usageEventsAck))
	}
	s, err := openStore(env, false)
	if err != nil {
		return failWith(env, err)
	}
	defer s.Close()
	if err := s.Ack(parsed.Positional, env.Now()); err != nil {
		return failWith(env, notFound("event", err))
	}
	return emit(env, ackOutput{SchemaVersion: SchemaVersion, OK: true})
}
