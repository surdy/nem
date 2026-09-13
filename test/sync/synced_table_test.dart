import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/local_rows.dart';
import 'package:nem/src/sync/sync_engine.dart';
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

  test('every domain table is registered, on the same clock and with a soft '
      'delete', () {
    final registered = defaultSyncedTables(db);

    // Registration is the whole of joining sync (#12, #14, #15): a table that
    // is not in this list is not synced, however many repositories write to
    // it.
    expect(
      [for (final table in registered) table.name],
      containsAll(<String>[
        'targets',
        'categories',
        'tasks',
        'bindings',
        'task_categories',
        'completions',
        // A photo's row. Its *bytes* are not here and never will be: they go
        // through `photos/photo_sync.dart`, because the outbox is a dirty set
        // of rows and a row is not a megabyte.
        'photos',
      ]),
    );
    for (final table in registered) {
      expect(table.clockColumn, 'updated_at', reason: table.name);
      expect(table.hasSoftDelete, isTrue, reason: table.name);
      // The membership join table included: sync addresses every row it moves
      // by a single `id`, which is why `task_categories` has one at all rather
      // than the composite key PLAN.md's schema block gives it.
      expect(table.columnNames, contains('id'), reason: table.name);
      // The seed walks every table in `created_at` order.
      expect(table.columnNames, contains('created_at'), reason: table.name);
    }
  });

  test('a device-local column is left out of the wire shape in both '
      'directions', () async {
    // `photos.local_path` is the name of the cache file holding the bytes on
    // *this* phone. The row is shared; whether a given device has the bytes on
    // disk is not, so sync neither pushes it nor applies it (#15).
    final photos = SyncedTable(
      db.photos,
      deviceLocalColumns: const {'local_path'},
    );
    final codec = SyncCodec(photos, rows.types);

    expect(photos.columnNames, contains('local_path'));
    expect([
      for (final c in photos.syncedColumns) c.name,
    ], isNot(contains('local_path')));

    final local = {
      'id': 'photo-1',
      'task_id': 'task-1',
      'storage_path': 'task-1/photo-1.jpg',
      'local_path': 'photo-1.jpg',
      'created_at': 1,
      'updated_at': 1,
      'deleted_at': null,
    };

    // Out: the column simply is not in the JSON. The Postgres table does not
    // have it, so sending it would be a 400 rather than a harmless extra.
    expect(codec.toRemote(local).containsKey('local_path'), isFalse);

    // In: a backend that sends it anyway — a hand-added column, a future
    // build — cannot make this device believe it holds a file it has never
    // downloaded.
    final applied = codec.toLocal({
      ...codec.toRemote(local),
      'local_path': 'somewhere-else',
    });
    expect(applied.containsKey('local_path'), isFalse);
    expect(applied['storage_path'], 'task-1/photo-1.jpg');
  });
}
