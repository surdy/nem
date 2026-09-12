import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../domain/interval_unit.dart';
import '../domain/task.dart';

part 'database.g.dart';

/// The `tasks` table from PLAN.md.
///
/// The floating columns (`interval_n`, `interval_unit`) and the fixed column
/// (`rrule`) are mutually exclusive nullable sets, deliberately not unified
/// (ADR 0005). `rrule` is present but unused until fixed schedules land.
@DataClassName('TaskRow')
@TableIndex(name: 'idx_tasks_due_date', columns: {#dueDate})
@TableIndex(name: 'idx_tasks_deleted_at', columns: {#deletedAt})
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();

  /// Targets arrive in P2; no foreign key yet because the table does not exist.
  TextColumn get targetId => text().nullable()();

  TextColumn get scheduleMode => textEnum<ScheduleMode>()();

  // Floating only.
  IntColumn get intervalN => integer().nullable()();
  TextColumn get intervalUnit => textEnum<IntervalUnit>().nullable()();

  // Fixed only.
  TextColumn get rrule => text().nullable()();

  DateTimeColumn get startDate => dateTime()();

  /// Derived cache, denormalised so the due list is one indexed query
  /// (PLAN.md). Never authoritative — see ADR 0004.
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// Derived cache of the latest completion (ADR 0004).
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

@DriftDatabase(tables: [Tasks])
class NemDatabase extends _$NemDatabase {
  NemDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'nem'));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // No migrations yet; this is schema version 1.
    },
    beforeOpen: (details) async {
      // Runs on EVERY open, not only after a migration — keep it to per-open
      // connection setup. Recomputation of derived state belongs to an explicit
      // launch-time call, not here.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
