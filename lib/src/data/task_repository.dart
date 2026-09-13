import 'dart:math';

import 'package:drift/drift.dart';

import '../domain/interval_unit.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';
import 'database.dart';

/// Reads and writes tasks, and keeps the derived `due_date` cache in step.
///
/// The cache exists only so the due list can sort in SQL (PLAN.md). Every value
/// the UI shows is recomputed from the schedule on read, so a stale cache can
/// misorder the list but can never display a wrong due date (ADR 0004).
class TaskRepository {
  TaskRepository(this._db);

  final NemDatabase _db;

  /// Live tasks, soonest due first.
  Stream<List<Task>> watchDueList() {
    final query = _db.select(_db.tasks)
      ..where((t) => t.deletedAt.isNull() & t.isArchived.equals(false))
      ..orderBy([
        (t) => OrderingTerm(expression: t.dueDate),
        (t) => OrderingTerm(expression: t.title),
      ]);
    return query.watch().map((rows) => rows.map(_toDomain).toList());
  }

  Future<List<Task>> allTasks() async {
    final rows = await (_db.select(
      _db.tasks,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.map(_toDomain).toList();
  }

  /// Creates a task with a floating schedule.
  Future<Task> createFloatingTask({
    required String title,
    String? notes,
    required int intervalN,
    required IntervalUnit intervalUnit,
    required DateTime startDate,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final schedule = FloatingSchedule(
      intervalN: intervalN,
      intervalUnit: intervalUnit,
      startDate: startDate,
    );
    final task = Task(
      id: _newId(),
      title: title,
      notes: (notes == null || notes.trim().isEmpty) ? null : notes.trim(),
      scheduleMode: ScheduleMode.floating,
      floatingSchedule: schedule,
      startDate: startDate,
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    await _db
        .into(_db.tasks)
        .insert(
          TasksCompanion.insert(
            id: task.id,
            title: task.title,
            notes: Value(task.notes),
            scheduleMode: ScheduleMode.floating,
            intervalN: Value(intervalN),
            intervalUnit: Value(intervalUnit),
            startDate: startDate,
            // Written on every mutation that could invalidate it (PLAN.md).
            dueDate: Value(task.dueDate),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return task;
  }

  /// Recomputes the `due_date` cache for every task.
  ///
  /// PLAN.md requires this on app launch, after every sync pull, and on every
  /// write that could invalidate it. It is called explicitly rather than from
  /// `beforeOpen`, which fires on every database open.
  Future<int> recomputeDueDates() async {
    final rows = await (_db.select(
      _db.tasks,
    )..where((t) => t.deletedAt.isNull())).get();
    var updated = 0;
    await _db.batch((batch) {
      for (final row in rows) {
        final due = _toDomain(row).dueDate;
        if (due == row.dueDate) continue;
        updated++;
        batch.update(
          _db.tasks,
          TasksCompanion(dueDate: Value(due)),
          where: (t) => t.id.equals(row.id),
        );
      }
    });
    return updated;
  }

  Task _toDomain(TaskRow row) {
    final intervalN = row.intervalN;
    final intervalUnit = row.intervalUnit;
    return Task(
      id: row.id,
      title: row.title,
      notes: row.notes,
      targetId: row.targetId,
      scheduleMode: row.scheduleMode,
      floatingSchedule:
          (row.scheduleMode == ScheduleMode.floating &&
              intervalN != null &&
              intervalUnit != null)
          ? FloatingSchedule(
              intervalN: intervalN,
              intervalUnit: intervalUnit,
              startDate: row.startDate,
            )
          : null,
      rrule: row.rrule,
      startDate: row.startDate,
      lastCompletedAt: row.lastCompletedAt,
      reminderTime: row.reminderTime,
      isArchived: row.isArchived,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}

final _random = Random.secure();

/// A RFC 4122 version 4 identifier.
String _newId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
