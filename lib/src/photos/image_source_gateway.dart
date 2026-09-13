import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Where a new reference photo comes from.
enum PhotoOrigin {
  /// Taken now, which is the common case: you are standing in front of the
  /// boiler wondering which valve it was.
  camera,

  /// Chosen from the photo library, for the picture you already took.
  library,
}

/// One image, as nem wants it: bytes and an extension.
class PickedImage {
  const PickedImage({required this.bytes, required this.extension});

  final Uint8List bytes;

  /// Without the dot, lowercased — what the cache file is named and what the
  /// object's content type is derived from.
  final String extension;
}

/// The camera and the photo library, behind the one interface that touches the
/// plugin.
///
/// The seam `TagGateway` is for NFC hardware and `DigestNotifier` is for the
/// notification plugin, and it exists for the same reason: there is no camera
/// on a laptop, `image_picker` returns a platform channel result that cannot be
/// faked from Dart, and every test of what happens *after* an image arrives
/// would otherwise be untestable. Nothing here decides anything; picking is one
/// call and the answer is bytes.
abstract class ImageSourceGateway {
  /// The chosen image, or null when the picker was dismissed.
  Future<PickedImage?> pick(PhotoOrigin origin);
}

/// The only implementation: `image_picker`.
class ImagePickerGateway implements ImageSourceGateway {
  ImagePickerGateway([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedImage?> pick(PhotoOrigin origin) async {
    final file = await _picker.pickImage(
      source: switch (origin) {
        PhotoOrigin.camera => ImageSource.camera,
        PhotoOrigin.library => ImageSource.gallery,
      },
      // A reference photo is looked at on a phone screen, and every byte of it
      // crosses a queue, a network and someone's data allowance. A modern
      // phone camera would otherwise hand over eight megabytes of detail that
      // nothing in nem can use — and the upload queue is exactly where that
      // would hurt, because a failed upload is retried.
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (file == null) return null;
    return PickedImage(
      bytes: await file.readAsBytes(),
      extension: _extensionOf(file.name),
    );
  }

  /// The extension of a picked file, defaulting to jpg.
  ///
  /// `imageQuality` re-encodes as JPEG on both platforms, so the default is
  /// also the usual answer; the name is still read rather than assumed,
  /// because a picker that hands back the original file would otherwise have
  /// its PNG stored under a `.jpg` name and served with the wrong content
  /// type.
  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'jpg';
    return name.substring(dot + 1).toLowerCase();
  }
}
