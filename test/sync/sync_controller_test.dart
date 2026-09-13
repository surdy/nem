import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/sync_controller.dart';
import 'package:nem/src/sync/sync_engine.dart';
import 'package:nem/src/sync/sync_settings.dart';
import 'package:nem/src/sync/sync_transport.dart';

import 'fake_sync_transport.dart';
import 'task_rows.dart';

void main() {
  group('the retry curve', () {
    test('starts at fifteen seconds and doubles', () {
      expect(nextRetryDelay(0), const Duration(seconds: 15));
      expect(nextRetryDelay(1), const Duration(seconds: 30));
      expect(nextRetryDelay(2), const Duration(minutes: 1));
      expect(nextRetryDelay(3), const Duration(minutes: 2));
    });

    test('is capped, so a week in a cellar is not a million requests', () {
      expect(nextRetryDelay(10), const Duration(minutes: 10));
      expect(nextRetryDelay(1000), const Duration(minutes: 10));
    });

    test('a negative attempt count is still a real delay', () {
      expect(nextRetryDelay(-1), const Duration(seconds: 15));
    });
  });

  group('the runner', () {
    late NemDatabase db;
    late TaskRepository tasks;
    late SyncSettingsRepository settings;
    late FakeSyncTransport transport;
    final now = DateTime(2026, 6, 15, 9);

    setUp(() async {
      db = NemDatabase(NativeDatabase.memory());
      tasks = TaskRepository(db);
      settings = SyncSettingsRepository(db);
      transport = FakeSyncTransport();
      await settings.write(
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
    });

    tearDown(() => db.close());

    SyncRunner runner() {
      final created = SyncRunner(
        engine: SyncEngine(
          db: db,
          transport: transport,
          settings: settings,
          tasks: tasks,
        ),
        clock: () => now,
      );
      addTearDown(created.dispose);
      return created;
    }

    Future<void> createTask() => tasks.createFloatingTask(
      title: 'Water the plants',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9),
    );

    test('with no backend it does nothing at all', () async {
      // The state a device that has never signed in is in, and the one every
      // existing widget test runs in (ADR 0001).
      final subject = SyncRunner(engine: null, clock: () => now);
      addTearDown(subject.dispose);

      expect(await subject.syncNow(), isNull);
      expect(subject.status.isConfigured, isFalse);
      expect(subject.status.isSignedIn, isFalse);
      expect(transport.fetches, 0);
    });

    test('a successful sync clears the error and stamps the time', () async {
      await createTask();
      final subject = runner();

      final report = await subject.syncNow(account: 'someone@example.com');

      expect(report!.isComplete, isTrue);
      expect(report.pushed, 1);
      expect(subject.status.account, 'someone@example.com');
      expect(subject.status.isReady, isTrue);
      expect(subject.status.lastSyncedAt, now);
      expect(subject.status.lastError, isNull);
      expect(subject.status.pending, 0);
    });

    test('it seeds before its first sync, so a device that has been in use '
        'for a month pushes what it already has', () async {
      await createTask();
      // Emptied by hand, as if the rows predated the outbox entirely.
      await db.customStatement('DELETE FROM outbox');

      final subject = runner();
      final report = await subject.syncNow(account: 'someone@example.com');

      expect(report!.pushed, 1);
    });

    test('a failed sync keeps the work and reports why', () async {
      await createTask();
      transport.failure = const SyncTransportFailure('no route to host');
      final subject = runner();

      final report = await subject.syncNow(account: 'someone@example.com');

      expect(report!.isComplete, isFalse);
      expect(subject.status.lastError, 'no route to host');
      expect(subject.status.pending, 1);
      expect(subject.status.isAuthFailure, isFalse);
    });

    test('an expired session is reported as such and not retried on a '
        'timer', () async {
      await createTask();
      transport.failure = const SyncTransportFailure(
        'JWT expired',
        isAuthFailure: true,
      );
      final subject = runner();

      await subject.syncNow(account: 'someone@example.com');

      expect(subject.status.isAuthFailure, isTrue);
      // Nothing is armed, so the test ends with no pending timer — which is
      // also the behaviour: a token nobody has renewed will not renew itself,
      // and retrying every ten minutes would only flatten the battery.
    });

    test('the status is published as it changes', () async {
      await createTask();
      final seen = <SyncStatus>[];
      final subject = SyncRunner(
        engine: SyncEngine(
          db: db,
          transport: transport,
          settings: settings,
          tasks: tasks,
        ),
        onStatus: seen.add,
        clock: () => now,
      );
      addTearDown(subject.dispose);

      await subject.syncNow(account: 'someone@example.com');

      expect(seen.first.isSyncing, isTrue);
      expect(seen.last.isSyncing, isFalse);
    });

    test(
      'a second sync started while the first is running is ignored',
      () async {
        await createTask();
        transport.seed(
          'tasks',
          remoteTaskJson(id: 'theirs', updatedAt: DateTime(2026, 6, 2, 9)),
        );
        final subject = runner();

        final first = subject.syncNow(account: 'someone@example.com');
        final second = subject.syncNow(account: 'someone@example.com');

        expect(await second, isNull, reason: 'no second drain over one outbox');
        expect((await first)!.isComplete, isTrue);
      },
    );
  });
}
