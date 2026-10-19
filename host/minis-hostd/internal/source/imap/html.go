package imap

import (
	"html"
	"regexp"
	"strings"
)

var (
	invisibleElements = regexp.MustCompile(`(?is)<(script|style|head|title)\b[^>]*>.*?</(script|style|head|title)\s*>`)
	htmlComments      = regexp.MustCompile(`(?s)<!--.*?-->`)
	lineBreakTags     = regexp.MustCompile(`(?i)<\s*(br|/p|/div|/ul|/ol|/tr|/h[1-6]|/blockquote|/table|hr)\b[^>]*>`)
	listItemTags      = regexp.MustCompile(`(?i)<\s*li\b[^>]*>`)
	anyTag            = regexp.MustCompile(`(?s)<[^>]*>`)
	horizontalSpace   = regexp.MustCompile(`[ \t\f\v\x{00A0}]+`)
	blankLines        = regexp.MustCompile(`\n{3,}`)
)

// htmlToText is deliberately crude: the text only has to be readable in a notification and an
// event view, and a full HTML renderer is not worth a dependency.
func htmlToText(source string) string {
	text := invisibleElements.ReplaceAllString(source, "")
	text = htmlComments.ReplaceAllString(text, "")
	text = strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(text)
	text = lineBreakTags.ReplaceAllString(text, "\n")
	text = listItemTags.ReplaceAllString(text, "\n• ")
	text = anyTag.ReplaceAllString(text, "")
	text = html.UnescapeString(text)
	text = horizontalSpace.ReplaceAllString(text, " ")
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimSpace(line)
	}
	text = blankLines.ReplaceAllString(strings.Join(lines, "\n"), "\n\n")
	return strings.TrimSpace(text)
}
