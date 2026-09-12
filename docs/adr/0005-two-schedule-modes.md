# Two schedule modes: floating and fixed

Household routines split cleanly in two: "every 3 months after I last did it"
(water filter) and "the 1st of the month regardless" (rent). Each task picks one
mode, and the two use different representations on the same table — an interval
for floating, an RRULE for fixed.

## Consequences

`tasks` carries two mutually exclusive sets of nullable columns. This is
deliberate — do not unify them behind a single representation. RRULE cannot
express floating mode at all, because floating depends on completion history
rather than on the calendar, so there is no shared encoding to collapse into.
