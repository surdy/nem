-- Reference photos on tasks (#15): the rows here, the bytes in Storage.
--
-- A photo is a file plus a row. This file is the row half — an ordinary synced
-- table, replicated exactly like `tasks`, with the same one-account RLS. The
-- bytes go to a Storage bucket, which is the second half of this file and the
-- one part of nem's backend that is not just a table.
--
-- Idempotent, like every migration here: safe to paste twice.

-- ---------------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------------

create table if not exists public.photos (
  id uuid primary key,
  -- No foreign key, for exactly the reason `completions.task_id` has none
  -- (ADR 0011): rows are pushed and pulled per table in no guaranteed order, so
  -- a photo can legitimately arrive before the task it is attached to, and a
  -- constraint would reject a push that is perfectly valid.
  task_id uuid not null,
  -- The object's key inside the bucket, or null while the bytes have not been
  -- uploaded yet. Written by the device only after an upload has actually
  -- succeeded, which is what makes a non-null value a promise that the object
  -- is there — the other device treats null as "not yet" rather than as a
  -- broken photo.
  storage_path text,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz
);

-- `local_path` is deliberately absent, and its absence is the point.
--
-- The device's `photos` table has one more column than this: the name of the
-- cache file holding the bytes on *that* phone. Whether a particular device has
-- the bytes on disk is a fact about the device and not about the photo, so sync
-- neither pushes nor applies it (`SyncedTable.deviceLocalColumns`). Replicating
-- it would have the second phone believe it holds a file it has never
-- downloaded, and show a blank tile instead of "waiting for the other device".
--
-- Do not add the column "for completeness". Nothing would write it and the
-- codec would not send it.

-- The pull is `where (updated_at, id) > cursor order by updated_at, id`.
create index if not exists idx_photos_updated_at
  on public.photos (updated_at, id);
create index if not exists idx_photos_task_id
  on public.photos (task_id);

alter table public.photos enable row level security;

drop policy if exists "the nem account owns every row" on public.photos;
create policy "the nem account owns every row"
  on public.photos for all to authenticated
  using (public.is_nem_account())
  with check (public.is_nem_account());

revoke all on public.photos from anon;
grant select, insert, update, delete on public.photos to authenticated;

-- ---------------------------------------------------------------------------
-- The bytes
-- ---------------------------------------------------------------------------
--
-- One private bucket, `reference-photos`, holding objects keyed
-- `<task id>/<photo id>.<ext>`. Private: nem has one account (ADR 0003), the
-- anon key ships inside the app and is not a secret, and a public bucket would
-- put every photograph of the inside of your boiler cupboard on a guessable
-- URL. The app downloads through the authenticated client, so it never needs a
-- public URL or a signed one.
--
-- Both statements below may fail on a self-hosted instance whose SQL user does
-- not own `storage.objects`. Neither is fatal, and neither can be applied from
-- this repository in any case — see ../README.md for the dashboard route, which
-- takes about a minute.

insert into storage.buckets (id, name, public)
  values ('reference-photos', 'reference-photos', false)
  on conflict (id) do nothing;

-- The same one-account allow-list the tables use, scoped to this bucket. Wrapped
-- so that an instance which refuses the policy — permissions on
-- `storage.objects` vary between hosted and self-hosted — reports it and lets
-- the rest of the migration stand, rather than rolling the whole file back.
do $$
begin
  execute 'drop policy if exists "the nem account owns every photo" '
          'on storage.objects';
  execute 'create policy "the nem account owns every photo" '
          'on storage.objects for all to authenticated '
          'using (bucket_id = ''reference-photos'' '
          '       and public.is_nem_account()) '
          'with check (bucket_id = ''reference-photos'' '
          '            and public.is_nem_account())';
exception
  when insufficient_privilege then
    raise notice
      'Could not create the storage policy: this role does not own '
      'storage.objects. Create it from the dashboard instead — see '
      'supabase/README.md, "Reference photos".';
end;
$$;
