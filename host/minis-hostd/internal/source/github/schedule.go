package github

import (
	"net/http"
	"strconv"
	"time"
)

const (
	minPollInterval    = 60 * time.Second
	loginFailureRetry  = 30 * time.Minute
	rateLimitExhausted = "0"
)

// NextPoll says when to poll again after a response with the given status and headers.
func NextPoll(now time.Time, pollIntervalHeader string, status int, rateRemaining string, rateReset string) time.Time {
	if isRateLimited(status, rateRemaining) {
		resetSeconds, err := strconv.ParseInt(rateReset, 10, 64)
		reset := time.Unix(resetSeconds, 0)
		// A reset that is unreadable or already past would otherwise poll in a tight loop.
		if err != nil || !reset.After(now) {
			return now.Add(minPollInterval)
		}
		return reset
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return now.Add(loginFailureRetry)
	}
	return now.Add(pollInterval(pollIntervalHeader))
}

func isRateLimited(status int, rateRemaining string) bool {
	return (status == http.StatusForbidden || status == http.StatusTooManyRequests) && rateRemaining == rateLimitExhausted
}

func pollInterval(header string) time.Duration {
	seconds, err := strconv.Atoi(header)
	if err != nil {
		return minPollInterval
	}
	return max(time.Duration(seconds)*time.Second, minPollInterval)
}
