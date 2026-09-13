# Missed occurrences collapse; the due date pins to the earliest missed one

A task is always exactly one row in the list. If three Tuesdays pass without a
completion, `due_date` stays on the *first* missed Tuesday rather than
advancing to the next future one — that is what produces "15 days late" while
keeping the list the length of your actual life rather than your accumulated
backlog.

## Consequences

`due_date` is routinely in the past. This looks like stale data and is not.
Completing advances it to the first occurrence after today, skipping the
intervening misses; those remain recoverable from the gap in the completion log,
but are never surfaced as rows of their own.
