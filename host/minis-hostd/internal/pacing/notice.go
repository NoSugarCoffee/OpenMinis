package pacing

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

const NoticeTextLimit = 120

const capNoticeTitle = "Daily cap reached"

// EventSummary is what notice text needs from an event. The caller fills Title and Body per source
// (spec §5.5): mail is sender name and subject, GitHub is owner/repo and "<reason>: <subject>".
type EventSummary struct {
	Source  store.Source
	Title   string
	Body    string
	URL     string
	Key     string
	EventID string
}

// SummaryOf maps a stored event, whose Title and Summary were written in notice form.
func SummaryOf(e store.Event) EventSummary {
	return EventSummary{Source: e.Source, Title: e.Title, Body: e.Summary, URL: e.URL, Key: e.Key, EventID: e.ID}
}

func truncate(text string) string {
	if utf8.RuneCountInString(text) <= NoticeTextLimit {
		return text
	}
	return string([]rune(text)[:NoticeTextLimit-1]) + "…"
}

func SingleNotice(e EventSummary) store.Notice {
	return store.Notice{Key: e.Key, EventID: e.EventID, Title: truncate(e.Title), Body: truncate(e.Body), URL: e.URL}
}

func BatchNotice(batchID string, events []EventSummary, host string) store.Notice {
	title, body := batchText(events)
	return store.Notice{
		Key:     "batch:" + batchID,
		BatchID: batchID,
		Title:   truncate(title),
		Body:    truncate(body),
		URL:     "minis://host-event/" + host + "/batch/" + batchID,
	}
}

func batchText(events []EventSummary) (title, body string) {
	counts := map[store.Source]int{}
	seen := map[string]bool{}
	var names []string
	for _, e := range events {
		counts[e.Source]++
		if !seen[e.Title] {
			seen[e.Title] = true
			names = append(names, e.Title)
		}
	}
	var parts []string
	if n := counts[store.SourceMail]; n > 0 {
		parts = append(parts, fmt.Sprintf("%d mail", n))
	}
	if n := counts[store.SourceGitHub]; n > 0 {
		parts = append(parts, fmt.Sprintf("%d GitHub", n))
	}
	return fmt.Sprintf("%d new: %s", len(events), strings.Join(parts, ", ")), strings.Join(names, ", ")
}

// CapNotice has no URL: it stands for no event or batch the app could open.
func CapNotice(day string) store.Notice {
	return store.Notice{
		Key:   "cap:" + day,
		Title: capNoticeTitle,
		Body:  fmt.Sprintf("%d notifications today. New events are stored until tomorrow.", DailyCap),
	}
}
