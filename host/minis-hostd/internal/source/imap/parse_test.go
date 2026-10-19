package imap

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/gate"
)

var received = time.Date(2026, 10, 19, 16, 14, 2, 0, time.UTC)

// fixture reads a test message with CRLF line ends, as IMAP servers send them.
func fixture(t *testing.T, dir, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", dir, name+".eml"))
	if err != nil {
		t.Fatal(err)
	}
	return crlf(raw)
}

func crlf(raw []byte) []byte {
	return bytes.ReplaceAll(bytes.ReplaceAll(raw, []byte("\r\n"), []byte("\n")), []byte("\n"), []byte("\r\n"))
}

func fetched(raw []byte) Fetched {
	return Fetched{Account: "personal", UIDValidity: 7, UID: 42, InternalDate: received, Size: int64(len(raw)), Raw: raw}
}

func parse(t *testing.T, raw []byte) candidate.Mail {
	t.Helper()
	m, err := Parse(fetched(raw))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestParseHeadersAndKey(t *testing.T) {
	m := parse(t, fixture(t, "imap", "latin1_qp"))
	if m.Key != "mail:personal:7:42" || m.Account != "personal" || m.UIDValidity != 7 || m.UID != 42 {
		t.Errorf("identity %q %q %d %d", m.Key, m.Account, m.UIDValidity, m.UID)
	}
	if !slices.Equal(m.From, []candidate.Address{{Name: "René François", Address: "rene@example.fr"}}) {
		t.Errorf("from %+v", m.From)
	}
	if !slices.Equal(m.ReplyTo, []candidate.Address{{Name: "Desk", Address: "reply@example.fr"}}) {
		t.Errorf("reply-to %+v", m.ReplyTo)
	}
	if !slices.Equal(m.To, []candidate.Address{{Name: "Me", Address: "me@gmail.com"}, {Address: "other@example.org"}}) {
		t.Errorf("to %+v", m.To)
	}
	if m.Subject != "Résumé du café" {
		t.Errorf("subject %q", m.Subject)
	}
	if m.MessageID != "<latin1@example.fr>" {
		t.Errorf("message id %q", m.MessageID)
	}
	if !m.Date.Equal(time.Date(2026, 10, 19, 16, 14, 0, 0, time.UTC)) || !m.InternalDate.Equal(received) {
		t.Errorf("dates %v %v", m.Date, m.InternalDate)
	}
}

func TestQuotedPrintableLatin1Decodes(t *testing.T) {
	m := parse(t, fixture(t, "imap", "latin1_qp"))
	want := "Le café est prêt. Une ligne très longue qui est coupée par le codage quoted-printable.\r\n"
	if m.Text != want || m.Truncated {
		t.Errorf("text %q truncated %v", m.Text, m.Truncated)
	}
}

func TestBase64AndGB2312Decode(t *testing.T) {
	m := parse(t, fixture(t, "imap", "gb2312"))
	if m.Subject != "你好" || m.Text != "你好，世界" {
		t.Errorf("subject %q text %q", m.Subject, m.Text)
	}
}

func TestPlainTextWinsAndAttachmentsAreListed(t *testing.T) {
	m := parse(t, fixture(t, "imap", "mixed_attachments"))
	if m.Subject != "Prüfbericht" {
		t.Errorf("subject %q", m.Subject)
	}
	if m.Text != "Grüße aus München — 你好\r\nZweite Zeile.\r\n" {
		t.Errorf("text %q", m.Text)
	}
	want := []candidate.Attachment{
		{Name: "report.pdf", Type: "application/pdf", Size: 23},
		{Name: "你好.txt", Type: "text/plain", Size: len("你好，世界")},
	}
	if !slices.Equal(m.Attachments, want) {
		t.Errorf("attachments %+v, want %+v", m.Attachments, want)
	}
}

func TestHTMLOnlyMailYieldsText(t *testing.T) {
	m := parse(t, fixture(t, "imap", "html_only"))
	want := "Dinner at 7 & drinks after?\n\n• Bring wine\n• Bring <cheese>\n\nSee you"
	if m.Text != want {
		t.Errorf("text %q, want %q", m.Text, want)
	}
}

func TestEveryAuthenticationResultsIsKeptTopmostFirst(t *testing.T) {
	m := parse(t, fixture(t, "imap", "relayed"))
	if len(m.AuthResults) != 3 ||
		!strings.HasPrefix(m.AuthResults[0], "mx.google.com;") || !strings.Contains(m.AuthResults[0], "dmarc=pass") ||
		!strings.HasPrefix(m.AuthResults[1], "relay.example.net;") ||
		!strings.Contains(m.AuthResults[2], "dmarc=fail") {
		t.Fatalf("auth results %q", m.AuthResults)
	}
	if m.AutoSubmitted != "no" {
		t.Errorf("auto-submitted %q", m.AutoSubmitted)
	}
	rules := []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: true}}
	if got := gate.Mail(m, rules, received.Add(time.Minute)); got.Action != gate.ActionPush {
		t.Errorf("Gmail's own header said pass, gate decided %+v", got)
	}
}

