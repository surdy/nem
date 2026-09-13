import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/photos/photo.dart';
import 'package:nem/src/photos/photo_cache.dart';
import 'package:nem/src/photos/photo_repository.dart';
import 'package:nem/src/photos/photo_storage.dart';
import 'package:nem/src/photos/photo_sync.dart';
import 'package:nem/src/photos/photo_transfer_queue.dart';
import 'package:nem/src/sync/outbox_store.dart';

import 'fake_photo_storage.dart';

void main() {
  late NemDatabase db;
  late Directory root;
  late PhotoRepository photos;
  late PhotoTransferQueue transfers;
  late OutboxStore outbox;
  late FakePhotoStorage storage;
  late PhotoSync sync;
  final now = DateTime(2026, 7, 10, 12);

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('nem-photo-sync');
    photos = PhotoRepository(db: db, cache: PhotoCache(Future.value(root)));
    transfers = photos.transfers;
    outbox = OutboxStore(db);
    storage = FakePhotoStorage();
    sync = PhotoSync(db: db, photos: photos, storage: storage);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Uint8List bytes([int seed = 7]) => Uint8List.fromList(List.filled(12, seed));

  /// A photo attached here, with its row already pushed — which is the state
  /// every drain below starts from unless it says otherwise.
  Future<Photo> attached({String taskId = 'task-1', int seed = 7}) async {
    final photo = await photos.attachPhoto(
      taskId: taskId,
      bytes: bytes(seed),
      now: now,
    );
    await outbox.remove('photos', photo.id);
    return photo;
  }

  /// A photo the other device made, as a pull leaves it: a row with a key and
  /// no bytes here.
  Future<Photo> pulled({String id = 'photo-far', int seed = 3}) async {
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: id,
            taskId: 'task-1',
            storagePath: Value('task-1/$id.jpg'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    storage.objects['task-1/$id.jpg'] = bytes(seed);
    return (await photos.photo(id))!;
  }

  group('uploading', () {
    test('puts the bytes up, then records where they went', () async {
      final photo = await attached();

      final report = await sync.sync(now: now);

      expect(report.uploaded, 1);
      expect(report.isComplete, isTrue);
      expect(storage.objects.keys, ['task-1/${photo.id}.jpg']);
      expect(storage.contentTypes['task-1/${photo.id}.jpg'], 'image/jpeg');

      // The row is told only after the bytes are there, so `storage_path` is a
      // promise rather than a hope — and the row is queued for push, because
      // that promise is what the other device acts on.
      final stored = await photos.photo(photo.id);
      expect(stored!.storagePath, 'task-1/${photo.id}.jpg');
      expect(await outbox.holds('photos', photo.id), isTrue);
      expect(await transfers.find(photo.id), isNull);
    });

    test(
      'a photo whose file has gone is surfaced, not retried into a hole',
      () async {
        final photo = await attached();
        await File('${root.path}/${photo.id}.jpg').delete();

        final report = await sync.drain(now: now);

        expect(report.uploaded, 0);
        expect(storage.uploads, 0);
        expect(
          (await transfers.find(photo.id))?.lastError,
          contains('missing'),
        );
      },
    );
  });

  group('downloading', () {
    test('fetches a photo the other device uploaded and caches it', () async {
      final photo = await pulled();

      final report = await sync.sync(now: now);

      expect(report.downloaded, 1);
      // Cached, so it displays from here on with no network at all.
      expect(File('${root.path}/${photo.id}.jpg').readAsBytesSync(), bytes(3));
      expect((await photos.photo(photo.id))!.localPath, '${photo.id}.jpg');
      expect(await transfers.find(photo.id), isNull);

      // And caching is *not* news for the other device: `local_path` is this
      // device's business, so nothing is queued for push.
      expect(await outbox.holds('photos', photo.id), isFalse);
    });

    test(
      'bytes that are not up there yet keep their place in the queue',
      () async {
        final photo = await pulled();
        storage.objects.clear();

        final report = await sync.sync(now: now);

        expect(report.downloaded, 0);
        expect(report.deferred, 1);
        expect(report.isComplete, isTrue);
        // Queued, with something to say. The next drain asks again.
        final transfer = await transfers.find(photo.id);
        expect(transfer!.operation, PhotoTransferOperation.download);
        expect(transfer.lastError, contains('has not finished uploading'));
      },
    );
  });

  group('removing', () {
    test(
      'waits for the tombstone to be pushed before deleting the object',
      () async {
        final photo = await attached();
        await sync.sync(now: now);
        await outbox.remove('photos', photo.id);
        await photos.deletePhoto(photo.id, now: now);

        // The tombstone is still in the outbox, so the object stays: bytes
        // deleted from Storage are gone for good, and the other device has not
        // seen the deletion yet.
        final deferred = await sync.drain(now: now);
        expect(deferred.removed, 0);
        expect(deferred.deferred, 1);
        expect(storage.objects, isNotEmpty);
        expect(storage.removals, 0);

        // Once the row has gone up, the bytes follow.
        await outbox.remove('photos', photo.id);
        final report = await sync.drain(now: now);
        expect(report.removed, 1);
        expect(storage.objects, isEmpty);
        expect(await transfers.count(), 0);
      },
    );

    test('an object that is already gone counts as removed', () async {
      final photo = await attached();
      await sync.sync(now: now);
      await outbox.remove('photos', photo.id);
      await photos.deletePhoto(photo.id, now: now);
      await outbox.remove('photos', photo.id);
      storage.objects.clear();

      final report = await sync.drain(now: now);

      expect(report.removed, 1);
      expect(await transfers.count(), 0);
    });

    test('deleting a task removes every one of its objects', () async {
      final first = await attached(seed: 1);
      final second = await attached(seed: 2);
      await sync.sync(now: now);
      await outbox.remove('photos', first.id);
      await outbox.remove('photos', second.id);
      expect(storage.objects, hasLength(2));

      await photos.deletePhotosForTask('task-1', now: now);
      // What `TaskDeletion` does next is push the rows; here the outbox is
      // drained by hand so the ordering under test is the photo queue's.
      await outbox.remove('photos', first.id);
      await outbox.remove('photos', second.id);
      final report = await sync.drain(now: now);

      expect(report.removed, 2);
      expect(storage.objects, isEmpty);
    });
  });

  group('offline, and afterwards', () {
    test(
      'a drain with no network leaves everything queued and says why',
      () async {
        final photo = await attached();
        storage.failure = const PhotoStorageFailure('No route to host');

        final report = await sync.sync(now: now);

        expect(report.isComplete, isFalse);
        expect(report.failure!.message, 'No route to host');
        expect(report.pending, 1);
        final transfer = await transfers.find(photo.id);
        expect(transfer!.attempts, 1);
        expect(transfer.lastError, 'No route to host');
      },
    );

    test(
      'the queue survives a restart and drains when the network comes back',
      () async {
        final photo = await attached();
        storage.failure = const PhotoStorageFailure('No route to host');
        await sync.sync(now: now);

        // A restart: everything in memory is thrown away and rebuilt over the
        // same database and the same directory. Only what was written down
        // survives — which is the whole point of a queue in SQLite rather than a
        // list in a field.
        final restarted = PhotoSync(
          db: db,
          photos: PhotoRepository(
            db: db,
            cache: PhotoCache(Future.value(root)),
          ),
          storage: storage,
        );
        expect(await transfers.count(), 1);

        storage.failure = null;
        final report = await restarted.sync(now: now);

        expect(report.uploaded, 1);
        expect(await transfers.count(), 0);
        expect(storage.objects.keys, ['task-1/${photo.id}.jpg']);
      },
    );

    test('a failure stops the drain and leaves the rest in order', () async {
      final first = await attached(seed: 1);
      await Future<void>.delayed(Duration.zero);
      final second = await photos.attachPhoto(
        taskId: 'task-1',
        bytes: bytes(2),
        now: now.add(const Duration(minutes: 5)),
      );
      storage.failure = const PhotoStorageFailure('No route to host');

      await sync.drain(now: now);

      // Oldest first, and the first failure stops it: exactly one attempt was
      // made, and both entries are still queued in their original order.
      expect(storage.uploads, 0);
      expect((await transfers.find(first.id))!.attempts, 1);
      expect((await transfers.find(second.id))!.attempts, 0);
      final queue = await transfers.pending();
      expect([for (final t in queue) t.photoId], [first.id, second.id]);
    });

    test(
      'an expired token is surfaced as one rather than as no network',
      () async {
        await attached();
        storage.failure = const PhotoStorageFailure(
          'JWT expired',
          isAuthFailure: true,
        );

        final report = await sync.sync(now: now);

        expect(report.failure!.isAuthFailure, isTrue);
      },
    );
  });

  test('a photo with no row left is dropped from the queue', () async {
    await transfers.enqueue(
      'a-photo-that-never-was',
      PhotoTransferOperation.upload,
      now: now,
    );

    final report = await sync.drain(now: now);

    expect(report.pending, 0);
    expect(storage.uploads, 0);
  });
}
