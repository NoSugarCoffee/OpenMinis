package imap

import (
	"testing"
	"time"
)

func TestPlan(t *testing.T) {
	stored := &Cursor{UIDValidity: 7, LastSeenUID: 40}
	cases := []struct {
		name      string
		stored    *Cursor
		validity  uint32
		next      uint32
		fetchFrom uint32
		cursor    Cursor
		reset     bool
	}{
		{"first run baselines at UIDNEXT-1", nil, 7, 51, 0, Cursor{7, 50}, false},
		{"same UIDVALIDITY resumes", stored, 7, 51, 41, Cursor{7, 40}, false},
		{"nothing new still resumes", stored, 7, 41, 41, Cursor{7, 40}, false},
		{"changed UIDVALIDITY rebaselines", stored, 9, 3, 0, Cursor{9, 2}, true},
		{"empty mailbox baselines at 0", nil, 7, 1, 0, Cursor{7, 0}, false},
	}
	for _, c := range cases {
		fetchFrom, cursor, reset := Plan(c.stored, c.validity, c.next)
		if fetchFrom != c.fetchFrom || cursor != c.cursor || reset != c.reset {
			t.Errorf("%s: got (%d, %+v, %v)", c.name, fetchFrom, cursor, reset)
		}
	}
}

func TestCursorRoundTrip(t *testing.T) {
	c := Cursor{UIDValidity: 4000000000, LastSeenUID: 12}
	if encoded := c.Encode(); encoded != `{"uidValidity":4000000000,"lastSeenUid":12}` {
		t.Errorf("encoded %s", encoded)
	}
	decoded, err := DecodeCursor(c.Encode())
	if err != nil || decoded != c {
		t.Errorf("decoded %+v %v", decoded, err)
	}
}

func TestDecodeCursorRejectsOtherValues(t *testing.T) {
	for _, value := range []string{"", "uid-10", `{"uidValidity":1}`, `{"uidValidity":1,"lastSeenUid":2,"x":3}`, `{"uidValidity":-1,"lastSeenUid":2}`} {
		if _, err := DecodeCursor(value); err == nil {
			t.Errorf("decoded %q", value)
		}
	}
}

func TestBackoffDoublesToTheMaximum(t *testing.T) {
	timing := ProductionTiming()
	var got []time.Duration
	backoff := time.Duration(0)
	for range 9 {
		backoff = NextBackoff(backoff, timing)
		got = append(got, backoff)
	}
	want := []time.Duration{5, 10, 20, 40, 80, 160, 300, 300, 300}
	for i := range want {
		if got[i] != want[i]*time.Second {
			t.Fatalf("backoff %v", got)
		}
	}
}
