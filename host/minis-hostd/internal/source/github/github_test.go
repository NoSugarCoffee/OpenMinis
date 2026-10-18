package github

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testToken = "ghp_testtoken"

func fixture(t *testing.T, name string) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "github", name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func fixtureList(t *testing.T, names ...string) []byte {
	t.Helper()
	items := make([]json.RawMessage, 0, len(names))
	for _, name := range names {
		items = append(items, fixture(t, name))
	}
	data, err := json.Marshal(items)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func decodeFixture(t *testing.T, name string) APINotification {
	t.Helper()
	var n APINotification
	if err := json.Unmarshal(fixture(t, name), &n); err != nil {
		t.Fatal(err)
	}
	return n
}

// newGitHub starts a stand-in for api.github.com that fails the test on anything but an
// authenticated GET, since hostd must never mutate a source.
func newGitHub(t *testing.T, handler http.HandlerFunc) (*Source, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("unexpected %s %s", r.Method, r.URL)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+testToken {
			t.Errorf("Authorization = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/vnd.github+json" {
			t.Errorf("Accept = %q", got)
		}
		if got := r.Header.Get("X-GitHub-Api-Version"); got != "2022-11-28" {
			t.Errorf("X-GitHub-Api-Version = %q", got)
		}
		handler(w, r)
	}))
	t.Cleanup(srv.Close)
	return &Source{Token: testToken, BaseURL: srv.URL, Client: srv.Client()}, srv
}

func TestPollSendsIfModifiedSinceAndQuery(t *testing.T) {
	const stored = "Sat, 18 Oct 2026 09:00:00 GMT"
	src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/notifications" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("If-Modified-Since"); got != stored {
			t.Errorf("If-Modified-Since = %q, want %q", got, stored)
		}
		q := r.URL.Query()
		if q.Get("all") != "false" || q.Get("per_page") != "50" {
			t.Errorf("query = %q", r.URL.RawQuery)
		}
		w.Header().Set("Last-Modified", "Sat, 18 Oct 2026 10:00:00 GMT")
		w.Header().Set("X-Poll-Interval", "60")
		w.Header().Set("X-RateLimit-Remaining", "4998")
		w.Header().Set("X-RateLimit-Reset", "1792320000")
		_, _ = w.Write(fixtureList(t, "mention", "ci_activity"))
	})
	res, err := src.Poll(context.Background(), stored)
	if err != nil {
		t.Fatal(err)
	}
	if res.NotModified || len(res.Candidates) != 2 {
		t.Fatalf("NotModified %v, %d candidates", res.NotModified, len(res.Candidates))
	}
	if res.LastModified != "Sat, 18 Oct 2026 10:00:00 GMT" || res.PollInterval != "60" {
		t.Errorf("LastModified %q PollInterval %q", res.LastModified, res.PollInterval)
	}
	if res.RateRemaining != "4998" || res.RateReset != "1792320000" || res.Status != http.StatusOK {
		t.Errorf("rate %q/%q status %d", res.RateRemaining, res.RateReset, res.Status)
	}
}

func TestPollWithoutCursorSendsNoIfModifiedSince(t *testing.T) {
	src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if _, ok := r.Header["If-Modified-Since"]; ok {
			t.Errorf("If-Modified-Since sent on first poll: %q", r.Header.Get("If-Modified-Since"))
		}
		_, _ = w.Write([]byte("[]"))
	})
	res, err := src.Poll(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Candidates) != 0 {
		t.Errorf("%d candidates", len(res.Candidates))
	}
}

func TestPollNotModified(t *testing.T) {
	src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Poll-Interval", "120")
		w.WriteHeader(http.StatusNotModified)
	})
	res, err := src.Poll(context.Background(), "Sat, 18 Oct 2026 10:00:00 GMT")
	if err != nil {
		t.Fatal(err)
	}
	if !res.NotModified || len(res.Candidates) != 0 || res.Status != http.StatusNotModified {
		t.Errorf("NotModified %v, %d candidates, status %d", res.NotModified, len(res.Candidates), res.Status)
	}
	if res.PollInterval != "120" {
		t.Errorf("PollInterval %q", res.PollInterval)
	}
	if res.LastModified != "" {
		t.Errorf("LastModified %q, want empty so the stored cursor stays", res.LastModified)
	}
}

func TestPollRateLimited(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusTooManyRequests} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			reset := now.Add(10 * time.Minute)
			src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-RateLimit-Remaining", "0")
				w.Header().Set("X-RateLimit-Reset", fmt.Sprint(reset.Unix()))
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"message":"API rate limit exceeded for user ID 41234567.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}`))
			})
			res, err := src.Poll(context.Background(), "")
			if !errors.Is(err, ErrRateLimited) || errors.Is(err, ErrUnauthorized) {
				t.Fatalf("err = %v", err)
			}
			got := NextPoll(now, res.PollInterval, res.Status, res.RateRemaining, res.RateReset)
			if !got.Equal(reset) {
				t.Errorf("next poll %v, want reset %v", got, reset)
			}
		})
	}
}

