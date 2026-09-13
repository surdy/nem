-- Realtime for the seven synced tables (#13).
--
-- Postgres Changes is switched off for a table until that table is a member of
-- the `supabase_realtime` publication; a channel bound to a table that is not in
-- it subscribes successfully and then simply never fires, which is the quietest
-- possible failure and the reason this file exists rather than being a line in
-- the dashboard someone has to remember.
--
-- Dated after `20260913190000_reference_photos.sql` on purpose, and re-dated
-- whenever a migration adds a synced table — #15 moved it once already, for
-- `photos`. The list below is
-- `defaultSyncedTables` (`lib/src/sync/sync_engine.dart`), and every table in it
-- has to exist before it can be published, so this file wants to be the last one
-- pasted — and wants re-running whenever a later migration adds a table.
--
-- This is the only thing realtime asks of the backend. Notably absent:
--
--   * no `replica identity full`. That exists so a subscriber can be told the
--     *old* values of an updated or deleted row, and nem never reads a realtime
--     payload at all — the message is a signal that something changed, and the
--     cursored pull is what fetches it (`lib/src/sync/sync_channel.dart`).
--     Leaving the default replica identity keeps the WAL smaller for free.
--   * no trigger, no function and no new policy. The existing row-level
--     security is what the realtime server evaluates for a subscriber, so the
--     account (ADR 0003) receives its own rows and the anon key receives
--     nothing, by the same policy that governs every other request.
--
-- Idempotent like the rest of `migrations/`: running it twice changes nothing.

do $$
declare
  t text;
begin
  -- Present on every Supabase project and on a stock self-hosted stack. Created
  -- here only for the instance where it has been dropped, so that the loop below
  -- has somewhere to add to.
  if not exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    execute 'create publication supabase_realtime';
  end if;

  foreach t in array array[
    'targets', 'categories', 'tasks', 'bindings', 'task_categories',
    'completions', 'photos'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I', t
      );
    end if;
  end loop;
end;
$$;
