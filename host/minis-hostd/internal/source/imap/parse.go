package imap

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/emersion/go-message"
	// Registers the charsets go-message decodes bodies and RFC 2047 words with.
	_ "github.com/emersion/go-message/charset"
	"github.com/emersion/go-message/mail"
	"github.com/emersion/go-message/textproto"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/candidate"
)

const (
	// FetchCap bounds one BODY.PEEK[] partial fetch.
	FetchCap = 1 << 20
	// TextCap bounds the plain text kept in an event.
	TextCap = 64 << 10
)

// Fetched is one message as the server returned it. Raw holds at most FetchCap bytes; Size is
// RFC822.SIZE, the whole message.
type Fetched struct {
	Account      string
	UIDValidity  uint32
	UID          uint32
	InternalDate time.Time
	Size         int64
	Raw          []byte
}

func (f Fetched) cut() bool { return f.Size > int64(len(f.Raw)) }

func EventKey(account string, uidValidity, uid uint32) string {
	return fmt.Sprintf("mail:%s:%d:%d", account, uidValidity, uid)
}

// Parse turns a fetched message into a candidate. It fails when the header or the MIME structure
// cannot be read; a message cut at FetchCap is not a failure, its unread rest is simply missing.
func Parse(f Fetched) (candidate.Mail, error) {
	if len(f.Raw) == 0 {
		return candidate.Mail{}, fmt.Errorf("imap: the server returned no bytes for uid %d", f.UID)
	}
	reader, err := mail.CreateReader(bytes.NewReader(f.Raw))
	if err != nil && !message.IsUnknownCharset(err) {
		return candidate.Mail{}, fmt.Errorf("imap: read header of uid %d: %w", f.UID, err)
	}
	m, err := headerFields(f, reader.Header)
	if err != nil {
		return candidate.Mail{}, err
	}
	body, err := readBody(reader, f.cut())
	if err != nil {
		return candidate.Mail{}, fmt.Errorf("imap: read body of uid %d: %w", f.UID, err)
	}
	text, textCut := capText(body.text())
	m.Text = text
	m.Truncated = f.cut() || textCut
	m.Attachments = body.attachments
	return m, nil
}

// Unreadable is what is recorded for a message Parse rejected, since the same bytes would fail
// again. It never names a sender, so the gate stores it as malformed and it never pushes.
func Unreadable(f Fetched, parseErr error) candidate.Mail {
	m := candidate.Mail{
		Key: EventKey(f.Account, f.UIDValidity, f.UID), Account: f.Account,
		UIDValidity: f.UIDValidity, UID: f.UID, InternalDate: f.InternalDate, Truncated: f.cut(),
		Text: fmt.Sprintf("minis-hostd could not read this message (%v). It was left untouched in the mailbox.", parseErr),
	}
	header, err := textproto.ReadHeader(bufio.NewReader(bytes.NewReader(f.Raw)))
	if err != nil {
		return m
	}
	h := mail.Header{Header: message.Header{Header: header}}
	m.MessageID = strings.TrimSpace(h.Get("Message-Id"))
	if subject, err := h.Subject(); err == nil {
		m.Subject = subject
	}
	if date, err := h.Date(); err == nil {
		m.Date = date
	}
	return m
}

func headerFields(f Fetched, h mail.Header) (candidate.Mail, error) {
	from, err := addresses(h, "From")
	if err != nil {
		return candidate.Mail{}, err
	}
	subject, err := h.Subject()
	if err != nil {
		subject = h.Get("Subject")
	}
	// A missing or malformed Date stays zero: the gate's freshness rule reads InternalDate.
	date, _ := h.Date()
	return candidate.Mail{
		Key:                EventKey(f.Account, f.UIDValidity, f.UID),
		Account:            f.Account,
		UIDValidity:        f.UIDValidity,
		UID:                f.UID,
		MessageID:          strings.TrimSpace(h.Get("Message-Id")),
		From:               from,
		ReplyTo:            displayAddresses(h, "Reply-To"),
		To:                 displayAddresses(h, "To"),
		Subject:            subject,
		Date:               date,
		InternalDate:       f.InternalDate,
		AuthResults:        h.Values("Authentication-Results"),
		AutoSubmitted:      strings.TrimSpace(h.Get("Auto-Submitted")),
		Precedence:         strings.TrimSpace(h.Get("Precedence")),
		HasListUnsubscribe: h.Get("List-Unsubscribe") != "",
		HasListID:          h.Get("List-Id") != "",
	}, nil
}

// addresses reads every header field named key, so a message with two From fields shows two
// addresses and the gate can reject it.
func addresses(h mail.Header, key string) ([]candidate.Address, error) {
	var list []candidate.Address
	fields := h.FieldsByKey(key)
	for fields.Next() {
		parsed, err := mail.ParseAddressList(fields.Value())
		if err != nil {
			return nil, fmt.Errorf("imap: %s %q: %w", key, fields.Value(), err)
		}
		for _, a := range parsed {
			list = append(list, candidate.Address{Name: a.Name, Address: strings.ToLower(a.Address)})
		}
	}
	return list, nil
}

// displayAddresses keeps an unparseable To or Reply-To as its raw text: no rule reads them, so
// such a header should not make the whole message unreadable.
func displayAddresses(h mail.Header, key string) []candidate.Address {
	list, err := addresses(h, key)
	if err != nil {
		return []candidate.Address{{Name: h.Get(key)}}
	}
	return list
}

type body struct {
	plain       string
	html        string
	attachments []candidate.Attachment
}

func (b body) text() string {
	if strings.TrimSpace(b.plain) != "" {
		return b.plain
	}
	return htmlToText(b.html)
}

func readBody(reader *mail.Reader, cut bool) (body, error) {
	var b body
	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			return b, nil
		}
		if err != nil && !message.IsUnknownCharset(err) {
			if cut {
				return b, nil
			}
			return b, err
		}
		content, readErr := io.ReadAll(io.LimitReader(part.Body, FetchCap))
		if readErr != nil && !cut {
			return b, readErr
		}
		switch header := part.Header.(type) {
		case *mail.InlineHeader:
			mediaType, _, _ := header.ContentType()
			switch {
			case mediaType == "text/html" && b.html == "":
				b.html = validUTF8(content)
			case mediaType == "text/plain" && b.plain == "":
				b.plain = validUTF8(content)
			}
		case *mail.AttachmentHeader:
			name, _ := header.Filename()
			mediaType, _, _ := header.ContentType()
			b.attachments = append(b.attachments, candidate.Attachment{Name: name, Type: mediaType, Size: len(content)})
		}
		if readErr != nil {
			return b, nil
		}
	}
}

func validUTF8(content []byte) string { return strings.ToValidUTF8(string(content), "�") }

func capText(text string) (string, bool) {
	if len(text) <= TextCap {
		return text, false
	}
	end := TextCap
	for end > 0 && !utf8.RuneStart(text[end]) {
		end--
	}
	return text[:end], true
}
