import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/photos/photo.dart';
import 'package:nem/src/photos/photo_cache.dart';
import 'package:nem/src/photos/photo_repository.dart';
import 'package:nem/src/photos/photo_transfer_queue.dart';
import 'package:nem/src/sync/outbox_store.dart';

void main() {
  late NemDatabase db;
  late Directory root;
  late PhotoRepository photos;
  late PhotoTransferQueue transfers;
  late OutboxStore outbox;
  late TaskRepository tasks;
  final now = DateTime(2026, 7, 10, 12);

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('nem-photos');
    photos = PhotoRepository(db: db, cache: PhotoCache(Future.value(root)));
    transfers = photos.transfers;
    outbox = OutboxStore(db);
    tasks = TaskRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<String> taskId() async {
    final task = await tasks.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  Uint8List bytes([int seed = 1]) => Uint8List.fromList(List.filled(8, seed));

  group('attaching', () {
    test('writes the file, then the row, then queues both halves', () async {
      final task = await taskId();
      final photo = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );

      // The row says only what is true: the bytes are here and not in
      // Storage.
      expect(photo.taskId, task);
      expect(photo.localPath, '${photo.id}.jpg');
      expect(photo.storagePath, isNull);
      expect(photo.isCached, isTrue);
      expect(photo.isUploaded, isFalse);

      // The file is on disk before anything is queued, so a row can never name
      // bytes that are not there.
      expect(File('${root.path}/${photo.id}.jpg').existsSync(), isTrue);

      // Both queues have an entry: the row for the outbox, the bytes for
      // their own.
      final queued = [
        for (final entry in await outbox.pending())
          if (entry.table == 'photos') entry,
      ];
      expect(queued, hasLength(1));
      expect(queued.single.rowId, photo.id);
      final transfer = await transfers.find(photo.id);
      expect(transfer?.operation, PhotoTransferOperation.upload);
    });

    test('a photo is attached to a task and never to a completion', () async {
      final task = await taskId();
      await photos.attachPhoto(taskId: task, bytes: bytes(), now: now);
      final completion = await tasks.recordCompletion(task, now: now);

      // Nothing in the schema or the repository can attach a photo to a
      // completion: the only key a photo carries is a task's (CONTEXT.md —
      // "Reference photo"). Asserted by asking for the completion's id as a
      // task id, which is the closest a caller could get, and getting nothing.
      expect(await photos.photosForTask(completion.id), isEmpty);
      expect(await photos.photosForTask(task), hasLength(1));
    });

    test(
      'the extension survives into the file name and the content type',
      () async {
        final task = await taskId();
        final photo = await photos.attachPhoto(
          taskId: task,
          bytes: bytes(),
          extension: 'png',
          now: now,
        );

        expect(photo.localPath, '${photo.id}.png');
        expect(PhotoRepository.contentTypeFor(photo.localPath!), 'image/png');
        expect(PhotoRepository.storageKeyFor(photo), '$task/${photo.id}.png');
      },
    );
  });

  group('deleting a photo', () {
    test('tombstones the row, drops the file and queues the removal', () async {
      final task = await taskId();
      final photo = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );
      await photos.markUploaded(photo.id, 'key.jpg', now: now);

      await photos.deletePhoto(
        photo.id,
        now: now.add(const Duration(hours: 1)),
      );

      final stored = await photos.photo(photo.id);
      // Soft, so the delete beats a stale update from the other device.
      expect(stored!.isDeleted, isTrue);
      expect(stored.localPath, isNull);
      // The key survives the tombstone, because the removal still needs it.
      expect(stored.storagePath, 'key.jpg');
      expect(File('${root.path}/${photo.id}.jpg').existsSync(), isFalse);
      expect(
        (await transfers.find(photo.id))?.operation,
        PhotoTransferOperation.remove,
      );
      expect(await photos.photosForTask(task), isEmpty);
    });

    test('a photo that never uploaded cancels its upload instead', () async {
      final task = await taskId();
      final photo = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );

      await photos.deletePhoto(photo.id, now: now);

      // There is nothing in the bucket to remove, and the upload that was
      // queued must not go out: it would put bytes there that nothing will
      // ever come back for.
      expect(await transfers.find(photo.id), isNull);
    });
  });

  group('deleting a task', () {
    test('takes every one of its photos with it', () async {
      final task = await taskId();
      final other = await taskId();
      final first = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );
      final second = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(2),
        now: now,
      );
      final untouched = await photos.attachPhoto(
        taskId: other,
        bytes: bytes(3),
        now: now,
      );
      await photos.markUploaded(first.id, 'a.jpg', now: now);
      await photos.markUploaded(second.id, 'b.jpg', now: now);

      await photos.deletePhotosForTask(task, now: now);

      expect(await photos.photosForTask(task), isEmpty);
      expect((await photos.photo(first.id))!.isDeleted, isTrue);
      expect((await photos.photo(second.id))!.isDeleted, isTrue);
      for (final photo in [first, second]) {
        expect(File('${root.path}/${photo.id}.jpg').existsSync(), isFalse);
        expect(
          (await transfers.find(photo.id))?.operation,
          PhotoTransferOperation.remove,
        );
      }

      // Another task's photo is untouched — the deletion is scoped to the task
      // and not to the bucket.
      expect((await photos.photo(untouched.id))!.isDeleted, isFalse);
      expect(File('${root.path}/${untouched.id}.jpg').existsSync(), isTrue);
    });
  });

  group('reconcile', () {
    test('queues a download for a photo the other device uploaded', () async {
      // Exactly what a pull leaves behind: a row with a storage path, and no
      // bytes on this device.
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: 'photo-1',
              taskId: 'task-1',
              storagePath: const Value('task-1/photo-1.jpg'),
              createdAt: now,
              updatedAt: now,
            ),
          );

      await photos.reconcile(now: now);

      expect(
        (await transfers.find('photo-1'))?.operation,
        PhotoTransferOperation.download,
      );
    });

    test('queues an upload for bytes that never went up', () async {
      final photo = await photos.attachPhoto(
        taskId: await taskId(),
        bytes: bytes(),
        now: now,
      );
      await transfers.remove(photo.id);

      await photos.reconcile(now: now);

      expect(
        (await transfers.find(photo.id))?.operation,
        PhotoTransferOperation.upload,
      );
    });

    test('drops the local copy of a photo the other device deleted', () async {
      final photo = await photos.attachPhoto(
        taskId: await taskId(),
        bytes: bytes(),
        now: now,
      );
      await photos.markUploaded(photo.id, 'key.jpg', now: now);
      await transfers.remove(photo.id);
      // A tombstone as a pull would apply it: the row alone, with nothing
      // said about this device's cache.
      await (db.update(db.photos)..where((p) => p.id.equals(photo.id))).write(
        PhotosCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );

      await photos.reconcile(now: now);

      expect(File('${root.path}/${photo.id}.jpg').existsSync(), isFalse);
      expect((await photos.photo(photo.id))!.localPath, isNull);
      // And emphatically no removal is queued. The device that deleted the
      // photo owns the object; a second device racing it would get a 404 that
      // reads like a failure.
      expect(await transfers.find(photo.id), isNull);
    });

    test(
      'a claim on a file that is gone is given up, not retried forever',
      () async {
        final photo = await photos.attachPhoto(
          taskId: await taskId(),
          bytes: bytes(),
          now: now,
        );
        await transfers.remove(photo.id);
        await File('${root.path}/${photo.id}.jpg').delete();

        await photos.reconcile(now: now);

        expect((await photos.photo(photo.id))!.localPath, isNull);
        expect(await transfers.find(photo.id), isNull);
      },
    );

    test('changes nothing on a second run', () async {
      final photo = await photos.attachPhoto(
        taskId: await taskId(),
        bytes: bytes(),
        now: now,
      );
      await photos.reconcile(now: now);
      final first = await transfers.find(photo.id);
      await photos.reconcile(now: now.add(const Duration(hours: 3)));
      final second = await transfers.find(photo.id);

      // Idempotent, and the queue position is kept rather than bumped: the
      // drain runs oldest-first, and re-queueing would send this photo to the
      // back of the queue on every sync.
      expect(second!.enqueuedAt, first!.enqueuedAt);
    });
  });

  group('watching', () {
    test('hands the screen the row, the file and the pending work', () async {
      final task = await taskId();
      final photo = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );

      final shown = (await photos.watchPhotosForTask(task).first).single;
      expect(shown.photo.id, photo.id);
      expect(shown.isReady, isTrue);
      expect(shown.file!.path, endsWith('${photo.id}.jpg'));
      expect(shown.statusLabel, 'Waiting to upload');
    });

    test(
      'a photo whose bytes are elsewhere says so rather than showing a hole',
      () async {
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: 'photo-1',
                taskId: 'task-1',
                createdAt: now,
                updatedAt: now,
              ),
            );

        final shown = (await photos.watchPhotosForTask('task-1').first).single;
        expect(shown.isReady, isFalse);
        expect(shown.statusLabel, 'Waiting for the other device');
      },
    );

    test('a failed transfer is surfaced, never silently dropped', () async {
      final task = await taskId();
      final photo = await photos.attachPhoto(
        taskId: task,
        bytes: bytes(),
        now: now,
      );
      await transfers.recordFailure(photo.id, 'No route to host');

      final shown = (await photos.watchPhotosForTask(task).first).single;
      expect(shown.statusLabel, 'Upload failed — retrying');
      expect(shown.errorMessage, 'No route to host');
      // And it is still queued, which is the other half of "retried".
      expect(await transfers.count(), 1);
    });
  });
}
