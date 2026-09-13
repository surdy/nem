-- nem's Postgres schema: a replica of the device's SQLite database.
--
-- The device is authoritative and this is a copy (ADR 0001). Nothing here
-- computes anything: there are no triggers maintaining `updated_at`, no
-- defaults filling in timestamps, no functions deriving a due date. Every
-- column is written exactly as the device sends it, because both devices
-- recalculate their own schedules and a server that "helpfully" restamped
-- `updated_at` would break last-write-wins on the spot — the value nem compares
-- is the moment the *edit* happened, not the moment it was uploaded.
--
-- There is no `user_id` anywhere (ADR 0003). One person, two devices, one
-- account; the account exists to scope the data and let the second device sign
-- in, and row-level security is written against a one-row allow-list rather
-- than against a column on every table.

-- ---------------------------------------------------------------------------
-- The single account (ADR 0003)
-- ---------------------------------------------------------------------------

-- One row, holding the uid of the one account that may read and write
-- everything. Seeded by hand after the first sign-in; see ../README.md.
--
-- An allow-list rather than `using (true)`: `to authenticated` on its own would
-- hand every row to anyone who ever managed to sign up, and "signups are off in
-- the dashboard" is a setting, not a constraint.
create table if not exists public.nem_account (
  uid uuid primary key
);

alter table public.nem_account enable row level security;

-- `security definer`, so the predicate can see the allow-list without the
-- allow-list needing a policy that exposes it — and `stable`, so Postgres
-- evaluates it once per statement rather than once per row.
--
-- This is not the server-side logic ADR 0001 rules out. It computes nothing
-- about the domain; it answers "is this the account", which is the one question
-- a database has to answer for itself.
create or replace function public.is_nem_account()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.nem_account where uid = auth.uid());
$$;

revoke all on function public.is_nem_account() from public, anon;
grant execute on function public.is_nem_account() to authenticated;

-- The account can see its own row; nobody can change it from a client.
drop policy if exists "the account can see itself" on public.nem_account;
create policy "the account can see itself"
  on public.nem_account for select to authenticated
  using (uid = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- The domain tables
-- ---------------------------------------------------------------------------
--
-- Column for column, `lib/src/data/database.dart`. Where this differs from
-- PLAN.md's schema block it is because the local table does, and the local
-- table is the one that is real:
--
--   * `tasks.start_date` is `timestamptz`, not `date`. drift stores it as a
--     full instant, and a `date` column would silently truncate one half of
--     every round trip.
--   * `tasks.reminder_time` is `text`, not `time`. It holds a wall-clock
--     "HH:mm" with no date and no zone, which is a string here as it is there.
--   * `tasks.snoozed_until` / `snoozed_at` are not in PLAN.md's block at all;
--     they arrived with snooze (#18) and are as real as the rest.

create table if not exists public.targets (
  id uuid primary key,
  name text not null,
  description text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);

create table if not exists public.bindings (
  id uuid primary key,
  -- Deliberately no `references public.targets (id)` — ADR 0011. Rows are
  -- pushed and pulled per table in no guaranteed order, so a binding can
  -- legitimately arrive before the target it names, and a constraint would
  -- reject a push that is perfectly valid and leave the device unable to
  -- converge. Referential integrity for this column is the application's job.
  target_id uuid not null,
  kind text not null check (kind in ('tag', 'label', 'barcode')),
  -- Our uuid for a tag or label, the raw product code for a barcode.
  value text not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  -- A target can wear a tag and a printed label at once, both carrying the
  -- same `nem://t/<uuid>`: two rows, two kinds, one value.
  constraint bindings_kind_value_key unique (kind, value)
);

create table if not exists public.tasks (
  id uuid primary key,
  title text not null,
  notes text,
  -- No foreign key, for exactly the reason bindings.target_id has none
  -- (ADR 0011).
  target_id uuid,
  schedule_mode text not null check (schedule_mode in ('floating', 'fixed')),
  -- Floating only.
  interval_n integer,
  interval_unit text check (interval_unit in ('day', 'week', 'month', 'year')),
  -- Fixed only: a DTSTART line and an RRULE line (ADR 0006).
  rrule text,
  start_date timestamptz not null,
  -- Derived caches (ADR 0004). Replicated because they are columns of the row,
  -- never trusted: each device recomputes them from its own completion log
  -- after every pull.
  due_date timestamptz,
  last_completed_at timestamptz,
  reminder_time text,
  snoozed_until timestamptz,
  snoozed_at timestamptz,
  is_archived boolean not null default false,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);

create table if not exists public.completions (
  id uuid primary key,
  -- No foreign key here either, and this one is a deliberate divergence from
  -- the local schema, which does have one.
  --
  -- ADR 0011's argument is about the order rows arrive in, and it applies to
  -- this column exactly as it does to `target_id`: a completion can be pushed
  -- before the task it records work against — the outbox drains in the order
  -- rows went dirty, but a partial drain, a reordering, or a task whose push
  -- was refused all break that. A constraint would reject the completion, and
  -- completions are the one thing nem cannot afford to lose (ADR 0004: due
  -- dates are derived from them and cannot be reconstructed from anything
  -- else). An orphan completion is recoverable; a rejected one is not.
  --
  -- The local `REFERENCES tasks (id)` is the mirror-image hazard and #12 will
  -- have to deal with it: a pull can deliver a completion before its task, and
  -- SQLite runs with `PRAGMA foreign_keys = ON`.
  task_id uuid not null,
  completed_at timestamptz not null,
  source text not null check (source in ('manual', 'tag', 'label', 'barcode')),
  note text,
  -- Which device recorded this.
  device_id text not null,
  created_at timestamptz not null,
  -- Tombstones a correction (ADR 0004). Completions are never updated in
  -- place, so there is no `updated_at`: the row is immutable apart from this.
  deleted_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
--
-- The pull is `where (updated_at, id) > cursor order by updated_at, id`, so
-- every synced table wants that composite. Completions are ordered on
-- `created_at` instead: they have no `updated_at` because they are immutable.

create index if not exists idx_targets_updated_at
  on public.targets (updated_at, id);
create index if not exists idx_bindings_updated_at
  on public.bindings (updated_at, id);
create index if not exists idx_tasks_updated_at
  on public.tasks (updated_at, id);
create index if not exists idx_completions_created_at
  on public.completions (created_at, id);

create index if not exists idx_bindings_target_id
  on public.bindings (target_id);
create index if not exists idx_tasks_target_id
  on public.tasks (target_id);
create index if not exists idx_completions_task_id
  on public.completions (task_id);

-- ---------------------------------------------------------------------------
-- Row-level security (ADR 0003)
-- ---------------------------------------------------------------------------
--
-- One policy per table, covering all four verbs, granting everything to the one
-- account and nothing to anybody else. `anon` is never named, so the anon key
-- alone — which ships in the app and is not a secret — reads nothing.

alter table public.targets     enable row level security;
alter table public.bindings    enable row level security;
alter table public.tasks       enable row level security;
alter table public.completions enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['targets', 'bindings', 'tasks', 'completions'] loop
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

revoke all on public.nem_account from anon;
grant select on public.nem_account to authenticated;