func TestPollUnauthorizedCarriesGitHubMessage(t *testing.T) {
	cases := []struct {
		status  int
		body    string
		message string
	}{
		{http.StatusUnauthorized, `{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}`, "Bad credentials"},
		{http.StatusForbidden, `{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/activity/notifications"}`, "Resource not accessible by personal access token"},
	}
	for _, c := range cases {
		t.Run(http.StatusText(c.status), func(t *testing.T) {
			src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("X-RateLimit-Remaining", "4999")
				w.WriteHeader(c.status)
				_, _ = w.Write([]byte(c.body))
			})
			res, err := src.Poll(context.Background(), "")
			if !errors.Is(err, ErrUnauthorized) {
				t.Fatalf("err = %v", err)
			}
			if !strings.Contains(err.Error(), c.message) {
				t.Errorf("err %q lacks %q", err, c.message)
			}
			if res.Status != c.status {
				t.Errorf("status %d", res.Status)
			}
		})
	}
}

func TestPollServerErrorIsPlainError(t *testing.T) {
	src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(`{"message":"Server Error"}`))
	})
	res, err := src.Poll(context.Background(), "")
	if err == nil || errors.Is(err, ErrUnauthorized) || errors.Is(err, ErrRateLimited) {
		t.Fatalf("err = %v", err)
	}
	if res.Status != http.StatusBadGateway {
		t.Errorf("status %d", res.Status)
	}
}

func TestPollFollowsNextLink(t *testing.T) {
	var pages []string
	var srvURL string
	src, srv := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		page := r.URL.Query().Get("page")
		pages = append(pages, page)
		switch page {
		case "":
			w.Header().Set("Last-Modified", "Sat, 18 Oct 2026 14:30:00 GMT")
			w.Header().Set("X-Poll-Interval", "60")
			w.Header().Set("Link", fmt.Sprintf(`<%s/notifications?all=false&per_page=50&page=2>; rel="next", <%s/notifications?all=false&per_page=50&page=3>; rel="last"`, srvURL, srvURL))
			_, _ = w.Write(fixtureList(t, "mention", "review_requested"))
		case "2":
			if _, ok := r.Header["If-Modified-Since"]; ok {
				t.Errorf("If-Modified-Since sent on a later page")
			}
			w.Header().Set("Link", fmt.Sprintf(`<%s/notifications?all=false&per_page=50&page=1>; rel="prev", <%s/notifications?all=false&per_page=50&page=3>; rel="next"`, srvURL, srvURL))
			_, _ = w.Write(fixtureList(t, "assign", "ci_activity"))
		case "3":
			w.Header().Set("X-RateLimit-Remaining", "4990")
			_, _ = w.Write(fixtureList(t, "author", "state_change"))
		default:
			t.Errorf("unexpected page %q", page)
		}
	})
	srvURL = srv.URL
	res, err := src.Poll(context.Background(), "Sat, 18 Oct 2026 09:00:00 GMT")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(pages, ",") != ",2,3" {
		t.Errorf("pages fetched %q", pages)
	}
	wantIDs := []string{"11738195213", "11738201877", "11738210450", "11738222019", "11738230002", "11738240317"}
	if len(res.Candidates) != len(wantIDs) {
		t.Fatalf("%d candidates", len(res.Candidates))
	}
	for i, id := range wantIDs {
		if res.Candidates[i].ThreadID != id {
			t.Errorf("candidate %d thread %q, want %q", i, res.Candidates[i].ThreadID, id)
		}
	}
	if res.LastModified != "Sat, 18 Oct 2026 14:30:00 GMT" || res.PollInterval != "60" {
		t.Errorf("LastModified %q PollInterval %q come from the first page", res.LastModified, res.PollInterval)
	}
	if res.RateRemaining != "4990" {
		t.Errorf("RateRemaining %q comes from the last page", res.RateRemaining)
	}
}

func TestPollRefusesNextLinkToAnotherHost(t *testing.T) {
	src, _ := newGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Link", `<https://attacker.example/notifications?page=2>; rel="next"`)
		_, _ = w.Write(fixtureList(t, "mention"))
	})
	if _, err := src.Poll(context.Background(), ""); err == nil {
		t.Fatal("followed a next link off the API host")
	}
}

