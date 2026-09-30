# PARITY.md — roster-writer's contractual parity with the n8n workflows

Source of truth for the port: the two live n8n Code nodes exported from CT102
on 2026-09-30 (`Build Roster Rows` + `Compute Next Shift` in workflow
`nGsgCVqKNh3d1cUv`; `Detect Shift Changes` in `Y74EonAHDDQFzx5L`). The Go
implementation must reproduce their observable behaviour exactly — the
dual-run bar is "≥7-day parallel + 17/17 change-replay".

## Feed
- URL: Kronos/UKG iCal (host `iss.prd.mykronos.com`), secret via sops.
- DTSTART/DTEND are UTC (`YYYYMMDDTHHMMSSZ`); Brisbane = fixed +10 h, no DST.
- Hand-rolled line parser (no ical library — the n8n parser is line-based,
  first value per key wins within a VEVENT, unfolded continuation lines).

## Two parse variants (deliberately different in n8n — preserved here)
- `parseAll` (change detector): every VEVENT keyed by Brisbane local date;
  LATER events overwrite earlier ones for the same date.
- `parseRoster` (roster builder): keyed by Brisbane local date; FIRST event
  wins UNLESS a later `shift` replaces a non-shift. Adds classification:
  - `shift` if summary contains "shift";
  - `unpaid_leave` if /without pay|unpaid|lwop/;
  - `paid_leave` if /leave|annual|sick|personal|carer|holiday|rostered day|rdo|bereavement|long service/;
  - else `other`.
  - `hours` = `[H:MM]` bracket in the summary when present, else the
    DTSTART→DTEND span; rounded to 2 dp. `paid_hours` = hours for
    shift/paid_leave, else 0.
  - `location` = first line of DESCRIPTION (split on the literal `\n` escape).
- Rows sorted by start; `is_next` = first future `shift`.
- (Leave semantics: the history table receives `shift`-category rows only —
  assumption to validate against the dual-run deltas.)

## Sensor contract (what HA sees; reproduced via MQTT, JSON attributes)
state = next shift start ISO (UTC, ms precision); attributes:
`friendly_name` "Next Shift", `device_class` "timestamp",
`icon` "mdi:calendar-clock", `shift_date`, `day` (3-letter), `start_local`
(HH:MM), `end_local`, `location`, `duration_hours`, `starts_in_hours`
(1 dp), `end_iso`, `this_week_count` (future shifts with start < now+7 d),
`this_week_hours` (sum paid_hours, 2 dp), `upcoming` (JSON string of the
next 5 shifts: date/day/start/end/location).

## Change detection (contract: cancelled / added / time_changed)
- Compare previous RAW feed (stored by the writer in `public.roster_feed_state`)
  against the current one, per Brisbane date, over the union of dates.
- `cancelled` = in prev only; `added` = in curr only; `time_changed` =
  start_iso or end_iso differ.
- Future-only (referenced start > now). `added` outside the 7-day notice
  window is skipped entirely (no log row — n8n behaviour).
- `days_notice` = floor((ref_start − now)/86400000).
- Log rows into `public.shift_change_log` carry (shift_date, detected_at,
  old_start, new_start) — local HH:MM strings, matching the G-D custody load.

## MQTT (retained)
- `jupiter/schedule/shift/state` — next start ISO.
- `jupiter/schedule/shift/attributes` — the attribute object above (minus
  friendly_name/device_class/icon duplication? no — full object; HA merges).
- Discovery: `homeassistant/sensor/jupiter_<slug>/config` with
  `state_topic`, `json_attributes_topic`, `device_class` timestamp, icon,
  and a Jupiter Platform device block.
- **Dual-run entity id**: `object_id` defaults to `next_shift_roster`
  (the ghost `sensor.next_shift` stays n8n-owned during dual-run). At the
  atomic flip: stop the n8n writer, republish discovery with
  `object_id=next_shift` so the registry takes the canonical id.
