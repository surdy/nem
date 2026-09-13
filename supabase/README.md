# The Supabase side

nem works completely without any of this. The device's SQLite database is the
source of truth (ADR 0001) and a backend is a replica that lets a second device
catch up — so everything below is optional, and nem with the sync fields empty
is nem.

`migrations/` holds the Postgres schema and its row-level security. Nothing in
this repository applies it for you and nem never creates a table: the app only
ever reads and writes rows.

---

## Applying it

### Option A — the dashboard, no tooling (five minutes)

1. Create a project at <https://supabase.com/dashboard>. Any region; the free
   tier is more than enough for one person's household chores.
2. Open **SQL Editor → New query**, paste the whole of
   `migrations/20260913000000_nem_schema.sql`, and run it, then do the same with
   every later file in `migrations/` in filename order. They are idempotent —
   every statement is `if not exists` or `drop … if exists` first — so running
   them twice is safe, and a project created before #12 or #14 is brought up to
   date by the same paste.
3. Do the **"Claim the account"** step below. Until you do, every request is
   refused by RLS and nem will say so.

### Option B — the Supabase CLI

```sh
brew install supabase/tap/supabase      # or see supabase.com/docs/guides/cli
supabase link --project-ref <your-project-ref>
supabase db push
```

`supabase db push` applies everything in `migrations/` in filename order.

### Self-hosting instead

A self-hosted Supabase exposes the identical API, which is the whole reason nem
speaks it directly rather than through an abstraction (ADR 0002). Follow
<https://supabase.com/docs/guides/self-hosting/docker>, run the same SQL against
its Postgres, and put its URL and anon key into nem's settings. Nothing in the
app changes and no new build is needed.

---

## Where the URL and the anon key are

**Supabase Cloud:** **Project Settings → API**.

* **Project URL** — `https://<project-ref>.supabase.co`. This is nem's
  **Base URL**.
* **Publishable key** (older projects call it the **anon / public key**) — a
  long `sb_publishable_…` string, or on older projects a JWT beginning `eyJ…`.
  This is nem's **Anon key**. Either form works.

**Self-hosted:** the `SUPABASE_PUBLIC_URL` and `ANON_KEY` values from the
`.env` you generated when setting up the Docker compose stack.

Neither is a secret. The anon key ships inside every Supabase client app and is
meant to be public; what actually protects the data is the row-level security in
the migration plus the single-account allow-list.

Put both into nem: **Settings → Sync**, then **Save backend**.

---

## Signing in

nem uses an email magic link and has no password (PLAN.md — Sync).

1. In the dashboard, **Authentication → URL Configuration → Redirect URLs**, add:

   ```
   nem://login-callback/
   ```

   This is the custom scheme the app registers on both platforms. Without it
   Supabase refuses to send a link back to nem and the sign-in never completes.

2. In nem, **Settings → Sync**, type your email and tap **Send magic link**.
3. Open the email *on the phone* and tap the link. It opens nem, which finishes
   the sign-in.
4. Repeat on the second device, with the same email address.

### Claim the account

Row-level security refuses everything until the one account is named. After the
first sign-in, run this once in **SQL Editor**:

```sql
insert into public.nem_account (uid)
select id from auth.users
order by created_at
limit 1
on conflict do nothing;
```

Then check it took — this should print exactly one row:

```sql
select * from public.nem_account;
```

### Shut the door behind you

**Authentication → Sign In / Providers → Email**, and turn **Allow new users to
sign up** off. One account is the whole model (ADR 0003); leaving signups open
means strangers can create accounts, and while RLS means they would see nothing,
there is no reason to let them.

---

## Realtime

A change made on one phone appears on the other while both are open, rather than
on the next foreground. That needs one thing on this side, and
`migrations/20260913200000_realtime_publication.sql` is it: the six synced tables
have to be members of the `supabase_realtime` publication, which is what the
dashboard's **Database → Replication** page toggles. Apply the migration — or
tick the six tables there — and it works; skip it and nem is exactly the app it
was before, syncing on foreground and on its retry timer. It is dated last of the
migrations because it names every synced table and so wants them all to exist;
re-run it after any later file that adds one.

nem never reads what the subscription delivers. The message means "something
changed" and the ordinary cursored pull is what fetches it, so there is no
`replica identity full` to set, nothing extra in the WAL, and no second way for
a row to reach the device. `lib/src/sync/sync_channel.dart` has the argument.

---

## Checking it works

In nem on the first device, **Settings → Sync** should show your email and
*Everything is sent* after a **Sync now**. Then in **Table Editor → tasks** you
should see your tasks. On the second device, **Sync now** brings them down.

If a sync fails, the same screen shows why. The two answers that mean something
specific:

| It says | What it is |
|---|---|
| *Sign in again: …* | The session expired, or RLS refused you — most often the **Claim the account** step was skipped. |
| Anything else | The backend could not be reached. Changes stay queued and go up on their own when it can be. |

---

## What is and is not synced

All six domain tables: `targets`, `categories`, `tasks`, `bindings`,
`task_categories` and `completions`. A completion recorded on one phone
reschedules the task on the other, a label or tag provisioned on one resolves on
the other, and a task put in a category on one is in it on the other.

Nothing in `sync_state` or `outbox` on the device is ever uploaded. Those are
device-local: which backend this phone points at, how far its pull has got, what
it still owes, and which categories *that phone's* due list is filtered to —
deliberately not shared, because two phones can reasonably be looking at two
different slices of the same work.

`due_date` and `last_completed_at` are here, and they are *not* what the other
device believes. They are derived caches (ADR 0004), replicated only because
they are columns of the row; each device recomputes them from its own copy of
the completion log after every pull. If you edit one in the Table Editor, the
next sync on either phone will overwrite it with arithmetic.

### Categories and memberships

`task_categories` is the join table, and it has an `id` of its own where
PLAN.md's schema block gives it a composite key. That is sync's doing: every row
sync moves is addressed by a single `id` — the outbox, the pull cursor and the
conditional `PATCH` all assume one. The pair stays unique as a constraint, so a
membership added on both phones converges on one row rather than two.

Neither column is a foreign key, on either side, for the reason ADR 0011 gives:
rows are pulled per table in no guaranteed order, so a membership can arrive
before the task or the category it names. Expect to see rows in the Table Editor
whose `category_id` matches nothing yet. The app treats those as "not in any
category" and they resolve themselves on the next pull.

Deleting a category is soft, like everything else, and it deletes no work: the
tasks are untouched and only the membership rows are tombstoned alongside it. As
with completions, expect both tables to hold rows you have "deleted" — that is
the design, and hard-deleting one in the Table Editor would let the other phone
resurrect it.

### Completions merge rather than resolve

`completions` is an append-only log, which is what lets two phones that were
both offline reconcile with no conflict resolution at all (ADR 0004). Two
devices' copies of one completion are byte-identical and carry the same
`updated_at`, so neither wins and neither has to.

The one thing that ever changes on a completion is its tombstone — `deleted_at`,
set when the work is taken back or corrected — and `updated_at` moves with it,
which is the only reason that column exists. A tombstone outranks a live row
whatever its timestamp, so taking a completion back on one phone cannot be
undone by the other pushing its untombstoned copy.

Correcting a completion writes two rows, not one: the original is tombstoned and
a replacement is appended. Expect the table to hold rows you have "deleted" —
that is the design, and hard-deleting one in the Table Editor would let the
other device resurrect it on its next push.
