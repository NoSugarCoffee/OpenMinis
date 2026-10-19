package gate

import (
	"net/mail"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

var testNow = time.Date(2026, 10, 19, 17, 0, 0, 0, time.UTC)

var aliceRules = []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: true}}

// loadEML reads only the headers the gate looks at; the real parser arrives with the IMAP source.
func loadEML(t *testing.T, name string) candidate.Mail {
	t.Helper()
	file, err := os.Open(filepath.Join("..", "..", "testdata", "mail", name+".eml"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	msg, err := mail.ReadMessage(file)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	var from []candidate.Address
	for _, value := range msg.Header["From"] {
		list, err := mail.ParseAddressList(value)
		if err != nil {
			t.Fatalf("%s: From %q: %v", name, value, err)
		}
		for _, address := range list {
			from = append(from, candidate.Address{Name: address.Name, Address: strings.ToLower(address.Address)})
		}
	}
	return candidate.Mail{
		From:               from,
		InternalDate:       testNow.Add(-time.Hour),
		AuthResults:        msg.Header["Authentication-Results"],
		AutoSubmitted:      msg.Header.Get("Auto-Submitted"),
		Precedence:         msg.Header.Get("Precedence"),
		HasListUnsubscribe: msg.Header.Get("List-Unsubscribe") != "",
		HasListID:          msg.Header.Get("List-Id") != "",
	}
}

func authenticMail(from string) candidate.Mail {
	return candidate.Mail{
		From:         []candidate.Address{{Name: "Sender", Address: from}},
		InternalDate: testNow.Add(-time.Hour),
		AuthResults:  []string{"mx.google.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com"},
	}
}

func assertDecision(t *testing.T, got Decision, action Action, reason string) {
	t.Helper()
	if got != (Decision{Action: action, Reason: reason}) {
		t.Errorf("got %+v, want {%s %s}", got, action, reason)
	}
}

func TestFixtures(t *testing.T) {
	cases := []struct {
		fixture string
		action  Action
		reason  string
	}{
		{"dmarc_pass", ActionPush, ReasonAllowed},
		{"dmarc_fail", ActionStoreOnly, ReasonSenderUnauthenticated},
		{"dmarc_none", ActionStoreOnly, ReasonSenderUnauthenticated},
		{"forged_lower", ActionStoreOnly, ReasonSenderUnauthenticated},
		{"forged_other_authserv", ActionStoreOnly, ReasonSenderUnauthenticated},
		{"two_from", ActionStoreOnly, ReasonMalformedSender},
		{"newsletter", ActionDrop, ReasonAutomated},
		{"noreply", ActionDrop, ReasonAutomated},
		{"auto_replied", ActionDrop, ReasonAutomated},
	}
	rules := []config.SenderRule{{Pattern: "@example.com", RequireDMARC: true}}
	for _, c := range cases {
		t.Run(c.fixture, func(t *testing.T) {
			assertDecision(t, Mail(loadEML(t, c.fixture), rules, testNow), c.action, c.reason)
		})
	}
}

func TestForgedAuthResultsBelowGmailsIsIgnored(t *testing.T) {
	pass, found := DMARCFromGmail(loadEML(t, "forged_lower").AuthResults)
	if pass || !found {
		t.Errorf("pass %v found %v, want the topmost Gmail header's fail", pass, found)
	}
	assertDecision(t, Mail(loadEML(t, "forged_lower"), aliceRules, testNow),
		ActionStoreOnly, ReasonSenderUnauthenticated)
}

func TestDMARCFromGmail(t *testing.T) {
	gmailPass := "mx.google.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com"
	cases := []struct {
		name    string
		headers []string
		pass    bool
		found   bool
	}{
		{"no headers", nil, false, false},
		{"pass", []string{gmailPass}, true, true},
		{"fail", []string{"mx.google.com; dmarc=fail (p=REJECT) header.from=example.com"}, false, true},
		{"no dmarc method", []string{"mx.google.com; dkim=pass header.i=@example.com; spf=pass smtp.mailfrom=example.com"}, false, true},
		{"none", []string{"mx.google.com; none"}, false, true},
		{"authserv-id with version", []string{"mx.google.com 1; dmarc=pass header.from=example.com"}, true, true},
		{"authserv-id case", []string{"MX.Google.COM; dmarc=pass"}, true, true},
		{"method with version", []string{"mx.google.com; dmarc/1=pass header.from=example.com"}, true, true},
		{"spaces around equals", []string{"mx.google.com; dmarc = pass header.from=example.com"}, true, true},
		{"result case", []string{"mx.google.com; dmarc=PASS"}, true, true},
		{"folded header", []string{"mx.google.com;\r\n       dkim=pass header.i=@example.com;\r\n       dmarc=pass header.from=example.com"}, true, true},
		{"other authserv-id ignored", []string{"relay.example.net; dmarc=pass", "mx.google.com; dmarc=fail"}, false, true},
		{"only other authserv-id", []string{"relay.example.net; dmarc=pass"}, false, false},
		{"lookalike authserv-id", []string{"mx.google.com.evil.example; dmarc=pass"}, false, false},
		{"authserv-id in a comment", []string{"(mx.google.com) relay.example.net; dmarc=pass"}, false, false},
		{"topmost Gmail header wins", []string{"mx.google.com; dmarc=fail", gmailPass}, false, true},
		{"pass inside a comment", []string{"mx.google.com; dmarc=fail (dmarc=pass)"}, false, true},
		{"pass inside a comment only", []string{"mx.google.com; spf=pass (dmarc=pass; really) smtp.mailfrom=a@example.com"}, false, true},
		{"nested comment", []string{"mx.google.com; spf=pass (outer (inner) dmarc=pass) smtp.mailfrom=a@example.com"}, false, true},
		{"escaped paren in comment", []string{`mx.google.com; spf=pass (a \) ; dmarc=pass) smtp.mailfrom=a@example.com`}, false, true},
		{"pass as a property value", []string{"mx.google.com; spf=pass smtp.mailfrom=dmarc=pass"}, false, true},
		{"pass in a quoted property", []string{`mx.google.com; spf=pass reason="x; dmarc=pass"`}, false, true},
		{"prefixed method name", []string{"mx.google.com; xdmarc=pass"}, false, true},
		{"conflicting dmarc results", []string{"mx.google.com; dmarc=pass; dmarc=fail"}, false, true},
		{"method without result", []string{"mx.google.com; dmarc"}, false, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pass, found := DMARCFromGmail(c.headers)
			if pass != c.pass || found != c.found {
				t.Errorf("pass %v found %v, want pass %v found %v", pass, found, c.pass, c.found)
			}
		})
	}
}

func TestMalformedSender(t *testing.T) {
	none := authenticMail("alice@example.com")
	none.From = nil
	assertDecision(t, Mail(none, aliceRules, testNow), ActionStoreOnly, ReasonMalformedSender)

	two := authenticMail("alice@example.com")
	two.From = append(two.From, candidate.Address{Address: "alice@example.com"})
	assertDecision(t, Mail(two, aliceRules, testNow), ActionStoreOnly, ReasonMalformedSender)
}

func TestReplyToNeverMatchesAllowlist(t *testing.T) {
	m := authenticMail("mallory@evil.example")
	m.ReplyTo = []candidate.Address{{Name: "Alice", Address: "alice@example.com"}}
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)

	m.From = nil
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonMalformedSender)
}

