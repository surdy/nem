import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../domain/binding.dart';
import '../domain/completion.dart';
import '../domain/interval_unit.dart';
import '../domain/task.dart';

part 'database.g.dart';

/// The `tasks` table from PLAN.md.
///
/// The floating columns (`interval_n`, `interval_unit`) and the fixed column
/// (`rrule`) are mutually exclusive nullable sets, deliberately not unified
/// (ADR 0005).
@DataClassName('TaskRow')
@TableIndex(name: 'idx_tasks_due_date', columns: {#dueDate})
@TableIndex(name: 'idx_tasks_deleted_at', columns: {#deletedAt})
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();

  /// The target this task is done on (ADR 0008). Optional — plenty of work is
  /// not attached to anything physical.
  ///
  /// No SQLite foreign key. Deletes are soft, so a referenced target row never
  /// actually disappears, and once sync arrives a pull can legitimately deliver
  /// a task before the target it names (PLAN.md — Sync). A constraint would
  /// reject that ordering; the repository keeps the reference honest instead.
  TextColumn get targetId => text().nullable()();

  TextColumn get scheduleMode => textEnum<ScheduleMode>()();

  // Floating only.
  IntColumn get intervalN => integer().nullable()();
  TextColumn get intervalUnit => textEnum<IntervalUnit>().nullable()();

  /// Fixed only: an RFC 5545 `DTSTART` line and an `RRULE` line (ADR 0006).
  ///
  /// The `DTSTART` carries the wall-clock anchor and the IANA zone id that
  /// ADR 0010 requires, which is why this one text column is the whole fixed
  /// representation and there is no separate zone column to migrate to. See
  /// `FixedSchedule.encode`.
  TextColumn get rrule => text().nullable()();

  DateTimeColumn get startDate => dateTime()();

  /// Derived cache, denormalised so the due list is one indexed query
  /// (PLAN.md). Never authoritative — see ADR 0004.
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// Derived cache of the latest live completion (ADR 0004). The authoritative
  /// answer is `MAX(completed_at)` over [Completions]; this column exists so
  /// the value is cheap to sort and show, and is recomputed, never trusted.
  DateTimeColumn get lastCompletedAt => dateTime().nullable()();

  /// The wall-clock "HH:mm" a task reminds at, null when it has not opted in
  /// (CONTEXT.md — "Reminder").
  ///
  /// Declared in the original scaffold and unused until issue #16, so wiring
  /// reminders up needed no migration. Read through `ReminderTime.tryParse`,
  /// which treats an unreadable value as no reminder rather than throwing on
  /// the launch path.
  TextColumn get reminderTime => text().nullable()();

  /// The date a snooze pushed this task out to, or null if it is not snoozed.
  ///
  /// **Not** a derived cache, and the one column on this table that a snooze
  /// could not have lived in otherwise: [dueDate] is rewritten from the
  /// schedule and the completion log by `recomputeDerivedState` on every launch
  /// and after every sync pull (ADR 0004), so a snooze written there would be
  /// erased within a launch. Stored here instead, where nothing derives it, it
  /// is an *input* to that recomputation rather than a casualty of it — see
  /// `domain/snooze.dart`.
  DateTimeColumn get snoozedUntil => dateTime().nullable()();

  /// When [snoozedUntil] was set.
  ///
  /// A completion recorded for later work supersedes the snooze, and this is
  /// what that comparison is against. Nothing is cleared to make it happen, so
  /// tombstoning that completion brings the snooze back (ADR 0004).
  DateTimeColumn get snoozedAt => dateTime().nullable()();

  /// Retired, but kept: an archived task is off the due list and out of the
  /// digest, and its completion log is untouched.
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `completions` table from PLAN.md.
///
/// Append-only (ADR 0004). Rows are inserted and never updated: taking a
/// completion back sets [deletedAt], and correcting one tombstones the row and
/// appends a replacement. Nothing in the repository rewrites `completed_at`,
/// `source` or `note`, which is what lets two devices merge their logs with no
/// conflict resolution at all.
@DataClassName('CompletionRow')
@TableIndex(name: 'idx_completions_task_id', columns: {#taskId})
@TableIndex(name: 'idx_completions_deleted_at', columns: {#deletedAt})
class Completions extends Table {
  TextColumn get id => text()();

  TextColumn get taskId => text().references(Tasks, #id)();

  /// When the work was done, which is not necessarily when the row was written.
  DateTimeColumn get completedAt => dateTime()();

  /// Constrained to the values of [CompletionSource], stored by name so later
  /// sources are additive.
  TextColumn get source => textEnum<CompletionSource>()();

  TextColumn get note => text().nullable()();

  /// Which device recorded this (PLAN.md — "Sync").
  TextColumn get deviceId => text()();

  DateTimeColumn get createdAt => dateTime()();

  /// Tombstones a correction (PLAN.md). A tombstoned completion no longer
  /// counts towards a task's derived state.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `targets` table from PLAN.md.
///
/// A target is a physical place or object work is done on (CONTEXT.md). Tasks
/// point at it through `tasks.target_id`, and bindings will point at it from the
/// other side in P2 (ADR 0008).
@DataClassName('TargetRow')
@TableIndex(name: 'idx_targets_deleted_at', columns: {#deletedAt})
class Targets extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `bindings` table from PLAN.md.
///
/// One scannable code, one target (CONTEXT.md — "Binding"; ADR 0008). The
/// uniqueness is on `(kind, value)` rather than on `value` alone, because a
/// target can wear a tag and a printed label at once and both carry the same
/// `nem://t/<uuid>` — two rows, two kinds, one value, one target.
@DataClassName('BindingRow')
@TableIndex(name: 'idx_bindings_target_id', columns: {#targetId})
@TableIndex(name: 'idx_bindings_deleted_at', columns: {#deletedAt})
@TableIndex(
  name: 'idx_bindings_kind_value',
  columns: {#kind, #value},
  unique: true,
)
class Bindings extends Table {
  TextColumn get id => text()();

  /// The target this code resolves to.
  ///
  /// No SQLite foreign key, for exactly the reasons `tasks.target_id` has none
  /// (ADR 0011): deletes are soft, so the row it names never actually goes
  /// away, and a sync pull can legitimately deliver a binding before the target
  /// it points at — a constraint would reject that pull and leave the device
  /// unable to converge. A binding whose target does not resolve is handled as
  /// an unknown code, not as corruption.
  TextColumn get targetId => text()();

  /// Constrained to the values of [BindingKind], stored by name.
  TextColumn get kind => textEnum<BindingKind>()();

  /// Our uuid for a tag or a label, the raw product code for a barcode.
  TextColumn get value => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  ///
  /// A tombstoned row still occupies its `(kind, value)` slot in the unique
  /// index — deliberately. Re-binding a code that was unbound re-points the row
  /// that is already there rather than inserting a second one, which is also
  /// what keeps the other device's copy of that binding converging on one row.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `sync_state` table from PLAN.md — device-local key/value state.
///
/// Holds the device id every completion records, the digest's configuration,
/// the Supabase base URL and anon key (ADR 0002), and the per-table pull
/// cursors. Never pushed: sync moves rows of the domain tables, and this is
/// not one of them.
class SyncState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Rows this device has changed and not yet pushed (PLAN.md — Sync).
///
/// A *dirty set*, not a log of mutations: an entry names a row, and the push
/// reads that row's current state out of SQLite when it drains. That is what
/// makes it right rather than merely cheap — SQLite is the source of truth
/// (ADR 0001), so the only thing worth sending is what the row says *now*.
/// Editing a task five times offline leaves one entry and pushes once, and a
/// replayed or duplicated drain cannot resurrect an intermediate value that no
/// longer exists anywhere.
///
/// The primary key is `(table_name, row_id)`, which is what collapses those
/// five edits into one entry. [enqueuedAt] is the *first* time the row went
/// dirty and is not bumped by later edits, so the drain order is the order the
/// rows were first touched — a task is pushed before a completion recorded
/// against it.
@DataClassName('OutboxRow')
@TableIndex(name: 'idx_outbox_enqueued_at', columns: {#enqueuedAt})
class Outbox extends Table {
  /// The SQL name of the table the row lives in — `tasks`, and from #12 the
  /// rest. Named explicitly because drift's `Table` already owns the
  /// `tableName` getter.
  TextColumn get pendingTable => text().named('table_name')();

  TextColumn get rowId => text()();

  DateTimeColumn get enqueuedAt => dateTime()();

  /// How many drains have tried and failed on this row. Kept for the backoff
  /// and so a row that can never be pushed is visible rather than silent.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// The last failure's message, for the same reason.
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {pendingTable, rowId};
}

@DriftDatabase(
  tables: [Tasks, Completions, Targets, Bindings, SyncState, Outbox],
)
class NemDatabase extends _$NemDatabase {
  NemDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'nem'));

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // Migrations only ever add. A wipe-and-recreate would destroy the
      // completion log, and the log is the only authoritative record nem has —
      // due dates are derived from it (ADR 0004) and cannot be reconstructed
      // from anything else on the device.
      if (from < 2) {
        await m.createTable(completions);
        await m.createTable(syncState);
        await m.create(idxCompletionsTaskId);
        await m.create(idxCompletionsDeletedAt);
      }
      // v3 adds `targets`. `tasks.target_id` has been declared since v1, so
      // nothing on `tasks` changes — the column simply starts being used.
      if (from < 3) {
        await m.createTable(targets);
        await m.create(idxTargetsDeletedAt);
      }
      // v4 adds `bindings`, so a scanned code can name a target. Nothing else
      // changes: targets and tasks are untouched, and a device that never
      // scans anything simply has an empty table.
      if (from < 4) {
        await m.createTable(bindings);
        await m.create(idxBindingsTargetId);
        await m.create(idxBindingsDeletedAt);
        await m.create(idxBindingsKindValue);
      }
      // v5 adds the two snooze columns. Both are nullable with no default, so
      // every existing task reads as "never snoozed" and nothing on disk is
      // rewritten. `is_archived` has been declared since v1 and needs no
      // migration — archive only starts using it.
      if (from < 5) {
        await m.addColumn(tasks, tasks.snoozedUntil);
        await m.addColumn(tasks, tasks.snoozedAt);
      }
      // v6 adds the outbox (#11). Nothing on any existing table changes, and
      // the table starts empty rather than pre-filled: a device upgrading into
      // this build has no backend configured yet, and what it already holds is
      // seeded into the outbox the first time one is (`SyncEngine.seed`), not
      // here. A device that never configures a backend simply accumulates an
      // entry per row it edits and nothing ever drains them, which costs a row
      // each and changes nothing else (ADR 0001 — the app is whole with no
      // account at all).
      if (from < 6) {
        await m.createTable(outbox);
        await m.create(idxOutboxEnqueuedAt);
      }
    },
    beforeOpen: (details) async {
      // Runs on EVERY open, not only after a migration — keep it to per-open
      // connection setup. Recomputation of derived state belongs to an explicit
      // launch-time call, not here.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
