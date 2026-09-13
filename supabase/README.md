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
   `migrations/20260913000000_nem_schema.sql`, and run it. It is idempotent —
   every statement is `if not exists` or `drop … if exists` first — so running
   it twice is safe.
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

#11 syncs `tasks`. Completions, targets and bindings are #12 — their tables are
created here so the schema mirrors the device, and the app simply does not push
or pull them yet.

Nothing in `sync_state` or `outbox` on the device is ever uploaded. Those are
device-local: which backend this phone points at, how far its pull has got, and
what it still owes.
