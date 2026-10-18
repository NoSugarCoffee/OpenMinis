package github

import (
	"net/http"
	"strconv"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)

func TestNextPoll(t *testing.T) {
	reset := now.Add(17 * time.Minute)
	resetHeader := strconv.FormatInt(reset.Unix(), 10)
	cases := []struct {
		name          string
		interval      string
		status        int
		rateRemaining string
		rateReset     string
		want          time.Time
	}{
		{"interval above the floor is used", "120", http.StatusOK, "4999", resetHeader, now.Add(120 * time.Second)},
		{"interval below the floor is raised to 60 s", "30", http.StatusOK, "4999", resetHeader, now.Add(60 * time.Second)},
		{"garbage interval falls to 60 s", "soon", http.StatusOK, "4999", resetHeader, now.Add(60 * time.Second)},
		{"missing interval falls to 60 s", "", http.StatusOK, "", "", now.Add(60 * time.Second)},
		{"not modified keeps the interval", "90", http.StatusNotModified, "", "", now.Add(90 * time.Second)},
		{"403 rate limit waits until reset", "60", http.StatusForbidden, "0", resetHeader, reset},
		{"429 rate limit waits until reset", "60", http.StatusTooManyRequests, "0", resetHeader, reset},
		{"rate limit with a reset in the past waits the floor", "60", http.StatusForbidden, "0", strconv.FormatInt(now.Add(-time.Minute).Unix(), 10), now.Add(60 * time.Second)},
		{"rate limit with garbage reset waits the floor", "60", http.StatusForbidden, "0", "later", now.Add(60 * time.Second)},
		{"401 retries after 30 min", "60", http.StatusUnauthorized, "4999", resetHeader, now.Add(30 * time.Minute)},
		{"403 without rate limit retries after 30 min", "60", http.StatusForbidden, "4999", resetHeader, now.Add(30 * time.Minute)},
		{"server error keeps the interval", "60", http.StatusBadGateway, "", "", now.Add(60 * time.Second)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := NextPoll(now, c.interval, c.status, c.rateRemaining, c.rateReset)
			if !got.Equal(c.want) {
				t.Errorf("NextPoll = %v, want %v", got, c.want)
			}
		})
	}
}
