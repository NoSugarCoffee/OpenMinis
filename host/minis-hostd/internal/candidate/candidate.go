// Package candidate holds what a source hands to the gate: one new mail or GitHub notification,
// before any rule has looked at it.
package candidate

import "time"

type Address struct {
	Name    string
	Address string // lower-cased
}

type Attachment struct {
	Name string
	Type string
	Size int
}

type Mail struct {
	Key          string // mail:<account>:<uidValidity>:<uid>
	Account      string
	UIDValidity  uint32
	UID          uint32
	MessageID    string
	From         []Address // every address in From; the gate rejects anything but exactly one
	ReplyTo      []Address
	To           []Address
	Subject      string
	Date         time.Time // the Date header
	InternalDate time.Time // when the server received it; freshness uses this
	// AuthResults holds every Authentication-Results header value, topmost first, as received.
	AuthResults        []string
	AutoSubmitted      string
	Precedence         string
	HasListUnsubscribe bool
	HasListID          bool
	Text               string // plain text, capped at 64 KiB
	Truncated          bool
	Attachments        []Attachment
}

type GitHub struct {
	Key          string // gh:<threadId>:<updatedAt>
	ThreadID     string
	Repo         string // owner/name
	Reason       string
	SubjectType  string
	SubjectTitle string
	HTMLURL      string
	UpdatedAt    time.Time
}
