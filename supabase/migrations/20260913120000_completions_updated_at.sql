-- `completions.updated_at`, for a project that already ran the first migration.
--
-- A fresh apply of `20260913000000_nem_schema.sql` already creates the column;
-- this file exists for the project that was created before #12, where
-- `create table if not exists` would do nothing and the column would simply
-- never appear. Safe to run either way — every statement is `if not exists`, or
-- an `update` that matches nothing once it has run.
--
-- Why the column exists at all is in the local schema's doc comment
-- (`lib/src/data/database.dart`, `Completions.updatedAt`), and the short form
-- is: the pull filters, orders and pages on one column, and a cursor on
-- `created_at` never carries a tombstone. Taking a completion back moves
-- `deleted_at` and leaves `created_at` where it was, so the corrected row would
-- sit behind the other device's cursor forever and the correction would never
-- arrive. The alternative — a cursor reading the later of the two columns —
-- wants an expression where PostgREST wants a column name.
--
-- Nothing computes it. Like every other column here it is written exactly as
-- the device sends it (ADR 0001), and there is deliberately no trigger: a
-- server that restamped `updated_at` on write would break last-write-wins on
-- the spot.

alter table public.completions
  add column if not exists updated_at timestamptz;

-- The backfill is the same one the device's `TableMigration` does: the later of
-- what the row already has, which is what the column would have held had it
-- existed from the start. A completion that was taken back is measured from its
-- tombstone; one that stands is measured from when it was written.
update public.completions
  set updated_at = coalesce(deleted_at, created_at)
  where updated_at is null;

alter table public.completions
  alter column updated_at set not null;

-- The pull is `where (updated_at, id) > cursor order by updated_at, id`, so
-- completions want the same composite every other synced table has. The
-- `created_at` one it replaces was only ever the index for a cursor that could
-- not carry a tombstone.
create index if not exists idx_completions_updated_at
  on public.completions (updated_at, id);
drop index if exists public.idx_completions_created_at;
