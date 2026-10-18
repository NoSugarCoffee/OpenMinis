package eventbody

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata/eventbody")

const (
	goldenDir   = "../../testdata/eventbody"
	contractDir = "../../testdata/contract"
)

var berlin = time.FixedZone("CEST", 2*60*60)

func sampleMail() candidate.Mail {
	return candidate.Mail{
		Key:          "mail:personal:7:4242",
		Account:      "personal",
		UIDValidity:  7,
		UID:          4242,
		MessageID:    "<CAF=abc123@mail.gmail.com>",
		From:         []candidate.Address{{Name: "Alice Chen", Address: "alice@example.com"}},
		ReplyTo:      []candidate.Address{{Name: "Ignored", Address: "reply@example.com"}},
		To:           []candidate.Address{{Name: "", Address: "me@gmail.com"}, {Name: "Bob Li", Address: "bob@example.org"}},
		Subject:      "Re: 合同 “第三版”",
		Date:         time.Date(2026, 10, 19, 10, 59, 12, 500, berlin),
		InternalDate: time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC),
		AuthResults:  []string{"mx.google.com; dmarc=pass"},
		Text:         "Hi,\n\nThe \"third\" draft is attached.\n\n— Alice <&>",
		Truncated:    true,
		Attachments:  []candidate.Attachment{{Name: "contract-v3.pdf", Type: "application/pdf", Size: 182344}},
	}
}

func sampleGitHub() candidate.GitHub {
	return candidate.GitHub{
		Key:          "gh:14567890123:2026-10-19T09:04:30Z",
		ThreadID:     "14567890123",
		Repo:         "NoSugarCoffee/OpenMinis",
		Reason:       "review_requested",
		SubjectType:  "PullRequest",
		SubjectTitle: "feat(hostd): add the push gate",
		HTMLURL:      "https://github.com/NoSugarCoffee/OpenMinis/pull/10",
		UpdatedAt:    time.Date(2026, 10, 19, 11, 4, 30, 0, berlin),
	}
}

func checkGolden(t *testing.T, name string, got json.RawMessage) {
	t.Helper()
	path := filepath.Join(goldenDir, name)
	var indented bytes.Buffer
	if err := json.Indent(&indented, got, "", "  "); err != nil {
		t.Fatal(err)
	}
	indented.WriteByte('\n')
	if *update {
		if err := os.MkdirAll(goldenDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, indented.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update to create it)", err)
	}
	if !bytes.Equal(indented.Bytes(), want) {
		t.Errorf("%s differs\ngot:\n%s\nwant:\n%s", name, indented.Bytes(), want)
	}
}

func TestMailBodyGolden(t *testing.T) {
	checkGolden(t, "mail.json", FromMail(sampleMail()).JSON())
}

func TestGitHubBodyGolden(t *testing.T) {
	checkGolden(t, "github.json", FromGitHub(sampleGitHub()).JSON())
}

func TestMailBodyWithoutListsHasEmptyArraysAndNoDate(t *testing.T) {
	m := sampleMail()
	m.To, m.Attachments, m.Date = nil, nil, time.Time{}
	got := string(FromMail(m).JSON())
	for _, want := range []string{`"to":[]`, `"attachments":[]`, `"date":""`} {
		if !bytes.Contains([]byte(got), []byte(want)) {
			t.Errorf("body %s lacks %s", got, want)
		}
	}
}

func TestMailBodyKeepsFirstSenderOfMalformedFrom(t *testing.T) {
	m := sampleMail()
	m.From = append(m.From, candidate.Address{Name: "Mallory", Address: "mallory@example.net"})
	if got := FromMail(m).From; got != (Address{Name: "Alice Chen", Address: "alice@example.com"}) {
		t.Errorf("from = %+v", got)
	}
	m.From = nil
	if got := FromMail(m).From; got != (Address{}) {
		t.Errorf("from = %+v, want empty", got)
	}
}

func TestTitlesAndSummaries(t *testing.T) {
	m := sampleMail()
	if got := MailTitle(m); got != "Alice Chen" {
		t.Errorf("MailTitle = %q", got)
	}
	if got := MailSummary(m); got != "Re: 合同 “第三版”" {
		t.Errorf("MailSummary = %q", got)
	}
	m.From = []candidate.Address{{Address: "alice@example.com"}}
	if got := MailTitle(m); got != "alice@example.com" {
		t.Errorf("MailTitle without name = %q", got)
	}
	m.From, m.Subject = nil, ""
	if got := MailTitle(m); got != unknownSender {
		t.Errorf("MailTitle without sender = %q", got)
	}
	if got := MailSummary(m); got != noSubject {
		t.Errorf("MailSummary without subject = %q", got)
	}
	g := sampleGitHub()
	if got := GitHubTitle(g); got != "NoSugarCoffee/OpenMinis" {
		t.Errorf("GitHubTitle = %q", got)
	}
	if got := GitHubSummary(g); got != "review_requested: feat(hostd): add the push gate" {
		t.Errorf("GitHubSummary = %q", got)
	}
}

// shape reduces a JSON value to its keys and value kinds, so a body can be compared with the CLI
// contract goldens without the values having to match.
func shape(t *testing.T, value json.RawMessage) string {
	t.Helper()
	var decoded any
	if err := json.Unmarshal(value, &decoded); err != nil {
		t.Fatal(err)
	}
	return describe(decoded)
}

func describe(v any) string {
	switch v := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		slices.Sort(keys)
		out := "{"
		for _, k := range keys {
			out += fmt.Sprintf("%s:%s,", k, describe(v[k]))
		}
		return out + "}"
	case []any:
		if len(v) == 0 {
			return "[]"
		}
		return "[" + describe(v[0]) + "]"
	case string:
		return "string"
	case float64:
		return "number"
	case bool:
		return "bool"
	case nil:
		return "null"
	}
	return fmt.Sprintf("%T", v)
}

func contractBody(t *testing.T, name string) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(contractDir, name))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Event struct {
			Body json.RawMessage `json:"body"`
		} `json:"event"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Event.Body
}

func TestBodiesMatchCLIContractShape(t *testing.T) {
	cases := []struct {
		golden string
		body   json.RawMessage
	}{
		{"events_get_mail.json", FromMail(sampleMail()).JSON()},
		{"events_get_github.json", FromGitHub(sampleGitHub()).JSON()},
	}
	for _, c := range cases {
		t.Run(c.golden, func(t *testing.T) {
			want, got := shape(t, contractBody(t, c.golden)), shape(t, c.body)
			if got != want {
				t.Errorf("shape differs from %s\ngot:  %s\nwant: %s", c.golden, got, want)
			}
		})
	}
}

func TestBodiesRoundTrip(t *testing.T) {
	mail := FromMail(sampleMail())
	var decodedMail Mail
	if err := json.Unmarshal(mail.JSON(), &decodedMail); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(decodedMail.To, mail.To) || decodedMail.Date != "2026-10-19T08:59:12Z" {
		t.Errorf("mail round trip: %+v", decodedMail)
	}
	gh := FromGitHub(sampleGitHub())
	var decodedGitHub GitHub
	if err := json.Unmarshal(gh.JSON(), &decodedGitHub); err != nil {
		t.Fatal(err)
	}
	if decodedGitHub != gh || gh.UpdatedAt != "2026-10-19T09:04:30Z" {
		t.Errorf("github round trip: %+v", decodedGitHub)
	}
}
