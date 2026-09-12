# nem — build plan

Implementation plan. Vocabulary lives in [CONTEXT.md](./CONTEXT.md); the
decisions behind this shape live in [docs/adr](./docs/adr) and are referenced,
not restated, below.

Flutter, iOS + Android, one person on two devices.

---

## Decisions

| ADR | Decision |
|---|---|
| [0001](./docs/adr/0001-local-first-sqlite-is-the-source-of-truth.md) | Local-first: SQLite is the source of truth |
| [0002](./docs/adr/0002-speak-the-supabase-api-directly.md) | Speak the Supabase API directly, no backend abstraction |
| [0003](./docs/adr/0003-one-user-no-account-model.md) | One user, no account model |
| [0004](./docs/adr/0004-completions-are-immutable-events.md) | Completions are immutable events; schedule state is derived |
| [0005](./docs/adr/0005-two-schedule-modes.md) | Two schedule modes: floating and fixed |
| [0006](./docs/adr/0006-store-fixed-schedules-as-rrule.md) | Store fixed schedules as RRULE, author through a narrower editor |
| [0007](./docs/adr/0007-missed-occurrences-collapse.md) | Missed occurrences collapse; due date pins to the earliest missed |
| [0008](./docs/adr/0008-a-tag-identifies-a-target-not-a-task.md) | A tag identifies a target, not a task |
| [0009](./docs/adr/0009-custom-uri-scheme-forgoing-ios-background-scanning.md) | Custom URI scheme on tags, forgoing iOS background scanning |
| [0010](./docs/adr/0010-recurrence-expands-in-floating-wall-clock-time.md) | Recurrence expands in floating wall-clock time, resolved per occurrence |

Settled without an ADR, because each is either obvious or cheap to reverse:
Flutter as the stack, iOS + Android as targets, the daily digest plus per-task
reminders, provisioning by writing tags / generating labels / binding barcodes,
instant completion with undo, no completion when nothing is due, reference photos
on tasks, categories and notes as task fields, no checklists, and the
Overdue → Today → Soon home screen.

---

## Due date engine

**Floating** — `due_date = (last_completion ?? start_date) + interval`.

**Fixed** — `due_date = earliest occurrence strictly after the last completed
occurrence`. Note this is not "the next future occurrence"; see ADR 0007.

Both are recomputed on app launch, after every sync pull, and on every write that
could invalidate them. They are caches (ADR 0004), never authoritative.

States: `overdue` (due date in the past, badge shows the day count),
`due_today`, `upcoming`.

---

## Schema

Local SQLite via drift is authoritative; the Postgres schema mirrors it.

```sql
targets(
  id uuid pk, name text, description text,
  created_at, updated_at, deleted_at
)

bindings(
  id uuid pk, target_id uuid fk,
  kind text check (kind in ('tag','label','barcode')),
  value text,               -- our uuid for tag/label, raw code for barcode
  created_at, updated_at, deleted_at,
  unique(kind, value)
)

tasks(
  id uuid pk, title text, notes text,
  target_id uuid fk null,
  schedule_mode text check (schedule_mode in ('floating','fixed')),
  interval_n int null, interval_unit text null,   -- floating only
  rrule text null,                                -- fixed only
  start_date date,
  due_date timestamptz,           -- derived cache
  last_completed_at timestamptz null,             -- derived cache
  reminder_time time null,
  is_archived bool default false,
  created_at, updated_at, deleted_at
)

categories(id uuid pk, name text, color int, created_at, updated_at, deleted_at)
task_categories(task_id uuid, category_id uuid, primary key(task_id, category_id))

completions(                      -- append-only, see ADR 0004
  id uuid pk, task_id uuid fk,
  completed_at timestamptz,
  source text check (source in ('manual','tag','label','barcode')),
  note text null,
  device_id text,
  created_at, deleted_at          -- deleted_at tombstones a correction
)

photos(
  id uuid pk, task_id uuid fk,
  storage_path text null,         -- Supabase Storage key
  local_path text null,           -- on-device cache
  created_at, updated_at, deleted_at
)

sync_state(key text pk, value text)   -- pull cursor, device id
```

