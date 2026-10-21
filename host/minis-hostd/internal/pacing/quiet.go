package pacing

import (
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
)

func minuteOfDay(t time.Time) int { return t.Hour()*60 + t.Minute() }

// InQuietHours compares wall-clock minutes in loc, so the window keeps its local times across DST
// changes; Start > End wraps past midnight.
func InQuietHours(now time.Time, w config.Window, loc *time.Location) bool {
	m := minuteOfDay(now.In(loc))
	if w.Start < w.End {
		return m >= w.Start && m < w.End
	}
	return m >= w.Start || m < w.End
}

// NextWindowEnd is the first local End strictly after now. Days are stepped with time.Date rather
// than by adding 24h, which would drift by an hour across a DST change. An End that falls in a
// spring-forward gap is normalised by time.Date to the equivalent instant after the jump.
func NextWindowEnd(now time.Time, w config.Window, loc *time.Location) time.Time {
	local := now.In(loc)
	for dayOffset := 0; ; dayOffset++ {
		end := time.Date(local.Year(), local.Month(), local.Day()+dayOffset, w.End/60, w.End%60, 0, 0, loc)
		if end.After(now) {
			return end
		}
	}
}
