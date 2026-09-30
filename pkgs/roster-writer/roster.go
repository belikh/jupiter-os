package main

// roster.go — the parsing / classification / contract computations ported
// from the n8n Code nodes with byte-level behavioural parity. See PARITY.md:
// every function here mirrors a specific n8n behaviour; do not "improve"
// semantics without updating the dual-run expectations.

import (
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const brisOffset = 10 * time.Hour // Brisbane: fixed +10, no DST

var (
	reUnfoldCRLF = regexp.MustCompile(`\r\n[ \t]`)
	reUnfoldLF   = regexp.MustCompile(`\n[ \t]`)
	reDate       = regexp.MustCompile(`^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?`)
	reBracket    = regexp.MustCompile(`\[(\d{1,3}):(\d{2})\]`)
	reUnpaid     = regexp.MustCompile(`without pay|unpaid|lwop`)
	rePaidLeave  = regexp.MustCompile(`leave|annual|sick|personal|carer|holiday|rostered day|rdo|bereavement|long service`)
)

// Event is the parseAll shape (change detector).
type Event struct {
	Date       string
	StartISO   time.Time
	EndISO     *time.Time
	StartLocal string
	EndLocal   string
	Summary    string
	Location   string
}

// RosterRow is the parseRoster shape (roster builder) after enrichment.
type RosterRow struct {
	Date      string
	StartISO  time.Time
	EndISO    *time.Time
	StartLoc  string
	EndLoc    string
	Location  string
	Summary   string
	Category  string
	Hours     float64
	PaidHours float64
	IsFuture  bool
	IsNext    bool
}

// Change is one shift_change_log candidate.
type Change struct {
	Date         string
	Type         string // cancelled | added | time_changed
	OldStart     string
	NewStart     string
	DaysNotice   int
	WithinWindow bool
	Location     string
}

func round2(f float64) float64 { return float64(int64(f*100+sign(f)*0.5)) / 100 }

func sign(f float64) float64 {
	if f < 0 {
		return -1
	}
	return 1
}

func round1(f float64) float64 { return float64(int64(f*10+sign(f)*0.5)) / 10 }

func unfold(text string) string {
	text = reUnfoldCRLF.ReplaceAllString(text, "")
	return reUnfoldLF.ReplaceAllString(text, "")
}

// parseDateUTC mirrors the n8n parseDate: naive parts, treated as UTC.
func parseDateUTC(s string) (time.Time, bool) {
	m := reDate.FindStringSubmatch(s)
	if m == nil {
		return time.Time{}, false
	}
	num := func(i int) int {
		if m[i] == "" {
			return 0
		}
		n, _ := strconv.Atoi(m[i])
		return n
	}
	return time.Date(num(1), time.Month(num(2)), num(3), num(4), num(5), num(6), 0, time.UTC), true
}

func isoMillis(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

func brisParts(t time.Time) (string, string) {
	b := t.UTC().Add(brisOffset)
	return b.Format("2006-01-02"), b.Format("15:04")
}

// scanEvents walks the unfolded ICS and yields per-VEVENT key/value maps
// (last occurrence wins per key, matching the n8n assign loop).
func scanEvents(ics string) []map[string]string {
	var out []map[string]string
	var cur map[string]string
	for _, line := range regexp.MustCompile(`\r?\n`).Split(unfold(ics), -1) {
		switch line {
		case "BEGIN:VEVENT":
			cur = map[string]string{}
			continue
		case "END:VEVENT":
			if cur != nil && cur["DTSTART"] != "" {
				out = append(out, cur)
			}
			cur = nil
			continue
		}
		if cur == nil {
			continue
		}
		i := strings.Index(line, ":")
		if i == -1 {
			continue
		}
		key, val := line[:i], line[i+1:]
		if sc := strings.Index(key, ";"); sc != -1 {
			key = key[:sc]
		}
		cur[key] = val
	}
	return out
}

func eventBase(ev map[string]string) (Event, bool) {
	su, ok := parseDateUTC(ev["DTSTART"])
	if !ok {
		return Event{}, false
	}
	var eu *time.Time
	if ev["DTEND"] != "" {
		if t, ok2 := parseDateUTC(ev["DTEND"]); ok2 {
			eu = &t
		}
	}
	date, startLocal := brisParts(su)
	e := Event{
		Date:       date,
		StartISO:   su,
		EndISO:     eu,
		StartLocal: startLocal,
		Summary:    ev["SUMMARY"],
	}
	if eu != nil {
		_, e.EndLocal = brisParts(*eu)
	}
	if d := ev["DESCRIPTION"]; d != "" {
		e.Location = strings.TrimSpace(strings.SplitN(strings.ReplaceAll(d, `\n`, "\n"), "\n", 2)[0])
	}
	return e, true
}

// parseAll mirrors the change detector's parseEvents (later events overwrite).
func parseAll(ics string) map[string]Event {
	out := map[string]Event{}
	for _, ev := range scanEvents(ics) {
		if e, ok := eventBase(ev); ok {
			out[e.Date] = e
		}
	}
	return out
}

func classify(summary string) string {
	s := strings.ToLower(summary)
	switch {
	case strings.Contains(s, "shift"):
		return "shift"
	case reUnpaid.MatchString(s):
		return "unpaid_leave"
	case rePaidLeave.MatchString(s):
		return "paid_leave"
	default:
		return "other"
	}
}

func bracketHours(summary string) (float64, bool) {
	m := reBracket.FindStringSubmatch(summary)
	if m == nil {
		return 0, false
	}
	h, _ := strconv.Atoi(m[1])
	mm, _ := strconv.Atoi(m[2])
	return round2(float64(h) + float64(mm)/60), true
}

// parseRoster mirrors Build Roster Rows (first-wins unless a shift replaces).
func parseRoster(ics string) map[string]RosterRow {
	out := map[string]RosterRow{}
	for _, ev := range scanEvents(ics) {
		base, ok := eventBase(ev)
		if !ok {
			continue
		}
		category := classify(base.Summary)
		hours := 0.0
		if base.EndISO != nil {
			hours = round2(base.EndISO.Sub(base.StartISO).Hours())
		}
		if bh, ok2 := bracketHours(base.Summary); ok2 {
			hours = bh
		}
		paid := category == "shift" || category == "paid_leave"
		paidHours := 0.0
		if paid {
			paidHours = hours
		}
		existing, seen := out[base.Date]
		if seen && (existing.Category == "shift" || category != "shift") {
			continue
		}
		out[base.Date] = RosterRow{
			Date: base.Date, StartISO: base.StartISO, EndISO: base.EndISO,
			StartLoc: base.StartLocal, EndLoc: base.EndLocal, Location: base.Location,
			Summary: base.Summary, Category: category, Hours: hours, PaidHours: paidHours,
		}
	}
	return out
}

var dayNames = []string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

func dayName(date string) string {
	t, err := time.Parse("2006-01-02", date)
	if err != nil {
		return ""
	}
	return dayNames[int(t.Weekday())]
}

func sortedRows(m map[string]RosterRow, now time.Time) []RosterRow {
	rows := make([]RosterRow, 0, len(m))
	for _, r := range m {
		rows = append(rows, r)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].StartISO.Before(rows[j].StartISO) })
	nextMarked := false
	for i := range rows {
		rows[i].IsFuture = rows[i].StartISO.After(now)
		if rows[i].IsFuture && rows[i].Category == "shift" && !nextMarked {
			rows[i].IsNext = true
			nextMarked = true
		}
	}
	return rows
}

