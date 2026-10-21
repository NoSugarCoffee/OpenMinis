// Package github polls the GitHub notifications API and turns unread threads into candidates.
// It only ever sends GET: hostd must never change the user's notification state.
package github

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/candidate"
)

var (
	// ErrUnauthorized covers 401 and any 403 that is not a rate limit; GitHub's message is wrapped.
	ErrUnauthorized = errors.New("github rejected the token")
	ErrRateLimited  = errors.New("github rate limit reached")
)

const (
	notificationsQuery = "all=false&per_page=50"
	apiVersion         = "2022-11-28"
	errorBodyLimit     = 4 << 10
)

type APISubject struct {
	Title string `json:"title"`
	URL   string `json:"url"` // empty when GitHub sends null, as it often does for CheckSuite
	Type  string `json:"type"`
}

type APIRepository struct {
	FullName string `json:"full_name"`
	HTMLURL  string `json:"html_url"`
}

type APINotification struct {
	ID         string        `json:"id"`
	Reason     string        `json:"reason"`
	UpdatedAt  string        `json:"updated_at"`
	Subject    APISubject    `json:"subject"`
	Repository APIRepository `json:"repository"`
}

// DefaultBaseURL is api.github.com; a GitHub Enterprise host would pass its own API root.
const DefaultBaseURL = "https://api.github.com"

type Source struct {
	Token   string
	BaseURL string
	Client  *http.Client
}

// PollResult always carries Status and the rate-limit headers, even alongside an error, so the
// caller can hand them to NextPoll.
type PollResult struct {
	Candidates    []candidate.GitHub
	LastModified  string // empty on 304: keep the stored cursor
	PollInterval  string
	RateRemaining string
	RateReset     string
	Status        int
	NotModified   bool
}

func ToCandidate(n APINotification) (candidate.GitHub, error) {
	if n.ID == "" {
		return candidate.GitHub{}, errors.New("github notification has no id")
	}
	if n.Repository.FullName == "" {
		return candidate.GitHub{}, fmt.Errorf("github notification %s has no repository full_name", n.ID)
	}
	updatedAt, err := time.Parse(time.RFC3339, n.UpdatedAt)
	if err != nil {
		return candidate.GitHub{}, fmt.Errorf("github notification %s: updated_at: %w", n.ID, err)
	}
	return candidate.GitHub{
		// The raw updated_at string, not a re-formatted time, keeps keys stable across releases.
		Key:          "gh:" + n.ID + ":" + n.UpdatedAt,
		ThreadID:     n.ID,
		Repo:         n.Repository.FullName,
		Reason:       n.Reason,
		SubjectType:  n.Subject.Type,
		SubjectTitle: n.Subject.Title,
		HTMLURL:      HTMLURL(n.Subject.Type, n.Subject.URL, n.Repository.HTMLURL),
		UpdatedAt:    updatedAt,
	}, nil
}

// HTMLURL derives the browser URL from the subject's API URL. The token has no repository access,
// so the subject itself is never fetched; anything that cannot be derived falls to the repo page.
func HTMLURL(subjectType, apiURL, repoHTMLURL string) string {
	webSegment, ok := map[string]struct{ api, web string }{
		"PullRequest": {"pulls", "pull"},
		"Issue":       {"issues", "issues"},
		"Commit":      {"commits", "commit"},
	}[subjectType]
	if !ok || apiURL == "" {
		return repoHTMLURL
	}
	parsed, err := url.Parse(apiURL)
	if err != nil {
		return repoHTMLURL
	}
	segments := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(segments) < 2 {
		return repoHTMLURL
	}
	kind, id := segments[len(segments)-2], segments[len(segments)-1]
	if kind != webSegment.api || id == "" {
		return repoHTMLURL
	}
	return strings.TrimSuffix(repoHTMLURL, "/") + "/" + webSegment.web + "/" + url.PathEscape(id)
}