func TestDisplayNameNeverMatchesAllowlist(t *testing.T) {
	m := authenticMail("mallory@evil.example")
	m.From[0].Name = "alice@example.com"
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
}

func TestTooOld(t *testing.T) {
	m := authenticMail("alice@example.com")
	m.InternalDate = testNow.Add(-FreshnessLimit - time.Second)
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonTooOld)

	m.InternalDate = testNow.Add(-FreshnessLimit)
	assertDecision(t, Mail(m, aliceRules, testNow), ActionPush, ReasonAllowed)
}

func TestMalformedSenderComesBeforeTooOld(t *testing.T) {
	m := authenticMail("alice@example.com")
	m.From = nil
	m.InternalDate = testNow.Add(-72 * time.Hour)
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonMalformedSender)
}

func TestTooOldComesBeforeAutomated(t *testing.T) {
	m := authenticMail("alice@example.com")
	m.HasListUnsubscribe = true
	m.InternalDate = testNow.Add(-72 * time.Hour)
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonTooOld)
}

func TestAutomated(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(m candidate.Mail) candidate.Mail
		action Action
		reason string
	}{
		{"auto-submitted auto-generated", func(m candidate.Mail) candidate.Mail { m.AutoSubmitted = "auto-generated"; return m }, ActionDrop, ReasonAutomated},
		{"auto-submitted with parameters", func(m candidate.Mail) candidate.Mail {
			m.AutoSubmitted = "auto-replied; owner-email=alice@example.com"
			return m
		}, ActionDrop, ReasonAutomated},
		{"auto-submitted no", func(m candidate.Mail) candidate.Mail { m.AutoSubmitted = "No"; return m }, ActionPush, ReasonAllowed},
		{"auto-submitted no with comment", func(m candidate.Mail) candidate.Mail { m.AutoSubmitted = " no (human) "; return m }, ActionPush, ReasonAllowed},
		{"precedence bulk", func(m candidate.Mail) candidate.Mail { m.Precedence = "bulk"; return m }, ActionDrop, ReasonAutomated},
		{"precedence list", func(m candidate.Mail) candidate.Mail { m.Precedence = "List"; return m }, ActionDrop, ReasonAutomated},
		{"precedence junk", func(m candidate.Mail) candidate.Mail { m.Precedence = " junk "; return m }, ActionDrop, ReasonAutomated},
		{"precedence first-class", func(m candidate.Mail) candidate.Mail { m.Precedence = "first-class"; return m }, ActionPush, ReasonAllowed},
		{"list-unsubscribe", func(m candidate.Mail) candidate.Mail { m.HasListUnsubscribe = true; return m }, ActionDrop, ReasonAutomated},
		{"list-id", func(m candidate.Mail) candidate.Mail { m.HasListID = true; return m }, ActionDrop, ReasonAutomated},
	}
	rules := []config.SenderRule{{Pattern: "@example.com", RequireDMARC: true}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertDecision(t, Mail(c.mutate(authenticMail("alice@example.com")), rules, testNow), c.action, c.reason)
		})
	}
}