// The gate's fixtures go through the real parser here, so its decisions hold for parsed mail.
func TestGateFixturesDecideTheSameWhenParsed(t *testing.T) {
	cases := map[string]gate.Decision{
		"dmarc_pass":   {Action: gate.ActionPush, Reason: gate.ReasonAllowed},
		"forged_lower": {Action: gate.ActionStoreOnly, Reason: gate.ReasonSenderUnauthenticated},
		"two_from":     {Action: gate.ActionStoreOnly, Reason: gate.ReasonMalformedSender},
		"newsletter":   {Action: gate.ActionDrop, Reason: gate.ReasonAutomated},
		"auto_replied": {Action: gate.ActionDrop, Reason: gate.ReasonAutomated},
	}
	rules := []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: true}, {Pattern: "@example.com", RequireDMARC: true}}
	for name, want := range cases {
		m := parse(t, fixture(t, "mail", name))
		if got := gate.Mail(m, rules, received.Add(time.Hour)); got != want {
			t.Errorf("%s: %+v, want %+v", name, got, want)
		}
	}
}

func TestLongTextIsCappedOnARuneBoundary(t *testing.T) {
	header := "From: alice@example.com\r\nSubject: Long\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n"
	raw := []byte(header + "a" + strings.Repeat("é", TextCap))
	m := parse(t, raw)
	if !m.Truncated || len(m.Text) > TextCap || len(m.Text) < TextCap-1 || !utf8.ValidString(m.Text) {
		t.Errorf("truncated %v, %d bytes, valid %v", m.Truncated, len(m.Text), utf8.ValidString(m.Text))
	}
}

func TestMessageCutAtTheFetchCapKeepsHeadersAndText(t *testing.T) {
	full := bigMessage(2 << 20)
	f := fetched(full[:FetchCap])
	f.Size = int64(len(full))
	m, err := Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	if !m.Truncated || m.Subject != "Big" || len(m.From) != 1 || !strings.HasPrefix(m.Text, "line 0\r\n") {
		t.Errorf("truncated %v subject %q from %+v text %.20q", m.Truncated, m.Subject, m.From, m.Text)
	}
}

func bigMessage(size int) []byte {
	var b bytes.Buffer
	b.WriteString("From: Alice Example <alice@example.com>\r\nTo: me@gmail.com\r\nSubject: Big\r\n" +
		"Message-ID: <big@example.com>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" +
		"--b\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n")
	for i := 0; b.Len() < size; i++ {
		fmt.Fprintf(&b, "line %d\r\n", i)
	}
	b.WriteString("--b--\r\n")
	return b.Bytes()
}

func TestBrokenHeaderIsUnreadableAndNeverPushes(t *testing.T) {
	raw := []byte("From: Alice Example <alice@example.com>\r\nThis line has no colon\r\n\r\nBody\r\n")
	f := fetched(raw)
	_, err := Parse(f)
	if err == nil {
		t.Fatal("parsed a header with a line that has no colon")
	}
	m := Unreadable(f, err)
	if m.Key != "mail:personal:7:42" || len(m.From) != 0 || !strings.Contains(m.Text, "could not read") {
		t.Errorf("unreadable %+v", m)
	}
	rules := []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: false}}
	if got := gate.Mail(m, rules, received); got.Action != gate.ActionStoreOnly {
		t.Errorf("unreadable mail decided %+v", got)
	}
}

func TestBrokenFromIsUnreadableButKeepsSubject(t *testing.T) {
	raw := []byte("From: <<<broken\r\nSubject: Still here\r\nMessage-ID: <b@example.com>\r\n\r\nBody\r\n")
	f := fetched(raw)
	_, err := Parse(f)
	if err == nil {
		t.Fatal("parsed a broken From")
	}
	m := Unreadable(f, err)
	if m.Subject != "Still here" || m.MessageID != "<b@example.com>" || len(m.From) != 0 {
		t.Errorf("unreadable %+v", m)
	}
}
