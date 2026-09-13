-- Categories and the membership of tasks in them (#14).
--
-- A category is a user-defined grouping that cuts across targets — kitchen,
-- car, admin (CONTEXT.md). It is not a tag: that word is reserved for NFC
-- hardware, and `bindings.kind` is the only place in this schema where it
-- legitimately appears.
--
-- Column for column, `lib/src/data/database.dart`, like everything else here.
-- Nothing computes anything: no trigger maintains `updated_at`, no default
-- fills in a timestamp, because the value last-write-wins compares has to be
-- the moment the *edit* happened on the device that made it (ADR 0001).
--
-- Safe to run twice — every statement is `if not exists`, or a `drop … if
-- exists` first — so a project created before #14 is brought up to date by
-- pasting this after the earlier files.

create table if not exists public.categories (
  id uuid primary key,
  name text not null,
  -- The swatch, as a 32-bit ARGB value; null when one was never chosen.
  -- `integer` rather than `smallint` or a text hex: it is the number drift
  -- stores, and a round trip that reinterpreted it would be a colour change.
  color integer,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  -- Soft delete, so a delete beats a stale update. Deleting a category deletes
  -- no work: the tasks are untouched, and the membership rows below are
  -- tombstoned by the device in the same transaction.
  deleted_at timestamptz
);

create table if not exists public.task_categories (
  -- A surrogate key, where PLAN.md's schema block writes a composite
  -- `(task_id, category_id)`. Sync addresses every row it moves by a single
  -- `id`: the outbox names `(table, row_id)`, the pull cursor is an
  -- `(updated_at, id)` pair, and the conditional `PATCH` filters on `id`. The
  -- pair is still unique — as a constraint rather than as the key — so a
  -- membership added on both devices converges on one row.
  id uuid primary key,
  -- Deliberately no `references`, on either column — ADR 0011, and this is the
  -- table its argument fits most sharply. A membership row names two rows, and
  -- sync pulls tables in no guaranteed order, so it can legitimately arrive
  -- before either of them. Two constraints would be two ways to refuse a
  -- perfectly valid push and leave a device unable to converge.
  task_id uuid not null,
  category_id uuid not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  -- Taking a task out of a category tombstones this row; putting it back
  -- re-points the row that is already there, which is what the unique
  -- constraint below is for. A hard delete would give the other device a row
  -- to resurrect.
  deleted_at timestamptz,
  constraint task_categories_pair_key unique (task_id, category_id)
);

-- The pull is `where (updated_at, id) > cursor order by updated_at, id`, so
-- every synced table wants that composite.
create index if not exists idx_categories_updated_at
  on public.categories (updated_at, id);
create index if not exists idx_task_categories_updated_at
  on public.task_categories (updated_at, id);

create index if not exists idx_task_categories_task_id
  on public.task_categories (task_id);
create index if not exists idx_task_categories_category_id
  on public.task_categories (category_id);

-- Row-level security, identical to the other tables': everything to the one
-- account (ADR 0003), nothing to anybody else. `anon` is never named, so the
-- anon key alone — which ships in the app and is not a secret — reads nothing.

alter table public.categories      enable row level security;
alter table public.task_categories enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['categories', 'task_categories'] loop
    execute format(
      'drop policy if exists "the nem account owns every row" on public.%I', t
    );
    execute format(
      'create policy "the nem account owns every row" on public.%I '
      'for all to authenticated '
      'using (public.is_nem_account()) '
      'with check (public.is_nem_account())', t
    );
    execute format('revoke all on public.%I from anon', t);
    execute format(
      'grant select, insert, update, delete on public.%I to authenticated', t
    );
  end loop;
end;
$$;
