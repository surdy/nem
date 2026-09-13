import 'dart:io';

import 'package:drift/drift.dart';

import '../data/database.dart';
import '../data/ids.dart';
import '../sync/outbox_store.dart';
import 'photo.dart';
import 'photo_cache.dart';
import 'photo_transfer_queue.dart';

/// Reads and writes reference photos: the rows, the local files, and the byte
/// work each of them still owes.
///
/// ## Keeping the row and the file consistent
///
/// A photo is a file plus a row (see [Photo]), and the two are written in an
/// order chosen so that every interruption leaves a state nem can describe:
///
/// * **Attaching** writes the *file first*, then the row. A row is never
///   allowed to name bytes that are not there; the reverse — bytes on disk with
///   no row — is an orphan file that [reconcile] cannot even see, which costs
///   a few kilobytes and confuses nothing.
/// * **Uploading** writes the *bytes first*, then `storage_path`. So a
///   non-null `storage_path` is a promise the bytes are in the bucket, and the
///   far device can treat its absence as "not yet" rather than as a broken
///   photo.
/// * **Deleting** tombstones the *row first* and only then removes the object.
///   That ordering is the whole of `PhotoSync`'s deferral rule, and the
///   argument for it is there.
///
/// None of these is a transaction across the two media, because there is no
/// such thing: SQLite cannot roll back a file write and Storage cannot enlist
/// in a transaction. What there is instead is an order in which every crash
/// point is recoverable, and a queue that re-tries the half that did not
/// happen.
class PhotoRepository {
  PhotoRepository({required NemDatabase db, required this.cache})
    : _db = db,
      _outbox = OutboxStore(db),
      _transfers = PhotoTransferQueue(db);

  final NemDatabase _db;

  /// Where the bytes live on this device, and the only thing the task screen
  /// ever reads an image out of.
  final PhotoCache cache;
  final OutboxStore _outbox;
  final PhotoTransferQueue _transfers;

  PhotoTransferQueue get transfers => _transfers;

  /// One task's live photos, oldest first, each with its file and its
  /// outstanding byte work.
  ///
  /// One stream rather than three, so the screen cannot show an image and a
  /// stale badge. It ticks whenever a photo row or a queue entry changes, which
  /// is exactly when the answer changes: an upload finishing removes a queue
  /// entry, a download finishing writes `local_path`.
  Stream<List<TaskPhoto>> watchPhotosForTask(String taskId) {
    final query =
        _db.select(_db.photos).join([
            leftOuterJoin(
              _db.photoTransfers,
              _db.photoTransfers.photoId.equalsExp(_db.photos.id),
            ),
          ])
          ..where(
            _db.photos.taskId.equals(taskId) & _db.photos.deletedAt.isNull(),
          )
          ..orderBy([OrderingTerm(expression: _db.photos.createdAt)]);

    return query.watch().asyncMap((rows) async {
      final photos = <TaskPhoto>[];
      for (final row in rows) {
        final photo = _toDomain(row.readTable(_db.photos));
        final transfer = row.readTableOrNull(_db.photoTransfers);
        photos.add(
          TaskPhoto(
            photo: photo,
            // The filesystem answers "can this be shown", not the row: a
            // `local_path` whose file was removed under us is a photo that
            // cannot be drawn, and pretending otherwise would show a blank
            // tile with no explanation.
            file: await _existingFile(photo),
            transfer: transfer == null
                ? null
                : PhotoTransfer(
                    photoId: transfer.photoId,
                    operation: transfer.operation,
                    enqueuedAt: transfer.enqueuedAt,
                    attempts: transfer.attempts,
                    lastError: transfer.lastError,
                  ),
          ),
        );
      }
      return photos;
    });
  }

