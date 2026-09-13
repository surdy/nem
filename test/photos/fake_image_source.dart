import 'dart:typed_data';

import 'package:nem/src/photos/image_source_gateway.dart';

/// A camera and a photo library that are neither.
///
/// The seam the task screen picks through, so "attaching a photo" can be tested
/// on a laptop with no camera in it — the same bargain `FakeTagGateway` makes
/// for a laptop with no NFC in it.
class FakeImageSource implements ImageSourceGateway {
  FakeImageSource({Uint8List? bytes, this.extension = 'jpg'})
    : bytes = bytes ?? Uint8List.fromList(const [1, 2, 3, 4]);

  /// What the next pick returns, or null for a picker the user dismissed.
  Uint8List? bytes;
  String extension;

  /// Every origin picked from, in order.
  final List<PhotoOrigin> picks = [];

  @override
  Future<PickedImage?> pick(PhotoOrigin origin) async {
    picks.add(origin);
    final bytes = this.bytes;
    if (bytes == null) return null;
    return PickedImage(bytes: bytes, extension: extension);
  }
}
