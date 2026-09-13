# Two schedule modes: floating and fixed

Household routines split cleanly in two: "every 3 months after I last did it"
(water filter) and "the 1st of the month regardless" (rent). Each task picks one
mode, and the two use different representations on the same table — an interval
for floating, an RRULE for fixed.

## Consequences

The two modes differ on short months, in opposite directions, and both are
correct for what they mean. A floating monthly interval **clamps**: anchored on
the 31st it lands on 28 February. A fixed monthly rule **skips**: RFC 5545
anchored on the 31st fires in January, March and May and drops February and
April entirely. "Every month from when I last did it" and "the 31st of the
month" are genuinely different instructions, so do not try to make them agree.

`tasks` carries two mutually exclusive sets of nullable columns. This is
deliberate — do not unify them behind a single representation. RRULE cannot
express floating mode at all, because floating depends on completion history
rather than on the calendar, so there is no shared encoding to collapse into.
