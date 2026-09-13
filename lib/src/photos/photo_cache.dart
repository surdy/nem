import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Where a photo's bytes live on this device.
///
/// This is the whole of "photos display with no network" (ADR 0001): the task
/// screen draws a `File`, never a URL, so a phone in a cellar shows every photo
/// it has ever seen and a phone that has never had a network shows every photo
/// it took itself.
///
/// ## Not the cache directory, despite the name
///
/// The files go in the application *support* directory. `getTemporaryDirectory`
/// — the one both platforms are free to empty whenever they feel like it — is
/// exactly wrong here: a photo taken offline and not yet uploaded exists in
/// precisely one place, and the OS reclaiming that place would destroy the
/// image while leaving a row that says it exists. Support-directory files are
/// deleted when the app is, and not before.
///
/// The name is still right for what the directory *means* once an upload has
/// gone through: after that, the bytes are in Storage too and the local copy is
/// a cache which a fresh install re-downloads.
class PhotoCache {
  /// A cache over a directory that is already known — which is every test.
  PhotoCache(Future<Directory> root) : _open = (() => root);

  PhotoCache._(this._open);

  /// The production cache: `<app support>/reference_photos`.
  ///
  /// The plugin is not called here. It is called the first time a photo's
  /// bytes are actually wanted, which on a device with no photos is never —
  /// and which keeps building the provider free of a platform channel that
  /// would have nowhere to report a failure.
  PhotoCache.applicationSupport()
    : this._(
        () async => Directory(
          _join(
            (await getApplicationSupportDirectory()).path,
            'reference_photos',
          ),
        ),
      );

  /// Asked for once, the first time it is needed; the answer is kept.
  final Future<Directory> Function() _open;

  Directory? _resolved;

  /// The cache file for a stored name, whether or not it exists yet.
  Future<File> file(String name) async {
    final dir = _resolved ??= await _open();
    return File(_join(dir.path, name));
  }

  /// Writes bytes, creating the directory the first time.
  Future<File> write(String name, Uint8List bytes) async {
    final target = await file(name);
    await target.parent.create(recursive: true);
    return target.writeAsBytes(bytes, flush: true);
  }

  /// The bytes, or null when this device does not hold them.
  Future<Uint8List?> read(String name) async {
    final source = await file(name);
    if (!source.existsSync()) return null;
    return source.readAsBytes();
  }

  Future<bool> contains(String name) async => (await file(name)).existsSync();

  /// Removes the local copy. Missing is not an error: the caller's intent is
  /// "there should be no file here", and there is not.
  Future<void> delete(String name) async {
    final target = await file(name);
    if (target.existsSync()) await target.delete();
  }

  /// The cache file's name for a photo — its id and the image's extension.
  ///
  /// Derived rather than random so the name is the same on both devices and
  /// stays derivable from the row alone, and stored in `photos.local_path`
  /// anyway so that changing this scheme later cannot strand the files already
  /// written under the old one.
  static String fileNameFor(String photoId, String extension) =>
      '$photoId.${extension.replaceFirst('.', '').toLowerCase()}';

  /// Joins with a forward slash rather than reaching for `package:path`.
  ///
  /// nem ships to iOS and Android, whose separator this is, and the tests run
  /// on the same posix paths. A dependency to concatenate two strings would be
  /// the more surprising choice.
  static String _join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';
}
