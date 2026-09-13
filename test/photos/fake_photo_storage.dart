import 'dart:typed_data';

import 'package:nem/src/photos/photo_storage.dart';

/// A Storage bucket in a map.
///
/// The seam `PhotoSync` is written against, standing in for the real one the
/// way `FakeSyncTransport` stands in for PostgREST and `FakeTagGateway` for NFC
/// hardware. There is no Docker, no Supabase CLI, no project and no bucket on
/// the machine this is written on, and there is no camera either — so every
/// decision the queue makes is exercised here or not at all.
///
/// It is a model rather than a stub on the two points that matter: an upload
/// overwrites, as the real one does with `upsert`, and a download of an object
/// that is not there raises [PhotoNotInStorage], which is the 404 the real one
/// translates. What it deliberately does not model is the network — requests
/// fail when a test says so, not when a socket does.
class FakePhotoStorage implements PhotoStorage {
  /// key -> bytes.
  final Map<String, Uint8List> objects = {};

  /// key -> content type, so a test can assert what was sent.
  final Map<String, String> contentTypes = {};

  /// Set to make every request fail, as an unreachable backend does.
  PhotoStorageFailure? failure;

  int uploads = 0;
  int downloads = 0;
  int removals = 0;

  @override
  Future<void> upload({
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    _check();
    uploads++;
    objects[path] = bytes;
    contentTypes[path] = contentType;
  }

  @override
  Future<Uint8List> download(String path) async {
    _check();
    downloads++;
    final bytes = objects[path];
    if (bytes == null) throw PhotoNotInStorage(path);
    return bytes;
  }

  @override
  Future<void> remove(String path) async {
    _check();
    removals++;
    if (!objects.containsKey(path)) throw PhotoNotInStorage(path);
    objects.remove(path);
  }

  void _check() {
    final failure = this.failure;
    if (failure != null) throw failure;
  }
}
