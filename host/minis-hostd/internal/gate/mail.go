package gate

import (
	"regexp"
	"strings"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

// FreshnessLimit keeps a long outage or a reconcile from pushing stale mail.
const FreshnessLimit = 48 * time.Hour

// automatedLocalPart is anchored so a person whose address merely contains "noreply" or
// "notification" is not silently dropped; headers catch most automated mail anyway.
var automatedLocalPart = regexp.MustCompile(`(?i)^(no-?reply|notifications?|mailer-daemon)$`)

// Mail applies spec §5.1 in its exact order; the order decides which reason a message records.
func Mail(m candidate.Mail, rules []config.SenderRule, now time.Time) Decision {
	if len(m.From) != 1 {
		return Decision{Action: ActionStoreOnly, Reason: ReasonMalformedSender}
	}
	from := m.From[0].Address
	if now.Sub(m.InternalDate) > FreshnessLimit {
		return Decision{Action: ActionStoreOnly, Reason: ReasonTooOld}
	}
	if isAutomated(m, from) {
		return Decision{Action: ActionDrop, Reason: ReasonAutomated}
	}
	matching := matchingRules(from, rules)
	if len(matching) == 0 {
		return Decision{Action: ActionStoreOnly, Reason: ReasonSenderNotAllowed}
	}
	if requiresDMARC(matching) {
		if pass, _ := DMARCFromGmail(m.AuthResults); !pass {
			return Decision{Action: ActionStoreOnly, Reason: ReasonSenderUnauthenticated}
		}
	}
	return Decision{Action: ActionPush, Reason: ReasonAllowed}
}

func isAutomated(m candidate.Mail, from string) bool {
	autoSubmitted := headerKeyword(m.AutoSubmitted)
	if autoSubmitted != "" && autoSubmitted != "no" {
		return true
	}
	switch headerKeyword(m.Precedence) {
	case "bulk", "list", "junk":
		return true
	}
	if m.HasListUnsubscribe || m.HasListID {
		return true
	}
	local, _ := splitAddress(from)
	return automatedLocalPart.MatchString(local)
}

// headerKeyword drops comments and parameters such as Auto-Submitted's "; owner-email=...".
func headerKeyword(value string) string {
	keyword, _, _ := strings.Cut(stripComments(value), ";")
	return strings.ToLower(strings.TrimSpace(keyword))
}

func matchingRules(address string, rules []config.SenderRule) []config.SenderRule {
	_, domain := splitAddress(address)
	var matching []config.SenderRule
	for _, rule := range rules {
		if rule.Pattern == config.AnySender || rule.Pattern == address || (domain != "" && rule.Pattern == "@"+domain) {
			matching = append(matching, rule)
		}
	}
	return matching
}

// requiresDMARC lets any one matching rule with require_dmarc = false admit the sender, because
// that rule was written for exactly this sender's inability to pass DMARC.
func requiresDMARC(matching []config.SenderRule) bool {
	for _, rule := range matching {
		if !rule.RequireDMARC {
			return false
		}
	}
	return true
}

// splitAddress splits at the last "@" because a quoted local part may itself contain one.
func splitAddress(address string) (local string, domain string) {
	at := strings.LastIndex(address, "@")
	if at < 0 {
		return address, ""
	}
	return address[:at], address[at+1:]
}
