import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';

/// The schema version 1 `tasks` table, exactly as drift created it before
/// completions existed. A device upgrading from the first build has this on
/// disk.
const _v1Schema = [
  'CREATE TABLE "tasks" ("id" TEXT NOT NULL, "title" TEXT NOT NULL, '
      '"notes" TEXT NULL, "target_id" TEXT NULL, "schedule_mode" TEXT NOT NULL, '
      '"interval_n" INTEGER NULL, "interval_unit" TEXT NULL, "rrule" TEXT NULL, '
      '"start_date" INTEGER NOT NULL, "due_date" INTEGER NULL, '
      '"last_completed_at" INTEGER NULL, "reminder_time" TEXT NULL, '
      '"is_archived" INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("is_archived" IN (0, 1)), "created_at" INTEGER NOT NULL, '
      '"updated_at" INTEGER NOT NULL, "deleted_at" INTEGER NULL, '
      'PRIMARY KEY ("id"))',
  'CREATE INDEX idx_tasks_due_date ON tasks (due_date)',
  'CREATE INDEX idx_tasks_deleted_at ON tasks (deleted_at)',
  'PRAGMA user_version = 1',
];

/// What schema version 2 added on top of [_v1Schema] — the completion log and
/// its device-local state. A device that took the completions build but not
/// this one has this on disk.
const _v2Schema = [
  ..._v1Schema,
  'CREATE TABLE "completions" ("id" TEXT NOT NULL, '
      '"task_id" TEXT NOT NULL REFERENCES tasks (id), '
      '"completed_at" INTEGER NOT NULL, "source" TEXT NOT NULL, '
      '"note" TEXT NULL, "device_id" TEXT NOT NULL, '
      '"created_at" INTEGER NOT NULL, "deleted_at" INTEGER NULL, '
      'PRIMARY KEY ("id"))',
  'CREATE TABLE "sync_state" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, '
      'PRIMARY KEY ("key"))',
  'CREATE INDEX idx_completions_task_id ON completions (task_id)',
  'CREATE INDEX idx_completions_deleted_at ON completions (deleted_at)',
  'PRAGMA user_version = 2',
];

/// Inserts the one task every migration test starts from.
const _insertTask =
    'INSERT INTO tasks (id, title, schedule_mode, interval_n, '
    'interval_unit, start_date, due_date, is_archived, created_at, '
    'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)';

int _seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

void main() {
  test('upgrading from version 1 adds completions and keeps the '
      'tasks that were already there', () async {
    final startDate = DateTime(2026, 3, 1, 9);
    final dueDate = DateTime(2026, 3, 31, 9);
    final created = DateTime(2026, 2, 20, 8);

    final db = NemDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final statement in _v1Schema) {
            raw.execute(statement);
          }
          raw.execute(
            'INSERT INTO tasks (id, title, schedule_mode, interval_n, '
            'interval_unit, start_date, due_date, is_archived, created_at, '
            'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
            [
              'task-1',
              'Replace the water filter',
              'floating',
              30,
              'day',
              startDate.millisecondsSinceEpoch ~/ 1000,
              dueDate.millisecondsSinceEpoch ~/ 1000,
              created.millisecondsSinceEpoch ~/ 1000,
              created.millisecondsSinceEpoch ~/ 1000,
            ],
          );
        },
      ),
    );
    addTearDown(db.close);

    final repository = TaskRepository(db);

    // The migration runs on first use. The task survives it — a wipe would take
    // the completion log with it, and that log is the only truth there is
    // (ADR 0004).
    final task = (await repository.allTasks()).single;
    expect(task.id, 'task-1');
    expect(task.title, 'Replace the water filter');
    expect(task.floatingSchedule?.intervalN, 30);
    expect(task.floatingSchedule?.intervalUnit, IntervalUnit.day);
    expect(task.startDate, startDate);
    expect(task.dueDate, dueDate);
    expect(task.lastCompletedAt, isNull);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, 3);

    // And the new tables are usable, indexes and foreign key included.
    final completion = await repository.recordCompletion(
      'task-1',
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );
    expect(completion.deviceId, isNotEmpty);
    expect(
      (await repository.allTasks()).single.dueDate,
      DateTime(2026, 4, 4, 9),
    );

    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'completions'",
        )
        .get();
    expect(
      indexes.map((row) => row.data['name']),
      containsAll(<String>[
        'idx_completions_task_id',
        'idx_completions_deleted_at',
      ]),
    );
  });

  test('upgrading from version 2 adds targets and keeps the '
      'completion log', () async {
    final startDate = DateTime(2026, 3, 1, 9);
    final dueDate = DateTime(2026, 3, 31, 9);
    final completedAt = DateTime(2026, 3, 5, 9);

    final db = NemDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final statement in _v2Schema) {
            raw.execute(statement);
          }
          raw.execute(_insertTask, [
            'task-1',
            'Replace the water filter',
            'floating',
            30,
            'day',
            _seconds(startDate),
            _seconds(dueDate),
            _seconds(startDate),
            _seconds(startDate),
          ]);
          raw.execute(
            'INSERT INTO completions (id, task_id, completed_at, source, '
            'device_id, created_at) VALUES (?, ?, ?, ?, ?, ?)',
            [
              'completion-1',
              'task-1',
              _seconds(completedAt),
              'manual',
              'device-1',
              _seconds(completedAt),
            ],
          );
        },
      ),
    );
    addTearDown(db.close);

    // The append-only log is untouched by the upgrade (ADR 0004), and the due
    // date still derives from it.
    final task = (await TaskRepository(db).allTasks()).single;
    expect(task.id, 'task-1');
    expect(task.lastCompletedAt, completedAt);
    expect(task.dueDate, DateTime(2026, 4, 4, 9));
    expect(task.targetId, isNull);

    // And the table version 3 adds is usable, with the task attachable to it.
    final targets = TargetRepository(db);
    final target = await targets.createTarget(name: 'The boiler');
    expect((await targets.allTargets()).single.id, target.id);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, 3);
  });
}
