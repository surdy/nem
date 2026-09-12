# A tag identifies a target, not a task

Scannable codes are bound to a target — a physical place or object such as the
boiler or the front door — and tasks hang off targets. A single spot usually
hosts several routines, so binding codes directly to tasks would mean three
stickers on one door.

## Consequences

A scan resolves to a *set* of due tasks rather than one, so the scan handler
needs a disambiguation path for the multi-task case. In exchange, re-pointing a
physical tag at different work is an in-app edit rather than a re-write of the
tag itself.
