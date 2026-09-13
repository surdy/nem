# Store fixed schedules as RRULE, author them through a narrower editor

Fixed schedules are stored as RFC 5545 RRULE strings and expanded by the `rrule`
package, while the editor deliberately exposes only the subset Google Calendar
exposes — frequency, interval, weekday picker, day-of-month versus nth-weekday,
and an end condition. Storage is therefore strictly more expressive than the UI.

The standard gives us correct handling of leap years and month ends, and leaves
a calendar-export path open; the rejected alternative — plain interval,
weekday-set and day-of-month columns — would have meant writing and testing that
calendar arithmetic ourselves.

It does **not** give us DST for free. The `rrule` package is UTC-only by explicit
design and refuses non-UTC input; see ADR 0010 for how local time is handled.

## Consequences

An RRULE that the editor cannot represent can still reach storage, by hand-edit
or future import. The editor must degrade gracefully — show the rule as read-only
text rather than crash or silently rewrite it. Where "read-only" is presented is
a UI question, not a storage one; today it is the task detail screen, because
there is no edit-task screen yet.

Deciding *what* counts as unrepresentable is a judgement surface this ADR leaves
open, and several lines have been drawn in code and pinned by tests: a fifth
weekday is never written (`BYDAY=5TU` skips months with only four, `-1TU` does
not, so a fifth-week anchor is offered as "the last"), a `BYMONTHDAY` equal to
the anchor's day is accepted as the same rule while a different one is not, and
a mid-day `UNTIL` is not.

The calendar-export path is narrower than this ADR first claimed. RFC 5545
requires `UNTIL` to be in UTC when `DTSTART` carries a `TZID`; we store it as
floating wall-clock digits instead, matching `DTSTART` and matching what the
`rrule` package itself emits and parses. That keeps the round trip exact and
immune to DST, but a strict third-party importer would read the end date off by
the zone offset. Resolve it when an export path is actually built, not before.

The `rrule` package validates by `assert`, so a malformed rule throws in debug
and passes silently in release. Parsing converts those into `FormatException` so
a hand-edited rule cannot crash a screen in one build mode only.