// Contract is the HA sensor payload computed exactly as Compute Next Shift.
type Contract struct {
	State         string
	ShiftDate     string
	Day           string
	StartLocal    string
	EndLocal      string
	Location      string
	DurationHours any
	StartsInHours any
	EndISO        string
	ThisWeekCount int
	ThisWeekHours float64
	Upcoming      string
}

type upcomingEntry struct {
	Date     string `json:"date"`
	Day      string `json:"day"`
	Start    string `json:"start"`
	End      string `json:"end"`
	Location string `json:"location"`
}

func computeContract(rows []RosterRow, now time.Time) Contract {
	var future []RosterRow
	for _, r := range rows {
		if r.IsFuture && r.Category == "shift" {
			future = append(future, r)
		}
	}
	c := Contract{State: "unknown", ThisWeekCount: 0}
	if len(future) == 0 {
		up, _ := json.Marshal([]upcomingEntry{})
		c.Upcoming = string(up)
		return c
	}
	next := future[0]
	upcoming := []upcomingEntry{}
	for i := 0; i < len(future) && i < 5; i++ {
		upcoming = append(upcoming, upcomingEntry{
			Date: future[i].Date, Day: dayName(future[i].Date),
			Start: future[i].StartLoc, End: future[i].EndLoc, Location: future[i].Location,
		})
	}
	up, _ := json.Marshal(upcoming)
	weekCut := now.Add(7 * 24 * time.Hour)
	weekHours := 0.0
	weekCount := 0
	for _, r := range future {
		if r.StartISO.Before(weekCut) {
			weekCount++
			weekHours += r.PaidHours
		}
	}
	endISO := ""
	if next.EndISO != nil {
		endISO = isoMillis(*next.EndISO)
	}
	c = Contract{
		State:         isoMillis(next.StartISO),
		ShiftDate:     next.Date,
		Day:           dayName(next.Date),
		StartLocal:    next.StartLoc,
		EndLocal:      next.EndLoc,
		Location:      next.Location,
		DurationHours: next.Hours,
		StartsInHours: round1(next.StartISO.Sub(now).Hours()),
		EndISO:        endISO,
		ThisWeekCount: weekCount,
		ThisWeekHours: round2(weekHours),
		Upcoming:      string(up),
	}
	return c
}

// detectChanges mirrors Detect Shift Changes (types, windows, skips).
func detectChanges(prevRaw, currRaw string, now time.Time) []Change {
	prev, curr := parseAll(prevRaw), parseAll(currRaw)
	if prevRaw == "" || len(prev) == 0 {
		return nil // baseline
	}
	dates := map[string]bool{}
	for d := range prev {
		dates[d] = true
	}
	for d := range curr {
		dates[d] = true
	}
	var out []Change
	for date := range dates {
		p, hasP := prev[date]
		c, hasC := curr[date]
		var typ string
		var ref Event
		switch {
		case hasP && !hasC:
			typ, ref = "cancelled", p
		case !hasP && hasC:
			typ, ref = "added", c
		case hasP && hasC && (!p.StartISO.Equal(c.StartISO) || !eqPtr(p.EndISO, c.EndISO)):
			typ, ref = "time_changed", c
		default:
			continue
		}
		if !ref.StartISO.After(now) {
			continue
		}
		daysNotice := int(ref.StartISO.Sub(now).Hours() / 24)
		within := daysNotice < 7
		if typ == "added" && !within {
			continue // n8n skips out-of-window additions entirely
		}
		ch := Change{Date: date, Type: typ, DaysNotice: daysNotice, WithinWindow: within, Location: ref.Location}
		if hasP {
			ch.OldStart = p.StartLocal
		}
		if hasC {
			ch.NewStart = c.StartLocal
		}
		out = append(out, ch)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Date != out[j].Date {
			return out[i].Date < out[j].Date
		}
		return out[i].Type < out[j].Type
	})
	return out
}

func eqPtr(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Equal(*b)
}