  /// Attaches an image to a task and queues its upload.
  ///
  /// [extension] is the image's file extension without the dot, which decides
  /// both the cache file's name and the object's content type.
  Future<Photo> attachPhoto({
    required String taskId,
    required Uint8List bytes,
    String extension = 'jpg',
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final id = newId();
    final fileName = PhotoCache.fileNameFor(id, extension);

    // The bytes before the row. If this throws — a full disk — there is no
    // photo at all, which is a state the user can understand and retry, and
    // nothing has been promised to the other device.
    await cache.write(fileName, bytes);

    await _db
        .into(_db.photos)
        .insert(
          PhotosCompanion.insert(
            id: id,
            taskId: taskId,
            // Null until an upload succeeds. The row says only what is true.
            storagePath: const Value(null),
            localPath: Value(fileName),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    await _outbox.enqueue(_db.photos.actualTableName, id, now: timestamp);
    await _transfers.enqueue(id, PhotoTransferOperation.upload, now: timestamp);

    return (await photo(id))!;
  }

  /// Removes one photo: its row, its bytes here, and its object there.
  ///
  /// The row is tombstoned rather than deleted (PLAN.md — Sync), so the
  /// deletion beats a stale update from a device that had not seen it. The
  /// object is *queued* for removal rather than removed now, and only leaves
  /// the bucket once the tombstone has been pushed — see [PhotoSync.drain].
  Future<void> deletePhoto(String photoId, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final existing = await photo(photoId);
    if (existing == null || existing.isDeleted) return;

    await (_db.update(
      _db.photos,
    )..where((p) => p.id.equals(photoId) & p.deletedAt.isNull())).write(
      PhotosCompanion(
        deletedAt: Value(timestamp),
        updatedAt: Value(timestamp),
        // The local copy goes now, so the column keeps telling the truth.
        localPath: const Value(null),
      ),
    );
    await _outbox.enqueue(_db.photos.actualTableName, photoId, now: timestamp);

    if (existing.isUploaded) {
      await _transfers.enqueue(
        photoId,
        PhotoTransferOperation.remove,
        now: timestamp,
      );
    } else {
      // Nothing was ever uploaded, so there is nothing to remove and the
      // upload that was queued must not go out: it would put bytes into the
      // bucket that nothing will ever come back for.
      await _transfers.remove(photoId);
    }

    final fileName = existing.localPath;
    if (fileName != null) await cache.delete(fileName);
  }

  /// Removes every photo of a task — what deleting the task does.
  ///
  /// Run *before* the task itself is tombstoned (see `app/task_deletion.dart`),
  /// so that a process killed halfway leaves a live task with no photos rather
  /// than a deleted task whose bytes nothing will ever go back for.
  Future<void> deletePhotosForTask(String taskId, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    for (final photo in await photosForTask(taskId)) {
      await deletePhoto(photo.id, now: timestamp);
    }
  }

  /// Records that the bytes reached Storage.
  ///
  /// An edit of the shared row — it is how the other device learns there is
  /// something to download — so `updated_at` moves and the row is queued for
  /// push.
  Future<void> markUploaded(
    String photoId,
    String storagePath, {
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(_db.photos)..where((p) => p.id.equals(photoId))).write(
      PhotosCompanion(
        storagePath: Value(storagePath),
        updatedAt: Value(timestamp),
      ),
    );
    await _outbox.enqueue(_db.photos.actualTableName, photoId, now: timestamp);
  }

  /// Records that this device now holds the bytes.
  ///
  /// Deliberately **not** an edit of the shared row: `local_path` is
  /// device-local (`SyncedTable.deviceLocalColumns`), so `updated_at` does not
  /// move and nothing is queued for push. Downloading a photo is not news for
  /// the other phone, and treating it as news would have two devices pushing
  /// rows at each other every time either one looked at an image.
  Future<void> markCached(String photoId, String fileName) async {
    await (_db.update(_db.photos)..where((p) => p.id.equals(photoId))).write(
      PhotosCompanion(localPath: Value(fileName)),
    );
  }

  /// Records that this device no longer holds the bytes. Device-local, like
  /// [markCached].
  Future<void> clearCached(String photoId) async {
    await (_db.update(_db.photos)..where((p) => p.id.equals(photoId))).write(
      const PhotosCompanion(localPath: Value(null)),
    );
  }

  /// Brings the queue and the cache back into line with the rows.
  ///
  /// Run at the start of every photo sync, and it is what makes the second
  /// device work at all: a pulled photo row is just a row, and something has to
  /// notice that its bytes are missing here and ask for them. It also picks up
  /// everything an interrupted anything left behind — an upload queued on a
  /// device that was reinstalled, a cache file deleted by a restore, a photo
  /// the other phone tombstoned while this one was offline.
  ///
  /// Cheap enough to run every time: one query, and one `stat` per photo.
  Future<void> reconcile({DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    for (final photo in await _allPhotos()) {
      final fileName = photo.localPath;
      final isCached = fileName != null && await cache.contains(fileName);

      if (photo.isDeleted) {
        // A tombstone pulled from the other device. Drop the local copy — but
        // do *not* queue a removal from Storage: the device that deleted the
        // photo owns that, and a second device racing it would get a 404 that
        // reads like a failure.
        if (fileName != null) {
          await cache.delete(fileName);
          await clearCached(photo.id);
        }
        continue;
      }

      if (isCached && !photo.isUploaded) {
        await _transfers.enqueue(
          photo.id,
          PhotoTransferOperation.upload,
          now: timestamp,
        );
      } else if (!isCached && photo.isUploaded) {
        await _transfers.enqueue(
          photo.id,
          PhotoTransferOperation.download,
          now: timestamp,
        );
      } else if (!isCached && fileName != null) {
        // The row claims a file that is not there and Storage has no copy
        // either. Nothing can be fetched; at least stop the screen claiming it
        // has an image.
        await clearCached(photo.id);
      }
    }
  }

  Future<Photo?> photo(String id) async {
    final row = await (_db.select(
      _db.photos,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  /// A task's live photos, oldest first.
  Future<List<Photo>> photosForTask(String taskId) async {
    final rows =
        await (_db.select(_db.photos)
              ..where((p) => p.taskId.equals(taskId) & p.deletedAt.isNull())
              ..orderBy([(p) => OrderingTerm(expression: p.createdAt)]))
            .get();
    return [for (final row in rows) _toDomain(row)];
  }

  /// The object key an upload writes to.
  ///
  /// Prefixed with the task so a bucket browsed in the dashboard is grouped
  /// the way the app is, and suffixed with the extension so the object is
  /// served with a sensible content type.
  static String storageKeyFor(Photo photo) {
    final name = photo.localPath ?? '${photo.id}.jpg';
    return '${photo.taskId}/$name';
  }

  /// The content type for a stored file name.
  static String contentTypeFor(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      _ => 'image/jpeg',
    };
  }

  Future<List<Photo>> _allPhotos() async {
    final rows = await _db.select(_db.photos).get();
    return [for (final row in rows) _toDomain(row)];
  }

  Future<File?> _existingFile(Photo photo) async {
    final fileName = photo.localPath;
    if (fileName == null) return null;
    final file = await cache.file(fileName);
    return file.existsSync() ? file : null;
  }

  Photo _toDomain(PhotoRow row) => Photo(
    id: row.id,
    taskId: row.taskId,
    storagePath: row.storagePath,
    localPath: row.localPath,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    deletedAt: row.deletedAt,
  );
}