// Poll fetches every page of unread notifications. ifModifiedSince is the Last-Modified of the
// previous successful poll, or empty on the first one.
func (s *Source) Poll(ctx context.Context, ifModifiedSince string) (PollResult, error) {
	if s.Client == nil {
		return PollResult{}, errors.New("github source has no HTTP client")
	}
	base, err := url.Parse(strings.TrimSuffix(s.BaseURL, "/") + "/notifications?" + notificationsQuery)
	if err != nil {
		return PollResult{}, fmt.Errorf("github base URL %q: %w", s.BaseURL, err)
	}

	var result PollResult
	pageURL := base
	cursor := ifModifiedSince
	for first := true; pageURL != nil; first = false {
		page, err := s.getPage(ctx, pageURL, cursor)
		result.Status = page.status
		result.RateRemaining = page.header.Get("X-RateLimit-Remaining")
		result.RateReset = page.header.Get("X-RateLimit-Reset")
		if first {
			result.PollInterval = page.header.Get("X-Poll-Interval")
		}
		if err != nil {
			return result, err
		}
		if page.status == http.StatusNotModified {
			result.NotModified = true
			return result, nil
		}
		if first {
			result.LastModified = page.header.Get("Last-Modified")
		}
		for _, n := range page.notifications {
			c, err := ToCandidate(n)
			if err != nil {
				return result, err
			}
			result.Candidates = append(result.Candidates, c)
		}
		pageURL, err = nextPage(base, page.header.Get("Link"))
		if err != nil {
			return result, err
		}
		// Later pages belong to the same snapshot as the first; a conditional header there could
		// only make GitHub answer 304 mid-listing.
		cursor = ""
	}
	return result, nil
}

type page struct {
	status        int
	header        http.Header
	notifications []APINotification
}

func (s *Source) getPage(ctx context.Context, pageURL *url.URL, ifModifiedSince string) (page, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pageURL.String(), nil)
	if err != nil {
		return page{}, fmt.Errorf("github request %s: %w", pageURL.Redacted(), err)
	}
	req.Header.Set("Authorization", "Bearer "+s.Token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)
	if ifModifiedSince != "" {
		req.Header.Set("If-Modified-Since", ifModifiedSince)
	}
	resp, err := s.Client.Do(req)
	if err != nil {
		return page{}, fmt.Errorf("github GET %s: %w", pageURL.Redacted(), err)
	}
	defer resp.Body.Close()

	got := page{status: resp.StatusCode, header: resp.Header}
	switch {
	case resp.StatusCode == http.StatusOK:
		if err := json.NewDecoder(resp.Body).Decode(&got.notifications); err != nil {
			return got, fmt.Errorf("github GET %s: decode notifications: %w", pageURL.Redacted(), err)
		}
		return got, nil
	case resp.StatusCode == http.StatusNotModified:
		return got, nil
	case resp.StatusCode == http.StatusTooManyRequests || isRateLimited(resp.StatusCode, resp.Header.Get("X-RateLimit-Remaining")):
		return got, fmt.Errorf("%w: %d: %s", ErrRateLimited, resp.StatusCode, errorMessage(resp.Body))
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return got, fmt.Errorf("%w: %d: %s", ErrUnauthorized, resp.StatusCode, errorMessage(resp.Body))
	default:
		return got, fmt.Errorf("github GET %s: unexpected status %d: %s", pageURL.Redacted(), resp.StatusCode, errorMessage(resp.Body))
	}
}

func errorMessage(body io.Reader) string {
	raw, err := io.ReadAll(io.LimitReader(body, errorBodyLimit))
	if err != nil {
		return fmt.Sprintf("(reading response body failed: %v)", err)
	}
	var parsed struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &parsed) == nil && parsed.Message != "" {
		return parsed.Message
	}
	return strings.TrimSpace(string(raw))
}

// nextPage returns the rel="next" target, or nil when there is none. A target off the API host is
// refused because following it would send the token elsewhere.
func nextPage(base *url.URL, link string) (*url.URL, error) {
	for part := range strings.SplitSeq(link, ",") {
		target, params, found := strings.Cut(strings.TrimSpace(part), ";")
		if !found || !hasRelNext(params) {
			continue
		}
		next, err := url.Parse(strings.Trim(strings.TrimSpace(target), "<>"))
		if err != nil {
			return nil, fmt.Errorf("github Link header next %q: %w", target, err)
		}
		next = base.ResolveReference(next)
		if next.Scheme != base.Scheme || next.Host != base.Host {
			return nil, fmt.Errorf("github Link header points next page off %s: %s", base.Host, next.Redacted())
		}
		return next, nil
	}
	return nil, nil
}

func hasRelNext(params string) bool {
	for param := range strings.SplitSeq(params, ";") {
		key, value, _ := strings.Cut(strings.TrimSpace(param), "=")
		if strings.EqualFold(key, "rel") && slices.Contains(strings.Fields(strings.Trim(value, `"`)), "next") {
			return true
		}
	}
	return false
}
