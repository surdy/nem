import 'dart:typed_data';

/// The bucket a reference photo's bytes live in.
///
/// Named here because both the Dart side and `supabase/README.md` have to
/// agree on it, and a typo would be a 404 that reads like an empty bucket.
const photoBucket = 'reference-photos';

/// The three Storage requests nem makes, and nothing else.
///
/// ## This is a testing seam, not a backend abstraction
///
/// The same distinction `SyncTransport` draws in `sync/sync_transport.dart`,
/// and drawn again here for the same reason. ADR 0002 says there is
/// deliberately no repository or gateway wrapping Supabase and not to add one
/// "for flexibility"; this is the other thing — the narrow seam
/// `DigestNotifier` is for the notification plugin and `TagGateway` is for NFC.
/// What decides which it is, is what sits on each side of the line:
///
/// * Below it — [SupabasePhotoStorage], the only implementation there will ever
///   be — is three `supabase_flutter` storage calls with no translation, no
///   retry, no caching and no decisions. It is shaped like the Storage API on
///   purpose, so it cannot quietly grow into a portability layer.
/// * Above it is every decision photos make — when to upload, what a 404 on a
///   download means, whether a removal may go before its tombstone has been
///   pushed, how a failure is retried and surfaced. None of that is Supabase's,
///   all of it is where the bugs will be, and this seam is what lets it be
///   tested on a laptop with no Docker, no Supabase CLI, no project, no bucket
///   and no camera.
abstract class PhotoStorage {
  /// Puts [bytes] at [path], overwriting whatever is there.
  ///
  /// Overwriting rather than failing on a key that exists, and that is load
  /// bearing: the queue entry is only removed *after* the row has been told
  /// where the bytes went, so a process killed in between retries the same
  /// upload. An upsert makes that retry a no-op instead of an error that can
  /// never clear.
  Future<void> upload({
    required String path,
    required Uint8List bytes,
    required String contentType,
  });

  /// Fetches the bytes at [path].
  ///
  /// Throws [PhotoNotInStorage] when there is nothing there, which is a normal
  /// outcome rather than an error: the other device has pushed the row and not
  /// yet the bytes.
  Future<Uint8List> download(String path);

  /// Deletes the object at [path]. Already gone is success — the caller wanted
  /// nothing there, and there is nothing there.
  Future<void> remove(String path);
}

/// There is no object at that key.
class PhotoNotInStorage implements Exception {
  const PhotoNotInStorage(this.path);

  final String path;

  @override
  String toString() => 'PhotoNotInStorage($path)';
}

/// Storage could not be reached, or refused the request.
///
/// The counterpart of `SyncTransportFailure`, kept as its own type rather than
/// reused so that nothing in `sync/` has to know photos exist — but carrying
/// the same [isAuthFailure] flag, because [SyncRunner] makes the same decision
/// from it: an expired token is not a network that is about to come back, so it
/// is surfaced rather than retried on a timer.
class PhotoStorageFailure implements Exception {
  const PhotoStorageFailure(this.message, {this.isAuthFailure = false});

  final String message;
  final bool isAuthFailure;

  @override
  String toString() => 'PhotoStorageFailure($message)';
}
