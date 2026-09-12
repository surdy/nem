# Store fixed schedules as RRULE, author them through a narrower editor

Fixed schedules are stored as RFC 5545 RRULE strings and expanded by the `rrule`
package, while the editor deliberately exposes only the subset Google Calendar
exposes — frequency, interval, weekday picker, day-of-month versus nth-weekday,
and an end condition. Storage is therefore strictly more expressive than the UI.

The standard gives us correct handling of leap years, month ends and DST for
free, and leaves a calendar-export path open; the rejected alternative — plain
interval, weekday-set and day-of-month columns — would have meant writing and
testing that date arithmetic ourselves.

## Consequences

An RRULE that the editor cannot represent can still reach storage, by hand-edit
or future import. The editor must degrade gracefully — show the rule as read-only
text rather than crash or silently rewrite it.
