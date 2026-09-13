import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'photo_storage.dart';

/// The only implementation of [PhotoStorage]: `supabase_flutter`, spoken to
/// directly (ADR 0002).
///
/// Nothing in this file decides anything. It holds a [SupabaseClient] handed to
/// it by whoever owns the session, turns three requests into three Storage
/// calls, and translates errors. There is no repository, no DTO and no second
/// backend behind a flag — a self-hosted instance exposes the identical Storage
/// API and is reached by typing a different URL into the settings screen.
class SupabasePhotoStorage implements PhotoStorage {
  const SupabasePhotoStorage(this.client);

  final SupabaseClient client;

  StorageFileApi get _bucket => client.storage.from(photoBucket);

  @override
  Future<void> upload({
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) {
    return _guard(
      () => _bucket.uploadBinary(
        path,
        bytes,
        // `upsert` so that re-running an upload whose bookkeeping did not
        // finish is a no-op rather than a 409 that can never clear — see
        // [PhotoStorage.upload].
        fileOptions: FileOptions(contentType: contentType, upsert: true),
      ),
    );
  }

  @override
  Future<Uint8List> download(String path) =>
      _guard(() => _bucket.download(path));

  @override
  Future<void> remove(String path) => _guard(() async {
    await _bucket.remove([path]);
  });

  /// Everything the network or Storage can throw, narrowed to the two outcomes
  /// the queue acts on.
  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on StorageException catch (error) {
      // 404 for an object that is not there, and 400 with `not_found` for the
      // same thing on some versions of the Storage API. Either way it means
      // "the bytes have not arrived yet", which is a state and not a failure.
      if (error.statusCode == '404' || error.error == 'not_found') {
        throw PhotoNotInStorage(error.message);
      }
      throw PhotoStorageFailure(
        error.message,
        // An expired or missing token is 401; a bucket policy that refuses is
        // 403, which with nem's single-account policies means the signed-in
        // account is not the one the data belongs to.
        isAuthFailure: error.statusCode == '401' || error.statusCode == '403',
      );
    } on AuthException catch (error) {
      throw PhotoStorageFailure(error.message, isAuthFailure: true);
    } on Object catch (error) {
      // A socket that will not open, a DNS name that does not resolve, a
      // self-hosted URL with a typo in it. All the same answer: not now.
      throw PhotoStorageFailure('$error');
    }
  }
}