func TestToCandidate(t *testing.T) {
	cases := []struct {
		fixture string
		key     string
		repo    string
		reason  string
		subject string
		title   string
		htmlURL string
	}{
		{"mention", "gh:11738195213:2026-10-18T09:14:02Z", "NoSugarCoffee/OpenMinis", "mention", "PullRequest", "Retry Bark push on 5xx with backoff", "https://github.com/NoSugarCoffee/OpenMinis/pull/42"},
		{"review_requested", "gh:11738201877:2026-10-18T10:02:45Z", "NoSugarCoffee/OpenMinis", "review_requested", "PullRequest", "hostd: add candidate types shared by sources and the gate", "https://github.com/NoSugarCoffee/OpenMinis/pull/9"},
		{"assign", "gh:11738210450:2026-10-18T11:30:00Z", "acme/infra", "assign", "Issue", "IMAP reconnect loops when the app password is revoked", "https://github.com/acme/infra/issues/317"},
		{"ci_activity", "gh:11738222019:2026-10-18T12:05:31Z", "NoSugarCoffee/OpenMinis", "ci_activity", "CheckSuite", "CI workflow run failed for feat/hostd-github branch", "https://github.com/NoSugarCoffee/OpenMinis"},
		{"author", "gh:11738230002:2026-10-18T13:47:19Z", "NoSugarCoffee/OpenMinis", "author", "Commit", "docs(remote): record spike S4, calling minis-hostd over SSH", "https://github.com/NoSugarCoffee/OpenMinis/commit/019e9e4c2a7f1b3d5e6f708192a3b4c5d6e7f809"},
		{"state_change", "gh:11738240317:2026-10-18T14:20:08Z", "acme/infra", "state_change", "Issue", "Quiet hours ignore DST transitions", "https://github.com/acme/infra/issues/298"},
		{"release", "gh:11738250990:2026-10-18T15:00:00Z", "BurntSushi/toml", "subscribed", "Release", "v1.6.0", "https://github.com/BurntSushi/toml"},
	}
	for _, c := range cases {
		t.Run(c.fixture, func(t *testing.T) {
			n := decodeFixture(t, c.fixture)
			got, err := ToCandidate(n)
			if err != nil {
				t.Fatal(err)
			}
			if got.Key != c.key || got.ThreadID != n.ID || got.Repo != c.repo || got.Reason != c.reason {
				t.Errorf("key %q thread %q repo %q reason %q", got.Key, got.ThreadID, got.Repo, got.Reason)
			}
			if got.SubjectType != c.subject || got.SubjectTitle != c.title || got.HTMLURL != c.htmlURL {
				t.Errorf("subject %q title %q url %q", got.SubjectType, got.SubjectTitle, got.HTMLURL)
			}
			want, _ := time.Parse(time.RFC3339, n.UpdatedAt)
			if !got.UpdatedAt.Equal(want) {
				t.Errorf("UpdatedAt %v, want %v", got.UpdatedAt, want)
			}
		})
	}
}

func TestToCandidateRejectsIncompleteNotifications(t *testing.T) {
	base := decodeFixture(t, "mention")
	noID := base
	noID.ID = ""
	badTime := base
	badTime.UpdatedAt = "yesterday"
	noRepo := base
	noRepo.Repository.FullName = ""
	for name, n := range map[string]APINotification{"no id": noID, "bad updated_at": badTime, "no repo": noRepo} {
		t.Run(name, func(t *testing.T) {
			if _, err := ToCandidate(n); err == nil {
				t.Error("accepted")
			}
		})
	}
}

func TestHTMLURL(t *testing.T) {
	const repo = "https://github.com/o/r"
	cases := []struct {
		subjectType string
		apiURL      string
		want        string
	}{
		{"PullRequest", "https://api.github.com/repos/o/r/pulls/42", "https://github.com/o/r/pull/42"},
		{"Issue", "https://api.github.com/repos/o/r/issues/7", "https://github.com/o/r/issues/7"},
		{"Commit", "https://api.github.com/repos/o/r/commits/abc123", "https://github.com/o/r/commit/abc123"},
		{"Release", "https://api.github.com/repos/o/r/releases/99", repo},
		{"CheckSuite", "", repo},
		{"Discussion", "", repo},
		{"RepositoryVulnerabilityAlert", "https://api.github.com/repos/o/r/vulnerability-alerts/3", repo},
		{"PullRequest", "https://api.github.com/repos/o/r/issues/42", repo},
		{"PullRequest", "not a url \x7f", repo},
		{"Issue", "https://api.github.com/repos/o/r/issues/", repo},
	}
	for _, c := range cases {
		t.Run(c.subjectType+" "+c.apiURL, func(t *testing.T) {
			if got := HTMLURL(c.subjectType, c.apiURL, repo); got != c.want {
				t.Errorf("HTMLURL = %q, want %q", got, c.want)
			}
		})
	}
}
