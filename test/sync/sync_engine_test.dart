import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/outbox_store.dart';
import 'package:nem/src/sync/sync_cursor.dart';
import 'package:nem/src/sync/sync_engine.dart';
import 'package:nem/src/sync/sync_row.dart';
import 'package:nem/src/sync/sync_settings.dart';
import 'package:nem/src/sync/sync_transport.dart';

import 'fake_sync_transport.dart';
import 'task_rows.dart';

void main() {
  late NemDatabase db;
  late TaskRepository tasks;
  late SyncSettingsRepository settings;
  late OutboxStore outbox;
  late FakeSyncTransport transport;

  const backend = 'https://nem.supabase.co';

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    settings = SyncSettingsRepository(db);
    outbox = OutboxStore(db);
    transport = FakeSyncTransport();
    await settings.write(
      const SyncSettings(url: backend, anonKey: 'public-anon-key'),
    );
  });

  tearDown(() => db.close());

  SyncEngine engine({int pageSize = 200}) => SyncEngine(
    db: db,
    transport: transport,
    settings: settings,
    tasks: tasks,
    pageSize: pageSize,
  );

  Future<String> createTask({
    String title = 'Replace the water filter',
    DateTime? now,
  }) async {
    final task = await tasks.createFloatingTask(
      title: title,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: now ?? DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  group('the outbox', () {
    test('a created task is queued and pushed', () async {
      final id = await createTask();
      expect(await outbox.count(), 1);

      final report = await engine().drainOutbox();

      expect(report.pushed, 1);
      expect(report.pending, 0);
      expect(transport.row('tasks', id), isNotNull);
      expect(transport.row('tasks', id)!['title'], 'Replace the water filter');
      // And the timestamps went up as ISO-8601, not as drift's integers.
      expect(transport.row('tasks', id)!['updated_at'], isA<String>());
      expect(transport.row('tasks', id)!['is_archived'], isFalse);
    });

    test('a second drain sends nothing', () async {
      await createTask();
      await engine().drainOutbox();
      transport.inserts = 0;
      transport.updates = 0;

      final report = await engine().drainOutbox();

      expect(report.pushed, 0);
      expect(transport.inserts + transport.updates, 0);
    });

    test(
      'five edits made offline push once, carrying the last of them',
      () async {
        final id = await createTask();
        for (var day = 2; day <= 6; day++) {
          await tasks.snoozeTask(
            id,
            n: day,
            unit: IntervalUnit.day,
            now: DateTime(2026, 6, day, 9),
          );
        }

        // One entry, not six: the outbox is a set of dirty rows, so what is sent
        // is the row as it now stands rather than a replay of how it got there.
        expect(await outbox.count(), 1);
        final report = await engine().drainOutbox();
        expect(report.pushed, 1);
        expect(transport.inserts, 1);
        expect(
          transport.row('tasks', id)!['snoozed_at'],
          DateTime(2026, 6, 6, 9).toUtc().toIso8601String(),
        );
      },
    );

    test('a push loses to a newer remote copy and is dropped unsent', () async {
      final id = await createTask(now: DateTime(2026, 6, 1, 9));
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          title: 'Renamed on the other phone',
          updatedAt: DateTime(2026, 6, 2, 9),
        ),
      );

      final report = await engine().drainOutbox();

      expect(report.pushed, 0);
      expect(report.superseded, 1);
      expect(report.pending, 0, reason: 'a losing push is not retried forever');
      expect(
        transport.row('tasks', id)!['title'],
        'Renamed on the other phone',
      );
    });

    test('a delete written here beats a newer update already on the '
        'backend', () async {
      final id = await createTask(now: DateTime(2026, 6, 1, 9));
      // The other phone renamed it an hour after this one deleted it.
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          title: 'Renamed while offline',
          updatedAt: DateTime(2026, 6, 3, 10),
        ),
      );
      // There is no task delete in the app yet (#18 archives instead), so the
      // tombstone is written straight into the row, the way a completion's is
      // when it is taken back.
      await db.customStatement(
        'UPDATE tasks SET deleted_at = ?, updated_at = ? WHERE id = ?',
        [
          DateTime(2026, 6, 3, 9).millisecondsSinceEpoch ~/ 1000,
          DateTime(2026, 6, 3, 9).millisecondsSinceEpoch ~/ 1000,
          id,
        ],
      );
      await outbox.enqueue('tasks', id, now: DateTime(2026, 6, 3, 9));

      final report = await engine().drainOutbox();

      expect(report.pushed, 1);
      expect(transport.row('tasks', id)!['deleted_at'], isNotNull);
    });

    test(
      'a drain that dies halfway leaves the rest queued, in order',
      () async {
        final first = await createTask(
          title: 'A',
          now: DateTime(2026, 6, 1, 9),
        );
        final second = await createTask(
          title: 'B',
          now: DateTime(2026, 6, 2, 9),
        );
        final third = await createTask(
          title: 'C',
          now: DateTime(2026, 6, 3, 9),
        );

        transport.failure = const SyncTransportFailure('no route to host');
        transport.failAfterWrites = 1;

        final report = await engine().drainOutbox();

        expect(report.isComplete, isFalse);
        expect(report.pushed, 1);
        expect(report.pending, 2);
        expect(transport.row('tasks', first), isNotNull);
        expect(transport.row('tasks', second), isNull);

        final left = await outbox.pending();
        expect([for (final entry in left) entry.rowId], [second, third]);
        expect(left.first.attempts, 1, reason: 'the failure is counted');
        expect(left.first.lastError, 'no route to host');

        // When the network comes back, the drain picks up exactly where it
        // stopped.
        transport.failure = null;
        final resumed = await engine().drainOutbox();
        expect(resumed.pushed, 2);
        expect(resumed.pending, 0);
        expect(transport.row('tasks', third), isNotNull);
      },
    );

    test(
      'an insert that loses a race is dropped rather than retried',
      () async {
        final id = await createTask(now: DateTime(2026, 6, 1, 9));
        // The other device inserts the same row in the window between this
        // device's conditional update finding nothing and its insert landing.
        transport.beforeWrite = () {
          transport.beforeWrite = null;
          transport.seed(
            'tasks',
            remoteTaskJson(
              id: id,
              title: 'Theirs',
              updatedAt: DateTime(2026, 6, 5, 9),
            ),
          );
        };

        final report = await engine().drainOutbox();

        expect(report.superseded, 1);
        expect(report.pending, 0);
        expect(transport.row('tasks', id)!['title'], 'Theirs');
      },
    );

    test('an entry for a row that is not there is dropped', () async {
      await outbox.enqueue('tasks', 'never-existed');
      final report = await engine().drainOutbox();
      expect(report.pushed, 0);
      expect(report.pending, 0);
    });

    test('an entry for a table this build does not sync is dropped', () async {
      // #12 registers completions; a build rolled back past it must not wedge
      // its queue behind rows it cannot push.
      await outbox.enqueue('completions', 'completion-1');
      final report = await engine().drainOutbox();
      expect(report.pending, 0);
    });
  });

  group('the pull', () {
    test('a task created on the other device arrives on this one', () async {
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: 'task-from-the-tablet',
          title: 'Bleed the radiators',
          updatedAt: DateTime(2026, 6, 2, 9),
          startDate: DateTime(2026, 6, 1),
        ),
      );

      final report = await engine().pull();

      expect(report.pulled, 1);
      final arrived = (await tasks.allTasks()).single;
      expect(arrived.id, 'task-from-the-tablet');
      expect(arrived.title, 'Bleed the radiators');
      expect(arrived.floatingSchedule?.intervalN, 30);
      // ADR 0004: the derived caches are recomputed from the log after a pull
      // rather than trusted from the wire.
      expect(arrived.dueDate, DateTime(2026, 7, 1));
    });

    test(
      'a remote row older than the local one is left on the floor',
      () async {
        final id = await createTask(
          title: 'Newer here',
          now: DateTime(2026, 6, 5, 9),
        );
        transport.seed(
          'tasks',
          remoteTaskJson(
            id: id,
            title: 'Older there',
            updatedAt: DateTime(2026, 6, 1, 9),
          ),
        );

        final report = await engine().pull();

        expect(report.pulled, 0);
        expect(report.rejected, 1);
        expect((await tasks.allTasks()).single.title, 'Newer here');
      },
    );

    test('a remote tombstone takes the task off this device', () async {
      final id = await createTask(now: DateTime(2026, 6, 1, 9));
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          updatedAt: DateTime(2026, 6, 2, 9),
          deletedAt: DateTime(2026, 6, 2, 9),
        ),
      );

      await engine().pull();

      expect(await tasks.allTasks(), isEmpty);
    });

    test('a remote tombstone beats a newer local edit', () async {
      final id = await createTask(now: DateTime(2026, 6, 1, 9));
      await tasks.snoozeTask(
        id,
        n: 1,
        unit: IntervalUnit.day,
        now: DateTime(2026, 6, 9, 9),
      );
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          updatedAt: DateTime(2026, 6, 2, 9),
          deletedAt: DateTime(2026, 6, 2, 9),
        ),
      );

      final report = await engine().pull();

      expect(report.pulled, 1);
      expect(await tasks.allTasks(), isEmpty);
    });

    test('the cursor advances, so a second pull asks for nothing', () async {
      transport.seed(
        'tasks',
        remoteTaskJson(id: 'a', updatedAt: DateTime(2026, 6, 2, 9)),
      );
      await engine().pull();

      final cursor = await settings.cursor('tasks');
      expect(cursor, isNotNull);
      expect(cursor!.id, 'a');

      final second = await engine().pull();
      expect(second.pulled, 0);
      expect(second.rejected, 0);
    });

    test('rows sharing a timestamp across a page boundary each arrive '
        'exactly once', () async {
      // The failure this guards against is not hypothetical: create three
      // tasks in one batch and Postgres stamps them identically. A cursor on
      // the timestamp alone either skips the tail of the group or re-reads it
      // forever without ever advancing.
      final at = DateTime(2026, 6, 2, 9);
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        transport.seed('tasks', remoteTaskJson(id: id, updatedAt: at));
      }

      final report = await engine(pageSize: 2).pull();

      expect(report.pulled, 5);
      expect([for (final task in await tasks.allTasks()) task.id]..sort(), [
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);
      // Three full pages plus a short one, and no page re-read: a cursor that
      // could not break the tie would have spun here. Counted for `tasks`
      // alone — a pull sweeps every registered table, and the other three have
      // nothing to say here.
      expect(transport.fetchesFor('tasks'), 3);

      final again = await engine(pageSize: 2).pull();
      expect(again.pulled, 0);
      expect(again.rejected, 0);
    });

    test('a pull interrupted between pages resumes at the boundary', () async {
      // Four rows sharing one timestamp, so the resume point is inside a group
      // that only the id can break — the case a timestamp-only cursor would
      // either skip or re-read.
      final at = DateTime(2026, 6, 2, 9);
      for (final id in ['a', 'b', 'c', 'd']) {
        transport.seed('tasks', remoteTaskJson(id: id, updatedAt: at));
      }

      // One page through, then the connection drops.
      transport.failure = const SyncTransportFailure('connection reset');
      transport.failAfterFetches = 1;

      final interrupted = await engine(pageSize: 2).pull();
      expect(interrupted.isComplete, isFalse);
      expect(interrupted.pulled, 2);
      expect((await tasks.allTasks()).length, 2);
      expect(await settings.cursor('tasks'), SyncCursor(clock: at, id: 'b'));

      // Back on the network, it picks up at the page boundary rather than
      // starting again.
      transport.failure = null;
      final resumed = await engine(pageSize: 2).pull();
      expect(resumed.pulled, 2);
      expect(resumed.rejected, 0, reason: 'nothing is re-read');
      expect((await tasks.allTasks()).length, 4);
    });

    test('a backend that ignores the cursor stops the pull instead of '
        'looping forever', () async {
      transport.seed(
        'tasks',
        remoteTaskJson(id: 'a', updatedAt: DateTime(2026, 6, 2, 9)),
      );
      await engine().pull();

      // A proxy, or an older schema with no index, that keeps answering with
      // the same row however the request is filtered.
      final stubborn = _StuckTransport(transport);
      final report = await SyncEngine(
        db: db,
        transport: stubborn,
        settings: settings,
        tasks: tasks,
        pageSize: 1,
      ).pull();

      expect(report.isComplete, isTrue);
      expect(
        stubborn.fetchesFor('tasks'),
        1,
        reason: 'it gives up rather than spinning',
      );
    });

    test('the cursor does not advance over rows this device pushed, so a '
        'peer\'s older row still arrives', () async {
      // The clock rows are ordered on is the *writing* device's, not the
      // server's (ADR 0001 — nothing on the backend computes anything), so rows
      // do not land in clock order. A phone that spent a fortnight offline
      // pushes a fortnight of work stamped when the work was done, and it lands
      // behind everything this phone wrote in the meantime.
      final id = await createTask(now: DateTime(2026, 6, 10, 9));

      final report = await engine().sync();
      expect(report.pushed, 1);
      expect(report.pulled, 0, reason: 'its own row back again taught it none');
      expect(
        await settings.cursor('tasks'),
        isNull,
        reason: 'nothing was learnt, so there is nowhere new to resume from',
      );

      // The other phone reconnects, with a task it created a week earlier.
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: 'from-the-tablet',
          title: 'Bleed the radiators',
          updatedAt: DateTime(2026, 6, 2, 9),
        ),
      );
      final second = await engine().pull();

      expect(second.pulled, 1);
      expect(
        [for (final task in await tasks.allTasks()) task.id],
        [id, 'from-the-tablet'],
      );
      expect(
        await settings.cursor('tasks'),
        SyncCursor(
          clock: DateTime(2026, 6, 2, 9).toUtc(),
          id: 'from-the-tablet',
        ),
        reason: 'the cursor sits at the last row it learnt from',
      );
    });

    test('a failed pull keeps the cursor it had', () async {
      transport.failure = const SyncTransportFailure('offline');
      final report = await engine().pull();

      expect(report.isComplete, isFalse);
      expect(await settings.cursor('tasks'), isNull);
    });
  });

  group('a pull landing mid-drain', () {
    test('converges: the local row takes the remote value and the queued '
        'push then no-ops', () async {
      final id = await createTask(title: 'Mine', now: DateTime(2026, 6, 1, 9));
      // Still queued, and meanwhile the other device pushed a newer version.
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          title: 'Theirs',
          updatedAt: DateTime(2026, 6, 4, 9),
        ),
      );

      // A pull arrives before the drain gets its chance.
      final pulled = await engine().pull();
      expect(pulled.pulled, 1);
      expect((await tasks.allTasks()).single.title, 'Theirs');
      expect(await outbox.count(), 1, reason: 'the entry is untouched');

      // The drain now reads the row as it stands — which is the remote's own
      // value — so the push is refused and the entry simply goes away.
      final drained = await engine().drainOutbox();
      expect(drained.pushed, 0);
      expect(drained.superseded, 1);
      expect(drained.pending, 0);
      expect(transport.row('tasks', id)!['title'], 'Theirs');
      expect((await tasks.allTasks()).single.title, 'Theirs');
    });

    test('a local edit made after the pull still wins', () async {
      final id = await createTask(title: 'Mine', now: DateTime(2026, 6, 1, 9));
      transport.seed(
        'tasks',
        remoteTaskJson(
          id: id,
          title: 'Theirs',
          updatedAt: DateTime(2026, 6, 4, 9),
        ),
      );
      await engine().pull();

      await tasks.snoozeTask(
        id,
        n: 2,
        unit: IntervalUnit.day,
        now: DateTime(2026, 6, 5, 9),
      );
      final drained = await engine().drainOutbox();

      expect(drained.pushed, 1);
      expect(transport.row('tasks', id)!['snoozed_at'], isNotNull);
    });
  });

  group('sync', () {
    test('pushes before it pulls', () async {
      await createTask();
      transport.seed(
        'tasks',
        remoteTaskJson(id: 'theirs', updatedAt: DateTime(2026, 6, 2, 9)),
      );

      final report = await engine().sync();

      expect(report.pushed, 1);
      expect(report.pulled, 1);
      expect((await tasks.allTasks()).length, 2);
    });

    test('a failed drain does not go on to attempt the pull', () async {
      await createTask();
      transport.failure = const SyncTransportFailure('offline');

      final report = await engine().sync();

      expect(report.isComplete, isFalse);
      expect(transport.fetches, 0);
      expect(report.pending, 1);
    });
  });

  group('seeding', () {
    test('signing in on a device that already has tasks queues all of '
        'them', () async {
      // A month of use with no backend: the outbox has entries from the
      // repository writes, which a fresh install would not have.
      await createTask(title: 'A');
      await createTask(title: 'B');
      await engine().drainOutbox();
      expect(await outbox.count(), 0);

      // Now a backend appears — a different one, or the first one.
      await settings.forgetProgress(['tasks']);
      await engine().seed();

      expect(await outbox.count(), 2);
    });

    test('seeding twice does nothing, and a new backend seeds again', () async {
      await createTask();
      await engine().seed();
      await engine().drainOutbox();
      expect(await outbox.count(), 0);

      await engine().seed();
      expect(await outbox.count(), 0, reason: 'already seeded for this URL');

      await settings.write(
        const SyncSettings(url: 'https://elsewhere.example', anonKey: 'k'),
      );
      await engine().seed();
      expect(
        await outbox.count(),
        1,
        reason: 'the new project has none of these rows',
      );
    });

    test('nothing is seeded with no backend configured', () async {
      await settings.write(const SyncSettings());
      await createTask();
      await engine().drainOutbox();
      await engine().seed();

      expect(await outbox.count(), 0);
    });
  });

  test('a round trip through the wire shape loses nothing', () async {
    final id = await createTask(now: DateTime(2026, 6, 1, 9, 30));
    await tasks.snoozeTask(
      id,
      n: 3,
      unit: IntervalUnit.day,
      now: DateTime(2026, 6, 2, 9),
    );
    final before = await localTaskAsRemote(db, id);

    await engine().drainOutbox();
    // Wipe the device and pull it back down.
    await db.customStatement('DELETE FROM tasks');
    await settings.forgetProgress(['tasks']);
    await engine().pull();

    final after = await localTaskAsRemote(db, id);
    // The derived caches are recomputed rather than restored, so they are
    // compared by what they should now be rather than to what they were.
    for (final column in before.keys) {
      if (column == 'due_date' || column == 'last_completed_at') continue;
      expect(after[column], before[column], reason: column);
    }
  });
}

/// A backend that answers every request with the same row, however the cursor
/// filters it.
class _StuckTransport implements SyncTransport {
  _StuckTransport(this._inner);

  final FakeSyncTransport _inner;
  final Map<String, int> fetchesByTable = {};

  int fetchesFor(String table) => fetchesByTable[table] ?? 0;

  @override
  Future<List<Map<String, Object?>>> fetchChanges({
    required String table,
    required String clockColumn,
    required SyncCursor? after,
    required int limit,
  }) async {
    fetchesByTable.update(table, (n) => n + 1, ifAbsent: () => 1);
    return _inner.fetchChanges(
      table: table,
      clockColumn: clockColumn,
      after: null,
      limit: limit,
    );
  }

  @override
  Future<void> insertRow({
    required String table,
    required Map<String, Object?> row,
  }) => _inner.insertRow(table: table, row: row);

  @override
  Future<int> updateIfSuperseded({
    required String table,
    required String clockColumn,
    required SyncRow row,
  }) => _inner.updateIfSuperseded(
    table: table,
    clockColumn: clockColumn,
    row: row,
  );
}
