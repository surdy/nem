import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/local_rows.dart';
import 'package:nem/src/sync/synced_table.dart';

void main() {
  late NemDatabase db;
  late LocalRows rows;
  late SyncedTable tasks;
  late SyncCodec codec;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    rows = LocalRows(db);
    tasks = SyncedTable(db.tasks);
    codec = SyncCodec(tasks, rows.types);
  });

  tearDown(() => db.close());

  test('the descriptor reads the table out of drift rather than a list', () {
    expect(tasks.name, 'tasks');
    expect(tasks.clockColumn, 'updated_at');
    expect(tasks.hasSoftDelete, isTrue);
    // Including the columns added since #11 was written: a new column is picked
    // up by regenerating, not by editing anything here.
    expect(
      tasks.columnNames,
      containsAll(<String>[
        'id',
        'title',
        'target_id',
        'schedule_mode',
        'start_date',
        'snoozed_until',
        'is_archived',
        'created_at',
        'updated_at',
        'deleted_at',
      ]),
    );
  });

  test('drift integers become the JSON Postgres expects', () async {
    final task = await TaskRepository(db).createFloatingTask(
      title: 'Replace the water filter',
      notes: 'Under the sink',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9, 30),
    );

    final json = codec.toRemote((await rows.read(tasks, task.id))!);

    expect(json['id'], task.id);
    expect(json['title'], 'Replace the water filter');
    expect(json['notes'], 'Under the sink');
    // A timestamp goes up as a `timestamptz` literal, never as drift's seconds.
    expect(
      json['updated_at'],
      DateTime(2026, 6, 1, 9, 30).toUtc().toIso8601String(),
    );
    // A boolean goes up as a boolean, not as 0 or 1.
    expect(json['is_archived'], isFalse);
    // An enum column goes up as the name drift stored.
    expect(json['schedule_mode'], 'floating');
    expect(json['interval_unit'], 'day');
    expect(json['deleted_at'], isNull);
  });

  test('JSON comes back as the values drift stores', () async {
    final local = codec.toLocal({
      'id': 'task-1',
      'title': 'Bleed the radiators',
      'schedule_mode': 'floating',
      'interval_n': 30,
      'interval_unit': 'day',
      'start_date': '2026-06-01T00:00:00.000Z',
      'is_archived': true,
      'created_at': '2026-06-01T09:00:00.000Z',
      'updated_at': '2026-06-01T09:00:00.000Z',
      'deleted_at': null,
    });

    expect(local['is_archived'], 1);
    expect(
      local['updated_at'],
      DateTime.utc(2026, 6, 1, 9).millisecondsSinceEpoch ~/ 1000,
    );
    expect(local['interval_n'], 30);
    expect(local['deleted_at'], isNull);
  });

  test('a whole number arriving as a JSON double is still an integer', () {
    // JSON has no integer type, so a backend, a proxy or a codec is entitled to
    // hand back `30.0`. Binding that to an INTEGER column would store a REAL.
    final local = codec.toLocal({'id': 'task-1', 'interval_n': 30.0});
    expect(local['interval_n'], 30);
    expect(local['interval_n'], isA<int>());
  });

  test('a column the backend did not send is left alone, not blanked', () {
    // An older migration on the server is a reason to write less, never a
    // reason to erase what this device knows.
    final local = codec.toLocal({'id': 'task-1', 'title': 'Only these two'});
    expect(local.keys, ['id', 'title']);
  });

  test('a row survives the round trip unchanged', () async {
    final task = await TaskRepository(db).createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 3,
      intervalUnit: IntervalUnit.month,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9, 30),
    );

    final raw = (await rows.read(tasks, task.id))!;
    expect(codec.toLocal(codec.toRemote(raw)), raw);
  });
}
