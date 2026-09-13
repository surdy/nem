import 'dart:typed_data';

import '../data/database.dart';
import '../sync/outbox_store.dart';
import 'photo.dart';
import 'photo_repository.dart';
import 'photo_storage.dart';
import 'photo_transfer_queue.dart';

/// What one drain of the photo queue did.
class PhotoSyncReport {
  const PhotoSyncReport({
    this.uploaded = 0,
    this.downloaded = 0,
    this.removed = 0,
    this.deferred = 0,
    this.pending = 0,
    this.failure,
  });

  /// Photos whose bytes reached Storage.
  final int uploaded;

  /// Photos whose bytes reached this device.
  final int downloaded;

  /// Objects deleted from Storage.
  final int removed;

  /// Entries this drain deliberately left alone — a removal whose tombstone
  /// has not been pushed yet, or a download whose bytes are not up there yet.
  final int deferred;

  /// Entries still queued when this drain stopped.
  final int pending;

  /// Why it stopped early, if it did.
  final PhotoStorageFailure? failure;

  bool get isComplete => failure == null;

  @override
  String toString() =>
      'PhotoSyncReport(uploaded: $uploaded, downloaded: $downloaded, '
      'removed: $removed, deferred: $deferred, pending: $pending'
      '${failure == null ? '' : ', failed: ${failure!.message}'})';
}

/// Moves the bytes, in the order that keeps them consistent with the rows.
///
/// The row half of a photo is the sync engine's job and goes through the
/// outbox; this is the other half. It is a separate drain rather than a fifth
/// table in the engine because bytes are not rows: they are not re-read from
/// SQLite when they drain, they are megabytes rather than fields, and they need
/// three verbs where a row needs one.
///
/// Everything here is a decision and is exercised against `FakePhotoStorage`;
/// the only thing that touches a network is behind [PhotoStorage], which is a
/// testing seam and not a backend abstraction (see `photo_storage.dart`, and
/// ADR 0002).
class PhotoSync {
  PhotoSync({
    required NemDatabase db,
    required this.photos,
    required this.storage,
  }) : queue = photos.transfers,
       outbox = OutboxStore(db),
       _photosTable = db.photos.actualTableName;

  final PhotoRepository photos;
  final PhotoStorage storage;
  final PhotoTransferQueue queue;
  final OutboxStore outbox;

  /// The outbox's name for the `photos` table, which is what a pending
  /// tombstone is looked up under.
  final String _photosTable;

  /// Notices what needs moving, then moves it.
  Future<PhotoSyncReport> sync({DateTime? now}) async {
    await photos.reconcile(now: now);
    return drain(now: now);
  }

  /// Works the queue oldest-first, and stops at the first network failure.
  ///
  /// A partial drain is a normal outcome, not a broken one: what moved is gone
  /// from the queue, the entry that failed keeps its place with its attempt
  /// count raised and its message stored, and everything behind it is untouched
  /// and still in order. The next drain — the next foreground, or the sync
  /// engine's own backoff timer — picks up exactly there.
  ///
  /// ## Why a removal waits for its tombstone
  ///
  /// Deleting a task deletes its photos, and bytes deleted from Storage are
  /// gone for good — there is no undelete, and the other device may not have
  /// seen the deletion yet. So the order matters, and it is: **tombstone
  /// first, bytes second.**
  ///
  /// If the object went first and the tombstone never arrived — this phone is
  /// offline for a fortnight, or never comes back at all — the other device
  /// would be left holding a live row that names an object which no longer
  /// exists. It cannot tell that from "not uploaded yet", so it would wait
  /// forever for bytes nobody is ever going to send, and if it had never
  /// cached the photo it has lost it with no record of why.
  ///
  /// Tombstone first inverts which way the inconsistency falls. The worst case
  /// becomes an object in the bucket that no row references: it costs storage,
  /// it is invisible in the app, and it can be deleted by hand. That is the
  /// recoverable half of the trade, and a removal therefore stays queued — not
  /// failed, not dropped — for as long as the photo's row is still sitting in
  /// the outbox.
  ///
  /// In practice it waits no time at all: `SyncRunner` drains the outbox before
  /// it gets here, so by the time a removal is looked at, the tombstone it is
  /// waiting for has usually gone up in the same sync.
  Future<PhotoSyncReport> drain({DateTime? now}) async {
    var uploaded = 0;
    var downloaded = 0;
    var removed = 0;
    var deferred = 0;

    for (final entry in await queue.pending()) {
      final photo = await photos.photo(entry.photoId);
      if (photo == null) {
        // No row at all. Nothing names these bytes and nothing ever will.
        await queue.remove(entry.photoId);
        continue;
      }

      try {
        switch (entry.operation) {
          case PhotoTransferOperation.upload:
            if (await _upload(photo, now: now)) {
              uploaded++;
            } else {
              deferred++;
            }
          case PhotoTransferOperation.download:
            if (await _download(photo)) {
              downloaded++;
            } else {
              deferred++;
            }
          case PhotoTransferOperation.remove:
            if (await _remove(photo)) {
              removed++;
            } else {
              deferred++;
            }
        }
      } on PhotoStorageFailure catch (failure) {
        await queue.recordFailure(entry.photoId, failure.message);
        return PhotoSyncReport(
          uploaded: uploaded,
          downloaded: downloaded,
          removed: removed,
          deferred: deferred,
          pending: await queue.count(),
          failure: failure,
        );
      }
    }

    return PhotoSyncReport(
      uploaded: uploaded,
      downloaded: downloaded,
      removed: removed,
      deferred: deferred,
      pending: await queue.count(),
    );
  }