func TestAutomatedLocalParts(t *testing.T) {
	rules := []config.SenderRule{{Pattern: "@example.com", RequireDMARC: true}}
	for _, local := range []string{"noreply", "no-reply", "NoReply", "notification", "notifications", "Mailer-Daemon"} {
		t.Run(local, func(t *testing.T) {
			assertDecision(t, Mail(authenticMail(local+"@example.com"), rules, testNow), ActionDrop, ReasonAutomated)
		})
	}
	for _, local := range []string{"alice", "noreplyer", "no_reply", "notification-team", "daemon"} {
		t.Run(local, func(t *testing.T) {
			assertDecision(t, Mail(authenticMail(local+"@example.com"), rules, testNow), ActionPush, ReasonAllowed)
		})
	}
}

func TestNewsletterFromAllowlistedSenderIsDroppedBeforeAllowlist(t *testing.T) {
	m := authenticMail("alice@example.com")
	m.HasListUnsubscribe = true
	assertDecision(t, Mail(m, aliceRules, testNow), ActionDrop, ReasonAutomated)
}

func TestAutomatedComesBeforeAllowlistForUnknownSender(t *testing.T) {
	assertDecision(t, Mail(authenticMail("noreply@unknown.example"), aliceRules, testNow), ActionDrop, ReasonAutomated)
}

