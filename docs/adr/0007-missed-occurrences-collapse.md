# Missed occurrences collapse; the due date pins to the earliest missed one

A task is always exactly one row in the list. If three Tuesdays pass without a
completion, `due_date` stays on the *first* missed Tuesday rather than
advancing to the next future one — that is what produces "15 days late" while
keeping the list the length of your actual life rather than your accumulated
backlog.

Precisely: the due date is the earliest occurrence strictly after the **last
completion**, not after the last completed *occurrence*. The completion log is
the truth (ADR 0004), and the distinction only shows up when the two disagree —
see the consequences.

## Consequences

`due_date` is routinely in the past. This looks like stale data and is not.

Completing work now clears the whole backlog at once: the completion timestamp
is today, so the earliest occurrence after it is the next *future* one and all
the intervening misses are skipped. One tap, not one tap per missed Tuesday.

But a **back-dated** completion deliberately does not clear the backlog. Record
that you did it last Wednesday and the due date lands on the occurrence after
last Wednesday, which may itself still be in the past — so the task stays
overdue, correctly, because the later occurrences genuinely were missed. This
falls out of the log being the truth rather than the clock, and it is the one
case where "first occurrence after today" would give a different, wrong answer.

Missed occurrences remain recoverable from the gaps in the completion log, but
are never surfaced as rows of their own.
