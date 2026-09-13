import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/task_deletion.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/notifications/reminder_scheduler.dart';
import 'package:nem/src/photos/photo.dart';
import 'package:nem/src/photos/photo_cache.dart';
import 'package:nem/src/photos/photo_repository.dart';
import 'package:nem/src/sync/outbox_store.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import '../notifications/fake_reminder_notifier.dart';

/// Deleting a task, and everything that has to go with it (#15).
///
/// The ordering is the subject: photos first, then the task, because an
/// interruption between the two has to leave a live task with no photos rather
/// than a deleted task whose bytes nothing will ever go back for.
void main() {
  late NemDatabase db;
  late TaskRepository tasks;
  late PhotoRepository photos;
  late OutboxStore outbox;
  late Directory root;
  late TaskDeletion deletion;
  final now = DateTime(2026, 6, 15, 9);

  setUpAll(tz_data.initializeTimeZones);

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    root = await Directory.systemTemp.createTemp('nem-task-deletion');
    photos = PhotoRepository(db: db, cache: PhotoCache(Future.value(root)));
    outbox = OutboxStore(db);
    deletion = TaskDeletion(
      tasks: tasks,
      photos: photos,
      reminders: ReminderScheduler(
        notifier: FakeReminderNotifier(),
        tasks: tasks,
        clock: () => now,
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<String> taskWithPhotos({int count = 2}) async {
    final task = await tasks.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: DateTime(2026, 6, 1, 9),
    );
    for (var i = 0; i < count; i++) {
      await photos.attachPhoto(
        taskId: task.id,
        bytes: Uint8List.fromList(List.filled(4, i)),
        now: DateTime(2026, 6, 2, 9).add(Duration(minutes: i)),
      );
    }
    return task.id;
  }

  test('deleting a task takes every one of its photos with it', () async {
    final id = await taskWithPhotos();
    final attached = await photos.photosForTask(id);
    expect(attached, hasLength(2));

    await deletion.delete(id);

    expect(await photos.photosForTask(id), isEmpty);
    for (final photo in attached) {
      // Tombstoned rather than deleted, so a phone that had not seen the
      // deletion cannot push the row back (PLAN.md — Sync).
      expect((await photos.photo(photo.id))!.isDeleted, isTrue);
      // The local copy goes now: the column says only what is true.
      expect(await photos.cache.contains(photo.localPath!), isFalse);
    }
  });

  test('the task is tombstoned rather than removed', () async {
    final id = await taskWithPhotos(count: 0);

    await deletion.delete(id);

    expect(await tasks.allTasks(), isEmpty);
    final row = await (db.select(
      db.tasks,
    )..where((t) => t.id.equals(id))).getSingle();
    expect(row.deletedAt, isNotNull);
    // And it is queued, so the other device is told rather than left holding a
    // task nobody has.
    expect(await outbox.holds('tasks', id), isTrue);
  });

  test('an uploaded photo is queued for removal, not removed behind the '
      'tombstone', () async {
    final id = await taskWithPhotos(count: 1);
    final photo = (await photos.photosForTask(id)).single;
    await photos.markUploaded(
      photo.id,
      '$id/${photo.localPath}',
      now: DateTime(2026, 6, 3, 9),
    );

    await deletion.delete(id);

    // The object waits for its tombstone to be pushed — bytes deleted from
    // Storage are gone for good, and the other device may not have seen the
    // deletion. `PhotoSync.drain` owns that order; this only has to have asked
    // for it.
    final queued = await photos.transfers.find(photo.id);
    expect(queued?.operation, PhotoTransferOperation.remove);
    expect(await outbox.holds('photos', photo.id), isTrue);
  });

  test(
    'a photo that never uploaded cancels its upload rather than racing it',
    () async {
      final id = await taskWithPhotos(count: 1);
      final photo = (await photos.photosForTask(id)).single;
      expect(
        (await photos.transfers.find(photo.id))?.operation,
        PhotoTransferOperation.upload,
      );

      await deletion.delete(id);

      // Uploading it now would put bytes in the bucket that nothing will ever
      // come back for.
      expect(await photos.transfers.find(photo.id), isNull);
    },
  );

  test('the completion log survives the task that is gone', () async {
    final id = await taskWithPhotos(count: 0);
    await tasks.recordCompletion(
      id,
      completedAt: DateTime(2026, 6, 5, 9),
      now: DateTime(2026, 6, 5, 9),
    );

    await deletion.delete(id);

    // Completions are immutable events (ADR 0004) and a task's tombstone does
    // not un-happen the work. The rows become orphans, which every query
    // already ignores; rewriting the log to erase history is the one thing nem
    // never does.
    expect(await db.select(db.completions).get(), hasLength(1));
  });

  test('deleting a task with no photos is not a special case', () async {
    final id = await taskWithPhotos(count: 0);

    await deletion.delete(id);

    expect(await tasks.allTasks(), isEmpty);
    expect(await photos.transfers.count(), 0);
  });
}
