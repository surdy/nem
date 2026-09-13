import 'dart:io';

/// A reference photo: an image attached to a task showing what the work
/// involves — which filter, which valve, where the stopcock is (CONTEXT.md —
/// "Reference photo").
///
/// Attached to a **task** and never to a completion. That is a design decision
/// rather than an omission: nem's photos say what the work *is*, not that it
/// was done, so there is no photo field on a completion and none is coming.
/// The glossary spells it out.
///
/// ## A photo is a file plus a row
///
/// The row is this. It is an ordinary synced row of an ordinary table, and it
/// moves between devices exactly as a task does. The *bytes* do not: they go to
/// Supabase Storage through a queue of their own (`photo_transfer_queue.dart`),
/// because the outbox is a dirty set of rows and a row is not a megabyte.
///
/// The two are kept consistent by never letting the row claim something that is
/// not true yet, which takes exactly two nullable columns:
///
/// * [localPath] — the name of the cache file on *this* device, or null when
///   this device does not hold the bytes. Device-local, and the one column of
///   this table that sync never carries (see `SyncedTable.deviceLocalColumns`):
///   whether a phone has the bytes on disk is that phone's business, and
///   replicating it would have the second device believe it holds a file it has
///   never downloaded.
/// * [storagePath] — the object key in the bucket, or null when the bytes have
///   not reached Storage yet. Written **only after** an upload has succeeded,
///   which makes a non-null value a promise: if a row names a storage path,
///   the bytes are there.
///
/// So the two failure directions are both survivable, and neither is a
/// half-written photo:
///
/// * **Row pushed, bytes not yet uploaded.** The far device sees a photo with
///   no storage path and says so — "waiting for the other device" — rather than
///   showing a broken image. When the upload lands, the row is updated and
///   pushed again, and the far device downloads it on its next sync.
/// * **Bytes uploaded, row not yet pushed.** An object in the bucket that
///   nothing references. It costs storage and nothing else, and the very next
///   drain of the outbox pushes the row that claims it. Losing the row
///   entirely — the phone is dropped in a canal — leaves an orphan object, and
///   an orphan object is the cheap half of this trade: the expensive half would
///   be a row that names bytes which are not there, because no device can tell
///   that from "not uploaded yet" and both would wait forever.
class Photo {
  const Photo({
    required this.id,
    required this.taskId,
    this.storagePath,
    this.localPath,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;

  /// The task this photo is attached to.
  ///
  /// No foreign key, here or in Postgres, for the reason ADR 0011 gives for
  /// `completions.task_id`: a pull delivers rows per table in no guaranteed
  /// order, so a photo can legitimately arrive before its task.
  final String taskId;

  /// The object key inside the bucket, or null while the bytes have not been
  /// uploaded. Non-null means the bytes are in Storage.
  final String? storagePath;

  /// The cache file's name on this device, or null when the bytes are not here.
  ///
  /// A *name*, not a path. The directory it sits in is the app's support
  /// directory, whose absolute path changes between installs on iOS, so an
  /// absolute path stored here would rot the first time the container moved.
  final String? localPath;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Soft delete, so a delete beats a stale update when sync arrives
  /// (PLAN.md).
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// Whether the bytes have reached Storage.
  bool get isUploaded => storagePath != null;

  /// Whether this device holds the bytes — which is the whole of whether the
  /// photo can be shown with no network (ADR 0001).
  bool get isCached => localPath != null;
}

/// The byte work a photo is waiting for.
///
/// Three operations rather than one, because all three cross the network, all
/// three can fail while offline, and all three have to survive a restart — so
/// all three belong in the same durable queue rather than in whichever one of
/// them happened to be written first.
enum PhotoTransferOperation {
  /// This device has the bytes and Storage does not.
  upload,

  /// Storage has the bytes and this device does not.
  download,

  /// The photo was deleted here and the object has to go.
  remove,
}

/// One photo's outstanding byte work.
class PhotoTransfer {
  const PhotoTransfer({
    required this.photoId,
    required this.operation,
    required this.enqueuedAt,
    this.attempts = 0,
    this.lastError,
  });

  final String photoId;
  final PhotoTransferOperation operation;

  /// When this photo first went dirty for this operation.
  final DateTime enqueuedAt;

  /// How many drains have tried and failed. Kept for the same reason the
  /// outbox keeps it: so work that can never be done is visible rather than
  /// silent.
  final int attempts;

  /// The last failure's message, which is what the task screen surfaces.
  final String? lastError;

  bool get hasFailed => lastError != null;

  @override
  String toString() =>
      'PhotoTransfer($photoId, ${operation.name}, attempts: $attempts)';
}

/// A photo as the task screen needs it: the row, the file if this device has
/// it, and whatever byte work is still outstanding.
///
/// Assembled by `PhotoRepository.watchPhotosForTask`, so the screen asks one
/// question and gets one answer rather than joining three sources itself.
class TaskPhoto {
  const TaskPhoto({required this.photo, this.file, this.transfer});

  final Photo photo;

  /// The cached image, or null when the bytes are not on this device.
  final File? file;

  /// The queued upload, download or removal, if any.
  final PhotoTransfer? transfer;

  /// Whether there is something to draw. Answered by the filesystem and never
  /// by the network (ADR 0001) — a cached photo displays in a basement.
  bool get isReady => file != null;

  /// What the tile says under the image, or null when there is nothing worth
  /// saying because the photo is simply there.
  ///
  /// A failed transfer is never silent: it keeps its place in the queue, it is
  /// retried on the sync engine's own backoff, and it says so here in the
  /// meantime (issue #15 — "never silently dropped").
  String? get statusLabel {
    final transfer = this.transfer;
    if (transfer != null && transfer.hasFailed) {
      return switch (transfer.operation) {
        PhotoTransferOperation.upload => 'Upload failed — retrying',
        PhotoTransferOperation.download => 'Download failed — retrying',
        PhotoTransferOperation.remove => 'Not yet removed — retrying',
      };
    }
    if (transfer?.operation == PhotoTransferOperation.upload) {
      return 'Waiting to upload';
    }
    if (isReady) return null;
    // No bytes here, and nothing queued that would fetch them: the other
    // device made this photo and has not uploaded it yet. Not an error — there
    // is nothing this device can do but wait, and saying so is kinder than a
    // broken image.
    if (!photo.isUploaded) return 'Waiting for the other device';
    return 'Downloading';
  }

  /// The failure's own words, for the line under the list.
  String? get errorMessage => transfer?.lastError;
}
