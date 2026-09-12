# Local-first: SQLite is the source of truth

nem has to work with no network — you scan a tag in a garage, a basement or on a
plane, and it must record the completion and tell you what is next. The device's
SQLite database is therefore authoritative and the server is a replica: every
scheduling calculation runs on-device, and nothing is computed server-side.

## Consequences

Due dates are recalculated independently on each device rather than synced, so a
phone that has been offline for a month is correct the moment it reopens. There
is no server-side job that can repair a schedule — a scheduling bug can only be
fixed by shipping a new build to both devices.
