# Completions are immutable events; schedule state is derived

A completion records that a task was performed at a moment in time and is never
updated in place, only appended. `due_date` and `last_completed_at` are caches
derived from that event log on each device, not authoritative values that sync.

Append-only sets merge without conflict, so two devices can both record work
offline and reconcile with no resolution strategy at all. Mutable schedule state
would have needed last-write-wins and would still have produced "the two phones
disagree about when this is due" bugs.

## Consequences

Correcting a completion means tombstoning it and appending a replacement, not
editing a row. Derived columns must be recomputed after every sync pull and on
every app launch — not only on write — because a pulled completion from the other
device, or a timezone change, can both invalidate them.
