import 'dart:async';

import 'package:nem/src/nfc/tag_gateway.dart';

/// The NFC hardware, in software.
///
/// [TagGateway] is the whole of nem's contact with the plugin, so a fake of it
/// is the whole of what a test needs to exercise writing a tag, a tag too small
/// to take the URI, a locked tag, a phone with NFC switched off and a phone
/// with no NFC in it at all — none of which can be arranged on a laptop, and
/// one of which cannot be arranged at all without deliberately ruining a tag.
class FakeTagGateway implements TagGateway {
  FakeTagGateway({
    this.available = TagAvailability.enabled,
    this.presentation = TagSessionPresentation.background,
    this.writeOutcome = const TagWritten(),
  });

  /// What [availability] answers. Mutable, because NFC can be switched on while
  /// a screen is looking at it.
  TagAvailability available;

  @override
  TagSessionPresentation presentation;

  /// What the next write comes to, unless [pendingWrite] is holding it open.
  TagWriteOutcome writeOutcome;

  /// Set to leave a write hanging, so the "waiting for a tag" state can be
  /// looked at and cancelled.
  Completer<TagWriteOutcome>? pendingWrite;

  /// Every URI a write was asked for, in order.
  final written = <String>[];

  /// Every session that was stopped, and what the iOS sheet was told to say.
  final stopped = <({String? message, String? errorMessage})>[];

  void Function(TagRead read)? _onRead;

  /// Whether a read session is open.
  bool get reading => _onRead != null;

  /// Hands a tag to the open read session, the way the hardware would.
  void present(TagRead read) {
    final onRead = _onRead;
    if (onRead == null) {
      throw StateError('No read session is open, so no tag can be presented');
    }
    onRead(read);
  }

  @override
  Future<TagAvailability> availability() async => available;

  @override
  Future<void> startReading({
    required void Function(TagRead read) onRead,
    String? prompt,
  }) async {
    _onRead = onRead;
  }

  @override
  Future<TagWriteOutcome> writeUri(String uri, {String? prompt}) {
    written.add(uri);
    return pendingWrite?.future ?? Future.value(writeOutcome);
  }

  @override
  Future<void> stop({String? message, String? errorMessage}) async {
    stopped.add((message: message, errorMessage: errorMessage));
    _onRead = null;
  }
}
