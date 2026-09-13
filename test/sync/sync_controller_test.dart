import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/photos/photo_cache.dart';
import 'package:nem/src/photos/photo_repository.dart';
import 'package:nem/src/photos/photo_storage.dart';
import 'package:nem/src/photos/photo_sync.dart';
import 'package:nem/src/sync/sync_controller.dart';
import 'package:nem/src/sync/sync_engine.dart';
import 'package:nem/src/sync/sync_settings.dart';
import 'package:nem/src/sync/sync_transport.dart';

import 'dart:io';
import 'dart:typed_data';

import '../photos/fake_photo_storage.dart';
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

  /// The bytes' half of a sync (#15).
  ///
  /// A photo is a file plus a row: the row goes through the outbox and the
  /// engine, the bytes go through their own queue and Storage. These are about
  /// the *seam between the two* — that the runner drains them in the order the
  /// deletion rule needs, that one retry covers both, and that a stuck upload
  /// is never reported as "everything is sent".
  group('the runner and the bytes', () {
    late NemDatabase db;
    late TaskRepository tasks;
    late SyncSettingsRepository settings;
    late FakeSyncTransport transport;
    late FakePhotoStorage storage;
    late PhotoRepository photos;
    late Directory root;
    final now = DateTime(2026, 6, 15, 9);

    setUp(() async {
      db = NemDatabase(NativeDatabase.memory());
      tasks = TaskRepository(db);
      settings = SyncSettingsRepository(db);
      transport = FakeSyncTransport();
      storage = FakePhotoStorage();
      root = await Directory.systemTemp.createTemp('nem-runner-photos');
      photos = PhotoRepository(db: db, cache: PhotoCache(Future.value(root)));
      await settings.write(
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
    });

    tearDown(() async {
      await db.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    SyncRunner runner() {
      final created = SyncRunner(
        engine: SyncEngine(
          db: db,
          transport: transport,
          settings: settings,
          tasks: tasks,
        ),
        photos: PhotoSync(db: db, photos: photos, storage: storage),
        clock: () => now,
      );
      addTearDown(created.dispose);
      return created;
    }

    Future<String> attachPhoto() async {
      final task = await tasks.createFloatingTask(
        title: 'Replace the water filter',
        intervalN: 1,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 9),
      );
      final photo = await photos.attachPhoto(
        taskId: task.id,
        bytes: Uint8List.fromList(const [9, 9, 9]),
        now: DateTime(2026, 6, 2, 9),
      );
      return photo.id;
    }

    test('one sync moves the row and then the bytes', () async {
      final photoId = await attachPhoto();

      await runner().syncNow(account: 'someone@example.com');

      expect(transport.tables['photos'], hasLength(1));
      expect(storage.uploads, 1);
      expect((await photos.photo(photoId))!.isUploaded, isTrue);
      // Both queues are empty afterwards, which is the whole of "sent".
      expect(await photos.transfers.count(), 0);
    });

    test(
      'a deletion removes the object only after its tombstone is up',
      () async {
        final photoId = await attachPhoto();
        await runner().syncNow(account: 'someone@example.com');
        expect(storage.objects, hasLength(1));

        await photos.deletePhoto(photoId, now: DateTime(2026, 6, 3, 9));

        // Offline: the tombstone cannot be pushed, so the object must stay.
        // Bytes deleted from Storage are gone for good and the other device has
        // not seen the deletion yet.
        transport.failure = const SyncTransportFailure('no route to host');
        await runner().syncNow(account: 'someone@example.com');
        expect(storage.objects, hasLength(1));
        expect(storage.removals, 0);

        // Back online, the tombstone goes up and the object goes with it.
        transport.failure = null;
        await runner().syncNow(account: 'someone@example.com');
        expect(storage.removals, 1);
        expect(storage.objects, isEmpty);
      },
    );

    test('a stuck upload is counted, surfaced and retried on the engine\'s '
        'own backoff', () async {
      await attachPhoto();
      storage.failure = const PhotoStorageFailure('storage is unreachable');
      final subject = runner();

      await subject.syncNow(account: 'someone@example.com');

      // The rows went up fine; only the bytes did not. Saying "everything is
      // sent" here is the silent drop #15 is about.
      expect(subject.status.pending, 0);
      expect(subject.status.pendingPhotos, 1);
      expect(subject.status.lastError, 'storage is unreachable');
      // One retry armed, on the engine's capped backoff, because there is work
      // waiting — not a second timer of the photo queue's own.
      expect(subject.hasRetryScheduled, isTrue);

      // And the entry kept its place with the failure written on it, which is
      // what the task screen reads.
      final entry = (await photos.transfers.pending()).single;
      expect(entry.attempts, 1);
      expect(entry.lastError, 'storage is unreachable');
    });

    test('an expired token on Storage is surfaced rather than retried on a '
        'timer', () async {
      await attachPhoto();
      storage.failure = const PhotoStorageFailure(
        'JWT expired',
        isAuthFailure: true,
      );
      final subject = runner();

      await subject.syncNow(account: 'someone@example.com');

      expect(subject.status.isAuthFailure, isTrue);
      expect(subject.status.lastError, 'JWT expired');
      // Signing in again is the only thing that fixes this, so a timer would
      // be a loop that never succeeds and a battery that never recovers.
      expect(subject.hasRetryScheduled, isFalse);
    });

    test('a drain that failed on the rows does not also ask Storage', () async {
      await attachPhoto();
      transport.failure = const SyncTransportFailure('no route to host');
      final subject = runner();

      await subject.syncNow(account: 'someone@example.com');

      // A failed push is a failed network. Asking the bucket the same question
      // would be a second round trip for the same answer.
      expect(storage.uploads, 0);
      expect(subject.status.lastError, 'no route to host');
    });

    test('the photo queue survives a restart', () async {
      await attachPhoto();
      storage.failure = const PhotoStorageFailure('storage is unreachable');
      await runner().syncNow(account: 'someone@example.com');

      // A new runner over the same database is what a relaunch is: the queue is
      // a table, so it is still there.
      storage.failure = null;
      final second = runner();
      await second.syncNow(account: 'someone@example.com');

      expect(storage.uploads, 1);
      expect(second.status.pendingPhotos, 0);
      expect(second.status.lastError, isNull);
    });
  });
}
