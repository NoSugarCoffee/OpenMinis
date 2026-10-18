// Package eventbody builds the JSON body stored with each event and returned by `events get`
// (spec §8), plus the event's title and summary in notice form (spec §5.5). The app decodes these
// shapes, so field names and value formats are a contract: times are RFC 3339 in UTC, lists are
// never null, and an unknown value is the empty string rather than an omitted key.
package eventbody

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
)

type Address struct {
	Name    string `json:"name"`
	Address string `json:"address"`
}

type Attachment struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Size int    `json:"size"`
}

type Mail struct {
	From        Address      `json:"from"`
	To          []Address    `json:"to"`
	Subject     string       `json:"subject"`
	Date        string       `json:"date"`
	MessageID   string       `json:"messageId"`
	Text        string       `json:"text"`
	Truncated   bool         `json:"truncated"`
	Attachments []Attachment `json:"attachments"`
}

type GitHub struct {
	Repo         string `json:"repo"`
	Reason       string `json:"reason"`
	SubjectType  string `json:"subjectType"`
	SubjectTitle string `json:"subjectTitle"`
	HTMLURL      string `json:"htmlUrl"`
	ThreadID     string `json:"threadId"`
	UpdatedAt    string `json:"updatedAt"`
}

const (
	unknownSender = "(unknown sender)"
	noSubject     = "(no subject)"
)

// FromMail keeps the first From address only: the body has room for one sender, and a message with
// zero or several is stored only (gate rule 1), so the app shows it as untrusted anyway.
func FromMail(m candidate.Mail) Mail {
	var from Address
	if len(m.From) > 0 {
		from = address(m.From[0])
	}
	to := make([]Address, 0, len(m.To))
	for _, a := range m.To {
		to = append(to, address(a))
	}
	attachments := make([]Attachment, 0, len(m.Attachments))
	for _, a := range m.Attachments {
		attachments = append(attachments, Attachment{Name: a.Name, Type: a.Type, Size: a.Size})
	}
	return Mail{
		From:        from,
		To:          to,
		Subject:     m.Subject,
		Date:        timestamp(m.Date),
		MessageID:   m.MessageID,
		Text:        m.Text,
		Truncated:   m.Truncated,
		Attachments: attachments,
	}
}

func FromGitHub(n candidate.GitHub) GitHub {
	return GitHub{
		Repo:         n.Repo,
		Reason:       n.Reason,
		SubjectType:  n.SubjectType,
		SubjectTitle: n.SubjectTitle,
		HTMLURL:      n.HTMLURL,
		ThreadID:     n.ThreadID,
		UpdatedAt:    timestamp(n.UpdatedAt),
	}
}

func (m Mail) JSON() json.RawMessage   { return mustMarshal(m) }
func (g GitHub) JSON() json.RawMessage { return mustMarshal(g) }

// MailTitle is the sender's display name, or the address when the name is empty.
func MailTitle(m candidate.Mail) string {
	if len(m.From) == 0 {
		return unknownSender
	}
	if m.From[0].Name != "" {
		return m.From[0].Name
	}
	if m.From[0].Address != "" {
		return m.From[0].Address
	}
	return unknownSender
}

func MailSummary(m candidate.Mail) string {
	if m.Subject == "" {
		return noSubject
	}
	return m.Subject
}

func GitHubTitle(n candidate.GitHub) string { return n.Repo }

func GitHubSummary(n candidate.GitHub) string { return n.Reason + ": " + n.SubjectTitle }

func address(a candidate.Address) Address { return Address{Name: a.Name, Address: a.Address} }

// timestamp writes the zero time (a missing Date header) as "" so the app never shows year 1.
func timestamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// mustMarshal leaves <, > and & as they are: mail text and Message-IDs are full of them, and the
// body is never embedded in HTML.
func mustMarshal[T Mail | GitHub](v T) json.RawMessage {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		panic(fmt.Sprintf("eventbody: encode %T: %v", v, err))
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
}
