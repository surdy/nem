# No foreign key constraint on a reference to a target

`tasks.target_id` and `bindings.target_id` both reference a target, and neither
carries a `REFERENCES` constraint, even though PLAN.md's schema block originally
wrote both as foreign keys.

Two properties of this design make the constraint wrong rather than merely
unnecessary. Deletes are soft (ADR 0003's schema shape, and every table carries
`deleted_at`), so a target row never actually vanishes and the constraint would
never be protecting against the case it exists for. More decisively, sync pulls
rows per table in no guaranteed order (ADR 0002), so a task can legitimately
arrive before the target it points at — a constraint would reject a pull that is
perfectly valid and leave the device permanently unable to converge.

## Consequences

Referential integrity for this column is the application's job: a `target_id`
that resolves to nothing must be treated as unassigned rather than as an error.

Adding the constraint later is not a one-line migration. SQLite cannot add a
foreign key to an existing table, so it means a `TableMigration` that recreates
`tasks` and copies every row — which is why this is worth recording rather than
leaving for someone to "tidy up".

Soft-deleting a target clears `target_id` on its tasks in the same transaction
and bumps their `updated_at`, so the unassignment is a change sync can see
rather than a local edit that the next pull would silently revert.
