/// The NFC hardware, narrowed to the four things nem asks of it.
///
/// The plugin lives behind this interface and nowhere else, the way the camera
/// lives behind `ScanPreviewBuilder` (#7): every decision above this line —
/// which outcome a failed write is, when a session may start, what a tag
/// resolves to — is exercised in tests against a fake, on a machine with no NFC
/// hardware in it.
///
/// "Tag" here is NFC hardware and nothing else (CONTEXT.md).
library;

/// Whether this device can read and write tags, and whether it can right now.
enum TagAvailability {
  /// There is NFC hardware and it is switched on.
  enabled,

  /// There is NFC hardware and the user has switched it off.
  ///
  /// Android only. iOS has no user-facing NFC toggle, so an iPhone that cannot
  /// scan reports [unsupported] instead — there is nothing to ask the user to
  /// turn on.
  disabled,

  /// No NFC hardware, or a platform nem's plugin does not cover.
  unsupported,
}

/// Whether a read session can run quietly under nem's own screen, or takes the
/// screen over with the system's.
///
/// This is the one platform difference the scan screen cannot hide: Android
/// polls in the background, so a tag can be read while the camera is still
/// looking for a label, and iOS presents a system sheet over everything, which
/// is not something to raise uninvited on top of a live camera. A property of
/// the gateway rather than a `defaultTargetPlatform` check in the widget, so a
/// test can drive both.
enum TagSessionPresentation {
  /// The session is invisible and nem's own UI stays in front of it (Android).
  background,

  /// The session raises the system's own sheet, so it needs a deliberate tap to
  /// start (iOS).
  systemSheet,
}

/// What came off one tag in a read session.
sealed class TagRead {
  const TagRead();
}

/// The tag carried a string, which is what the scan flow resolves.
///
/// Not necessarily one of nem's: a tag somebody else wrote carries its own
/// payload, and that is a value a binding can point at a target just as well
/// (CONTEXT.md — "Binding").
final class TagValueRead extends TagRead {
  const TagValueRead(this.value);

  final String value;
}

/// The tag was detected but nothing readable came off it — no NDEF message, or
/// a message of a type that is not a string.
final class TagUnreadable extends TagRead {
  const TagUnreadable([this.detail]);

  final String? detail;
}

/// How an attempt to write a tag ended.
///
/// The three named failures are the ones a person can act on, which is why they
/// are separate cases rather than one error with a message attached: a tag too
/// small needs a bigger tag, a locked tag needs a different tag, and an
/// unknown failure needs holding the phone still and trying again.
sealed class TagWriteOutcome {
  const TagWriteOutcome();
}

/// The tag now carries the URI.
final class TagWritten extends TagWriteOutcome {
  const TagWritten();
}

/// The tag is not big enough for the message.
///
/// Established *before* writing, by comparing the message against the tag's
/// reported capacity, because it cannot be established afterwards: Android
/// collapses over-capacity, tag-lost and RF failure into one bare `IOException`
/// and iOS's typed code does not survive the plugin's stringification. A thrown
/// error is therefore only ever [TagWriteFailed].
final class TagTooSmall extends TagWriteOutcome {
  const TagTooSmall({required this.needed, required this.capacity});

  /// The size of nem's NDEF message, in bytes.
  final int needed;

  /// What this tag can hold, in bytes.
  final int capacity;
}

/// The tag has been locked and can never be written again.
final class TagReadOnly extends TagWriteOutcome {
  const TagReadOnly();
}

/// The tag holds no NDEF structure and this platform cannot give it one.
///
/// Android can format a blank tag on the spot; iOS has no formatting API at
/// all, so an unformatted tag is a dead end on an iPhone. Most NTAG stock ships
/// pre-formatted, so this is the odd tag rather than the common one — but
/// "nothing happened" is not a useful thing to tell somebody holding a phone
/// against a sticker.
final class TagUnformatted extends TagWriteOutcome {
  const TagUnformatted();
}

/// The session ended without a tag — the user dismissed it, or it timed out.
final class TagWriteCancelled extends TagWriteOutcome {
  const TagWriteCancelled();
}

/// Anything else. Includes over-capacity failures that slipped past the
/// pre-check, which is why the message is kept.
final class TagWriteFailed extends TagWriteOutcome {
  const TagWriteFailed([this.detail]);

  final String? detail;
}

/// Reading and writing tags, and nothing else.
abstract interface class TagGateway {
  /// Whether a read session may be started without the user asking for one.
  TagSessionPresentation get presentation;

  /// Whether this device can scan at all, asked fresh every time: NFC can be
  /// switched off while nem is on screen.
  Future<TagAvailability> availability();

  /// Starts reading, calling [onRead] for each tag until [stop].
  ///
  /// Starting twice is harmless; the second call is ignored.
  Future<void> startReading({
    required void Function(TagRead read) onRead,
    String? prompt,
  });

  /// Writes [uri] to the next tag presented, and ends the session.
  ///
  /// Completes with what happened. Never throws for a tag-related reason — a
  /// broken write is a [TagWriteOutcome], because every one of them is
  /// something the screen has to say out loud.
  Future<TagWriteOutcome> writeUri(String uri, {String? prompt});

  /// Ends whatever session is running. Safe to call when none is.
  ///
  /// [message] and [errorMessage] are what the iOS sheet says as it closes, and
  /// are ignored on Android, which has no sheet.
  Future<void> stop({String? message, String? errorMessage});
}

/// Why a tag cannot take a message of [messageSize] bytes, or null when it can.
///
/// Pure, and the whole of the pre-write decision. Both failures it can name are
/// invisible afterwards: the exception a doomed write throws says neither
/// "locked" nor "too small", so asking the tag beforehand is the only way this
/// ticket's "distinct outcomes" criterion can be met at all.
TagWriteOutcome? refuseWrite({
  required bool isWritable,
  required int capacity,
  required int messageSize,
}) {
  if (!isWritable) return const TagReadOnly();
  if (messageSize > capacity) {
    return TagTooSmall(needed: messageSize, capacity: capacity);
  }
  return null;
}