A task's two schedule representations are mutually exclusive nullable column
sets (ADR 0005). `due_date` is denormalised so the due list is one indexed query.

---

## Sync

- **Auth**: email magic link, one account, signed in on both devices.
- **Pull**: `where updated_at > cursor` per table, on foreground plus a realtime
  subscription when connected.
- **Push**: an outbox of pending mutations, drained on connectivity.
- **Conflicts**: completions append and merge freely. Everything else is
  last-write-wins on `updated_at`. Deletes are soft so a delete beats a stale
  update.
- **Backend swap**: base URL and anon key are settings fields (ADR 0002).

---

## Scanning

### Resolution

```
scan → raw value
     → binding (uuid parsed from nem://t/<uuid>, or a raw barcode string)
     → target
     → tasks at that target, filtered to due or overdue
```

| tasks due | behaviour |
|---|---|
| exactly 1 | complete immediately, haptic, toast, 5s undo |
| 2+ | bottom sheet listing them, tick individually |
| 0 | target detail sheet — all tasks and their due dates, nothing completed |
| unknown code | offer to bind it to a target |

A repeat scan of the same target within 30 seconds is ignored, so a fumbled tap
cannot double-log.

### Platform specifics

**Android** — an `NDEF_DISCOVERED` intent filter on `android:scheme="nem"` gives
tap-to-launch from closed.

**iOS** — no tap-to-launch by design (ADR 0009). Open nem, then scan. Requires
the Core NFC entitlement, `NFCReaderUsageDescription`, and a **paid Apple
Developer Program membership ($99/yr)** — which is also what keeps the build
installed beyond 7 days. Android carries no equivalent cost.

### Provisioning

Per target: write a blank NTAG215/216 with `nem://t/<uuid>`; render the same URI
as a label, exportable as PNG/PDF; or bind an existing product barcode.

---

## Phases

Each ends with something usable.

**P1 — a working tracker.** Flutter project, drift schema, task CRUD, both
schedule modes, the RRULE editor, the due list, manual completion with undo,
daily digest. No sync, no scanning, one phone.

Goal: discover within a week whether the scheduling model fits your life, before
anything is built on top of it.

**P2 — the scan.** Targets, bindings, NFC read and write, label generation, QR
and barcode scanning, the resolution flow above, Android intent filter, iOS
entitlement and scan screen.

**P3 — two devices.** Supabase project, Postgres schema and RLS, magic-link auth,
outbox push, cursor pull, realtime, and the settings screen that makes the
self-hosted swap a field edit.

**P4 — the rest.** Categories and filtering, notes, reference photos with an
upload queue, per-task reminder times, history and streaks, snooze, archive.

---

## Assumptions

Not yet challenged. Flag any and I'll change it before P1.

1. Auth is email magic link — no password, no anonymous-plus-device-code flow.
2. State management is Riverpod 3, using manual providers rather than
   `@riverpod` codegen — Riverpod 3 reversed its own guidance and now
   recommends codegen only when build_runner is already in play.
3. Fixed schedules expand as floating wall-clock times and are resolved to an
   instant per occurrence against a stored IANA zone id; completions stored
   UTC. See ADR 0010.
4. The iOS 64-pending-notification cap is handled by a rolling window, re-topped
   on foreground and verified against `pendingNotificationRequests().length`.
   Where a schedule maps onto `matchDateTimeComponents` (a plain weekly or
   monthly time), one OS-level repeating notification is used instead of
   expanding the rule into many — one slot rather than fifty-two.
5. Blank tags are NTAG215/216.
6. No widget, no watch app, no Siri or Assistant integration in any phase.

---

## Dependencies

| package | purpose |
|---|---|
| `drift` | local SQLite, typed queries, migrations |
| `rrule` | RFC 5545 parsing and occurrence expansion |
| `nfc_manager` | NFC read and NDEF write, both platforms |
| `mobile_scanner` | camera QR and barcode capture |
| `qr_flutter` | label rendering |
| `flutter_local_notifications` + `timezone` | digest and reminders |
| `supabase_flutter` | auth, Postgres, realtime, storage |
| `flutter_riverpod` | state management |