  /// Puts a photo's bytes in the bucket, then records where they went.
  ///
  /// The bytes before the row, so `storage_path` stays a promise rather than a
  /// hope. If the process dies between the two, the entry is still queued and
  /// the next drain uploads the same bytes to the same key again — which is
  /// why [PhotoStorage.upload] overwrites rather than refusing.
  Future<bool> _upload(Photo photo, {DateTime? now}) async {
    final fileName = photo.localPath;
    final bytes = fileName == null ? null : await photos.cache.read(fileName);
    if (bytes == null) {
      // The row says this device has the bytes and it does not. Nothing to
      // upload and nothing to retry, but the entry stays with its message so
      // the screen can say the image is missing rather than pretending it is
      // still on its way. `reconcile` clears the claim on the next sync.
      await queue.recordFailure(photo.id, 'The image file is missing.');
      return false;
    }

    final key = PhotoRepository.storageKeyFor(photo);
    await storage.upload(
      path: key,
      bytes: bytes,
      contentType: PhotoRepository.contentTypeFor(fileName!),
    );
    await photos.markUploaded(photo.id, key, now: now);
    await queue.remove(photo.id);
    return true;
  }

  /// Fetches a photo the other device uploaded, and caches it.
  Future<bool> _download(Photo photo) async {
    final key = photo.storagePath;
    if (key == null) {
      // Nothing to fetch yet — the other device has the bytes and has not
      // uploaded them. Leave the entry; `reconcile` will settle it.
      return false;
    }
    final Uint8List bytes;
    try {
      bytes = await storage.download(key);
    } on PhotoNotInStorage {
      // The row promised bytes that are not there. Rare — `storage_path` is
      // only written after an upload succeeds — but survivable: keep the entry
      // and say so, rather than failing the whole drain over one object.
      await queue.recordFailure(
        photo.id,
        'The other device has not finished uploading this photo.',
      );
      return false;
    }

    final fileName = key.split('/').last;
    await photos.cache.write(fileName, bytes);
    await photos.markCached(photo.id, fileName);
    await queue.remove(photo.id);
    return true;
  }

  /// Deletes the object, but only once the tombstone that justifies it has
  /// been pushed. See the class comment on [drain].
  Future<bool> _remove(Photo photo) async {
    final key = photo.storagePath;
    if (key == null) {
      await queue.remove(photo.id);
      return false;
    }
    if (await outbox.holds(_photosTable, photo.id)) return false;

    try {
      await storage.remove(key);
    } on PhotoNotInStorage {
      // Already gone. The caller wanted nothing there, and there is nothing
      // there.
    }
    await queue.remove(photo.id);
    return true;
  }
}
