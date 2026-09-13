import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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

  /// Wall-clock "HH:mm"; per-task reminders arrive in P4.
  TextColumn get reminderTime => text().nullable()();

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

/// The `sync_state` table from PLAN.md — device-local key/value state.
///
/// Sync itself is P3, but the device id it holds is needed now: every
/// completion records the device that wrote it.
class SyncState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(tables: [Tasks, Completions, Targets, SyncState])
class NemDatabase extends _$NemDatabase {
  NemDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'nem'));

  @override
  int get schemaVersion => 3;

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
    },
    beforeOpen: (details) async {
      // Runs on EVERY open, not only after a migration — keep it to per-open
      // connection setup. Recomputation of derived state belongs to an explicit
      // launch-time call, not here.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