func TestSenderNotAllowed(t *testing.T) {
	assertDecision(t, Mail(authenticMail("bob@example.com"), aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
	assertDecision(t, Mail(authenticMail("alice@example.com"), nil, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
}

func TestAllowlistComesBeforeDMARC(t *testing.T) {
	m := authenticMail("bob@example.com")
	m.AuthResults = nil
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
}

func TestExactAddressRule(t *testing.T) {
	assertDecision(t, Mail(authenticMail("alice@example.com"), aliceRules, testNow), ActionPush, ReasonAllowed)
	assertDecision(t, Mail(authenticMail("alice@example.com.evil.example"), aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
	assertDecision(t, Mail(authenticMail("malice@example.com"), aliceRules, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
}

func TestDomainRuleMatchesSubdomainOnlyWhenWritten(t *testing.T) {
	domain := []config.SenderRule{{Pattern: "@example.com", RequireDMARC: true}}
	assertDecision(t, Mail(authenticMail("bob@example.com"), domain, testNow), ActionPush, ReasonAllowed)
	assertDecision(t, Mail(authenticMail("bob@a.example.com"), domain, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
	assertDecision(t, Mail(authenticMail("bob@badexample.com"), domain, testNow), ActionStoreOnly, ReasonSenderNotAllowed)

	subdomain := []config.SenderRule{{Pattern: "@a.example.com", RequireDMARC: true}}
	assertDecision(t, Mail(authenticMail("bob@a.example.com"), subdomain, testNow), ActionPush, ReasonAllowed)
	assertDecision(t, Mail(authenticMail("bob@example.com"), subdomain, testNow), ActionStoreOnly, ReasonSenderNotAllowed)
}

func TestSenderUnauthenticated(t *testing.T) {
	m := authenticMail("alice@example.com")
	m.AuthResults = nil
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonSenderUnauthenticated)

	m.AuthResults = []string{"mx.google.com; dmarc=fail header.from=example.com"}
	assertDecision(t, Mail(m, aliceRules, testNow), ActionStoreOnly, ReasonSenderUnauthenticated)
}

func TestRequireDMARCFalseAdmitsWithoutAuth(t *testing.T) {
	rules := []config.SenderRule{{Pattern: "alice@example.com", RequireDMARC: false}}
	m := authenticMail("alice@example.com")
	m.AuthResults = nil
	assertDecision(t, Mail(m, rules, testNow), ActionPush, ReasonAllowed)

	m.AuthResults = []string{"mx.google.com; dmarc=fail header.from=example.com"}
	assertDecision(t, Mail(m, rules, testNow), ActionPush, ReasonAllowed)
}

func TestAnyMatchingRuleWithoutDMARCAdmits(t *testing.T) {
	rules := []config.SenderRule{
		{Pattern: "@example.com", RequireDMARC: true},
		{Pattern: "alice@example.com", RequireDMARC: false},
	}
	m := authenticMail("alice@example.com")
	m.AuthResults = nil
	assertDecision(t, Mail(m, rules, testNow), ActionPush, ReasonAllowed)

	other := authenticMail("bob@example.com")
	other.AuthResults = nil
	assertDecision(t, Mail(other, rules, testNow), ActionStoreOnly, ReasonSenderUnauthenticated)
}

func TestGitHub(t *testing.T) {
	notification := func(repo, reason string) candidate.GitHub {
		return candidate.GitHub{Repo: repo, Reason: reason}
	}
	reasons := []string{"mention", "review_requested"}
	allRepos := config.GitHubSource{Reasons: reasons}
	filtered := config.GitHubSource{Reasons: reasons, Repos: []string{"acme/api", "tools/*"}}
	cases := []struct {
		name   string
		n      candidate.GitHub
		src    config.GitHubSource
		action Action
		reason string
	}{
		{"kept reason, all repos", notification("anyone/anything", "mention"), allRepos, ActionPush, ReasonAllowed},
		{"reason not kept", notification("acme/api", "subscribed"), filtered, ActionStoreOnly, ReasonReasonNotKept},
		{"reason checked before repo", notification("other/repo", "subscribed"), filtered, ActionStoreOnly, ReasonReasonNotKept},
		{"exact repo", notification("acme/api", "review_requested"), filtered, ActionPush, ReasonAllowed},
		{"repo case-insensitive", notification("Acme/API", "mention"), filtered, ActionPush, ReasonAllowed},
		{"owner wildcard", notification("tools/lint", "mention"), filtered, ActionPush, ReasonAllowed},
		{"repo not kept", notification("acme/web", "mention"), filtered, ActionStoreOnly, ReasonRepoNotKept},
		{"owner prefix is not the owner", notification("toolsmith/lint", "mention"), filtered, ActionStoreOnly, ReasonRepoNotKept},
		{"wildcard needs a slash", notification("tools", "mention"), filtered, ActionStoreOnly, ReasonRepoNotKept},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertDecision(t, GitHub(c.n, c.src), c.action, c.reason)
		})
	}
}

func TestAnySenderRuleStillDropsAutomatedAndUnauthenticatedMail(t *testing.T) {
	rules := []config.SenderRule{{Pattern: config.AnySender, RequireDMARC: true}}
	now := time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	person := candidate.Mail{
		From:         []candidate.Address{{Name: "Bob", Address: "bob@unknown.example"}},
		InternalDate: now,
		AuthResults:  []string{"mx.google.com; dmarc=pass (p=NONE) header.from=unknown.example"},
	}
	if d := Mail(person, rules, now); d.Action != ActionPush {
		t.Errorf("person: %+v", d)
	}
	newsletter := person
	newsletter.HasListUnsubscribe = true
	if d := Mail(newsletter, rules, now); d.Action != ActionDrop || d.Reason != ReasonAutomated {
		t.Errorf("newsletter: %+v", d)
	}
	forged := person
	forged.AuthResults = []string{"mx.google.com; dmarc=fail header.from=unknown.example"}
	if d := Mail(forged, rules, now); d.Reason != ReasonSenderUnauthenticated {
		t.Errorf("forged: %+v", d)
	}
}
