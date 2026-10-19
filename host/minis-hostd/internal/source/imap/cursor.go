package imap

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Cursor is how far one account's INBOX has been read. UIDs only mean something within one
// UIDVALIDITY, so the two always travel together.
type Cursor struct {
	UIDValidity uint32 `json:"uidValidity"`
	LastSeenUID uint32 `json:"lastSeenUid"`
}

func (c Cursor) Encode() string {
	encoded, err := json.Marshal(c)
	if err != nil {
		panic(fmt.Sprintf("imap: encode cursor %+v: %v", c, err))
	}
	return string(encoded)
}

type storedCursor struct {
	UIDValidity *uint32 `json:"uidValidity"`
	LastSeenUID *uint32 `json:"lastSeenUid"`
}

func DecodeCursor(value string) (Cursor, error) {
	decoder := json.NewDecoder(bytes.NewReader([]byte(value)))
	decoder.DisallowUnknownFields()
	var stored storedCursor
	if err := decoder.Decode(&stored); err != nil {
		return Cursor{}, fmt.Errorf("imap: stored cursor %q is not a mail cursor: %w", value, err)
	}
	if stored.UIDValidity == nil || stored.LastSeenUID == nil {
		return Cursor{}, fmt.Errorf("imap: stored cursor %q lacks uidValidity or lastSeenUid", value)
	}
	return Cursor{UIDValidity: *stored.UIDValidity, LastSeenUID: *stored.LastSeenUID}, nil
}

// Plan decides what a fresh connection does with the mailbox it found. fetchFrom is 0 when there
// is nothing to fetch: a first run or a changed UIDVALIDITY takes UIDNEXT-1 as the baseline so
// mail already in the mailbox never pushes, and re-pushing a whole mailbox after a reset would be
// worse than missing the gap (spec §4.1).
func Plan(stored *Cursor, uidValidity, uidNext uint32) (fetchFrom uint32, newCursor Cursor, reset bool) {
	baseline := Cursor{UIDValidity: uidValidity, LastSeenUID: uidNext - 1}
	switch {
	case stored == nil:
		return 0, baseline, false
	case stored.UIDValidity != uidValidity:
		return 0, baseline, true
	default:
		return stored.LastSeenUID + 1, *stored, false
	}
}
