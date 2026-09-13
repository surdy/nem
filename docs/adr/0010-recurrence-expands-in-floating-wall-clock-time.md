# Recurrence expands in floating wall-clock time, resolved per occurrence

The `rrule` package is UTC-only by explicit design — it refuses `DateTime`s
whose `isUtc` is false, and states that it deliberately knows nothing about time
zones. So "every Tuesday at 09:00" cannot be expanded directly in local time.

We therefore store a wall-clock start time plus an IANA zone id (never a fixed
UTC offset), hand the expander a *floating* time — the local wall-clock digits
relabelled as UTC, which preserves the digits rather than converting them — and
resolve each returned occurrence back to a real instant individually, against
that date's offset in the stored zone.

## Storage

The wall-clock anchor and the zone id are stored inside the existing `rrule`
column as RFC 5545's own notation for exactly that pair, rather than in extra
columns:

```
DTSTART;TZID=Europe/London:20260106T000000
RRULE:FREQ=WEEKLY;BYDAY=TU
```

So the fixed representation stays a single column (ADR 0005) and the
calendar-export path stays open (ADR 0006). A bare `RRULE:` line with no
`DTSTART` still parses, falling back to the task's start date and the device
zone. Do not add a separate timezone column — it is already here.

## Considered options

`teno_rrule`, which supports zone-aware recurrence natively and would remove the
relabelling dance. Rejected for now: it is much less established than `rrule`,
and the pattern above is well-documented by `rrule` itself.

## Consequences

Resolving the wall-clock time to an instant **once** and then adding seven-day
durations is wrong — it drifts by an hour across every DST transition. Each
occurrence must be resolved independently. Expect to see `copyWith(isUtc: true)`
applied to a local time in the expansion path; that is deliberate relabelling,
not a bug, and it is the single most confusing line in the scheduling code.

A wall-clock time that does not exist (spring-forward gap) or occurs twice
(autumn fall-back) resolves silently without warning. Reminders in the small
hours need an explicit policy rather than whatever the library happens to pick.

The bundled tzdata snapshot only updates when the `timezone` package is bumped,
so occurrences far in the future in a zone with pending legislative changes can
be wrong until that upgrade happens.
