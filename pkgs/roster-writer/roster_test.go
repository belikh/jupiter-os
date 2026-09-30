package main

// roster_test.go — fixture-driven parity tests (pure; no network/DB).

import (
	"testing"
	"time"
)

const fixtureICS = `BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260930T173000Z
DTEND:20261001T030000Z
SUMMARY:Shift [9:30]
DESCRIPTION:ISS/S/4/1/00221-BRISBANE AIRPORT/QSCRNPT/2550/APO\nSecond line ignored
END:VEVENT
BEGIN:VEVENT
DTSTART:20261001T173000Z
DTEND:20261002T030000Z
SUMMARY:Shift
END:VEVENT
BEGIN:VEVENT
DTSTART:20261004T220000Z
DTEND:20261005T060000Z
SUMMARY:Annual Leave
END:VEVENT
BEGIN:VEVENT
DTSTART:20261006T173000Z
DTEND:20261007T030000Z
SUMMARY:RDO
END:VEVENT
END:VCALENDAR`

func TestParseRosterParity(t *testing.T) {
	rows := parseRoster(fixtureICS)
	if len(rows) != 4 {
		t.Fatalf("want 4 rows, got %d", len(rows))
	}
	// 2026-09-30T17:30Z → Brisbane 2026-10-01 03:30
	r := rows["2026-10-01"]
	if r.Category != "shift" || r.StartLoc != "03:30" || r.EndLoc != "13:00" {
		t.Fatalf("row1: %+v", r)
	}
	if r.Hours != 9.5 || r.PaidHours != 9.5 {
		t.Fatalf("row1 hours: %+v", r)
	}
	if r.Location != "ISS/S/4/1/00221-BRISBANE AIRPORT/QSCRNPT/2550/APO" {
		t.Fatalf("row1 location: %q", r.Location)
	}
	if got := dayName(r.Date); got != "Thu" {
		t.Fatalf("day: %s", got)
	}
	// leave row: paid_leave with span hours (8h)
	l := rows["2026-10-05"]
	if l.Category != "paid_leave" || l.PaidHours != 8 {
		t.Fatalf("leave: %+v", l)
	}
	// RDO: contains "rdo" → paid_leave, no bracket → span hours
	d := rows["2026-10-07"]
	if d.Category != "paid_leave" {
		t.Fatalf("rdo: %+v", d)
	}
}

func TestShiftOverridesNonShift(t *testing.T) {
	ics := `BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260930T230000Z
DTEND:20261001T070000Z
SUMMARY:Annual Leave
END:VEVENT
BEGIN:VEVENT
DTSTART:20260930T173000Z
DTEND:20261001T030000Z
SUMMARY:Shift
END:VEVENT
END:VCALENDAR`
	rows := parseRoster(ics)
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	if rows["2026-10-01"].Category != "shift" {
		t.Fatalf("shift must override leave for the same local date: %+v", rows["2026-10-01"])
	}
}

func TestComputeContract(t *testing.T) {
	now := time.Date(2026, 9, 30, 6, 30, 0, 0, time.UTC)
	rows := sortedRows(parseRoster(fixtureICS), now)
	c := computeContract(rows, now)
	if c.State != "2026-09-30T17:30:00.000Z" {
		t.Fatalf("state: %s", c.State)
	}
	if c.ShiftDate != "2026-10-01" || c.StartLocal != "03:30" || c.EndLocal != "13:00" {
		t.Fatalf("contract row: %+v", c)
	}
	if c.StartsInHours != float64(11) {
		t.Fatalf("starts_in_hours: %v", c.StartsInHours)
	}
	if c.ThisWeekCount != 2 {
		t.Fatalf("this_week_count: %d", c.ThisWeekCount)
	}
	if c.ThisWeekHours != 19 {
		t.Fatalf("this_week_hours: %v", c.ThisWeekHours)
	}
	if c.EndISO != "2026-10-01T03:00:00.000Z" {
		t.Fatalf("end_iso: %s", c.EndISO)
	}
}

func TestDetectChanges(t *testing.T) {
	now := time.Date(2026, 9, 30, 6, 30, 0, 0, time.UTC)
	prev := `BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260930T173000Z
DTEND:20261001T030000Z
SUMMARY:Shift
END:VEVENT
BEGIN:VEVENT
DTSTART:20261002T173000Z
DTEND:20261003T030000Z
SUMMARY:Shift
END:VEVENT
BEGIN:VEVENT
DTSTART:20261020T173000Z
DTEND:20261021T030000Z
SUMMARY:Shift
END:VEVENT
END:VCALENDAR`
	curr := `BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260930T173000Z
DTEND:20261001T030000Z
SUMMARY:Shift
END:VEVENT
BEGIN:VEVENT
DTSTART:20261002T180000Z
DTEND:20261003T030000Z
SUMMARY:Shift
END:VEVENT
BEGIN:VEVENT
DTSTART:20261004T173000Z
DTEND:20261005T030000Z
SUMMARY:Shift
END:VEVENT
END:VCALENDAR`
	ch := detectChanges(prev, curr, now)
	if len(ch) != 3 {
		t.Fatalf("want 3 changes (retimed, cancelled, added-in-window), got %d: %+v", len(ch), ch)
	}
	byDate := map[string]Change{}
	for _, c := range ch {
		byDate[c.Date] = c
	}
	if byDate["2026-10-03"].Type != "time_changed" {
		t.Fatalf("retime: %+v", byDate["2026-10-03"])
	}
	if byDate["2026-10-21"].Type != "cancelled" {
		t.Fatalf("cancel: %+v", byDate["2026-10-21"])
	}
	if byDate["2026-10-05"].Type != "added" || !byDate["2026-10-05"].WithinWindow {
		t.Fatalf("add: %+v", byDate["2026-10-05"])
	}
	// out-of-window add is skipped entirely
	curr2 := prev + "\nBEGIN:VEVENT\nDTSTART:20261025T173000Z\nDTEND:20261026T030000Z\nSUMMARY:Shift\nEND:VEVENT\nEND:VCALENDAR"
	ch2 := detectChanges(prev, curr2, now)
	for _, c := range ch2 {
		if c.Type == "added" {
			t.Fatalf("out-of-window add must be skipped: %+v", c)
		}
	}
}
