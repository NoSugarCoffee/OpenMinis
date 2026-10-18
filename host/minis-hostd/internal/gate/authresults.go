package gate

import "strings"

const gmailAuthservID = "mx.google.com"

// DMARCFromGmail reads only the topmost Authentication-Results header that Gmail wrote. Gmail
// prepends its header on receipt, so any header below it, even one claiming to be mx.google.com,
// came from the sender and may be forged (RFC 8601 §5).
func DMARCFromGmail(authResults []string) (pass bool, found bool) {
	for _, header := range authResults {
		parts := splitOutsideQuotes(stripComments(header), ';')
		authservID := strings.Fields(parts[0])
		if len(authservID) == 0 || !strings.EqualFold(authservID[0], gmailAuthservID) {
			continue
		}
		return dmarcPassed(parts[1:]), true
	}
	return false, false
}

// dmarcPassed demands that every dmarc result passes, so a header with conflicting results fails.
func dmarcPassed(resinfos []string) bool {
	sawDMARC := false
	for _, resinfo := range resinfos {
		method, result, ok := methodResult(resinfo)
		if !ok {
			continue
		}
		name, _, _ := strings.Cut(method, "/")
		if !strings.EqualFold(name, "dmarc") {
			continue
		}
		if !strings.EqualFold(result, "pass") {
			return false
		}
		sawDMARC = true
	}
	return sawDMARC
}

// methodResult reads the leading "method[/version] = result" of a resinfo, ignoring the
// properties after it so that a value such as "smtp.mailfrom=dmarc=pass" is never a result.
func methodResult(resinfo string) (method string, result string, ok bool) {
	left, right, found := strings.Cut(resinfo, "=")
	method = strings.TrimSpace(left)
	if !found || method == "" || strings.ContainsAny(method, " \t\r\n") {
		return "", "", false
	}
	fields := strings.Fields(right)
	if len(fields) == 0 {
		return "", "", false
	}
	return method, fields[0], true
}

// stripComments removes RFC 5322 comments, which may nest and escape parentheses, while keeping
// quoted strings intact; Gmail's spf comment, for one, contains a ";".
func stripComments(value string) string {
	var out strings.Builder
	depth := 0
	inQuote := false
	escaped := false
	for _, r := range value {
		switch {
		case escaped:
			escaped = false
			if depth == 0 {
				out.WriteRune(r)
			}
		case r == '\\' && (inQuote || depth > 0):
			escaped = true
			if depth == 0 {
				out.WriteRune(r)
			}
		case inQuote:
			if r == '"' {
				inQuote = false
			}
			out.WriteRune(r)
		case r == '(':
			depth++
		case r == ')' && depth > 0:
			depth--
			if depth == 0 {
				out.WriteRune(' ')
			}
		case depth > 0:
		case r == '"':
			inQuote = true
			out.WriteRune(r)
		default:
			out.WriteRune(r)
		}
	}
	return out.String()
}

func splitOutsideQuotes(value string, separator rune) []string {
	var parts []string
	var current strings.Builder
	inQuote := false
	escaped := false
	for _, r := range value {
		switch {
		case escaped:
			escaped = false
		case inQuote && r == '\\':
			escaped = true
		case r == '"':
			inQuote = !inQuote
		case !inQuote && r == separator:
			parts = append(parts, current.String())
			current.Reset()
			continue
		}
		current.WriteRune(r)
	}
	return append(parts, current.String())
}
