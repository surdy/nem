import 'completion.dart';

/// The kind of scannable code a binding names (CONTEXT.md).
///
/// The three are physically different things and are never used
/// interchangeably: a [tag] is NFC hardware, a [label] is a QR code nem
/// generated and you printed, and a [barcode] is a product code that already
/// existed and that nem only recognises.
enum BindingKind {
  /// A physical NFC tag. NFC hardware only — never a category or a sticker.
  tag,

  /// A QR code nem generated, encoding [labelUriFor] and printed onto
  /// something.
  label,

  /// A pre-existing product code — EAN, UPC, Code 128 — that nem binds but did
  /// not create.
  barcode;

  /// How a completion recorded through a scan of this kind is sourced.
  ///
  /// The two enums are deliberately separate: [BindingKind] says what is stuck
  /// to the thing, [CompletionSource] says how a completion came to be
  /// recorded, and only this mapping connects them.
  CompletionSource get completionSource => switch (this) {
    BindingKind.tag => CompletionSource.tag,
    BindingKind.label => CompletionSource.label,
    BindingKind.barcode => CompletionSource.barcode,
  };

  /// How this kind reads in the UI — "Label".
  String get displayLabel => switch (this) {
    BindingKind.tag => 'Tag',
    BindingKind.label => 'Label',
    BindingKind.barcode => 'Barcode',
  };
}

/// The association between one scannable code and one target (CONTEXT.md —
/// "Binding").
///
/// A binding is what makes a scan mean something. The code itself carries no
/// meaning: `nem://t/<uuid>` on a label and `5010358210016` off a filter box are
/// both just strings until a binding points them at a target (ADR 0008).
///
/// Immutable, and free of any persistence concern. Like [Target] there is no
/// soft-delete timestamp here — the repository only hands back live bindings.
class Binding {
  const Binding({
    required this.id,
    required this.targetId,
    required this.kind,
    required this.value,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// The target this code resolves to (ADR 0008).
  ///
  /// May name a target that is not on this device: sync pulls rows per table in
  /// no guaranteed order, so a binding can legitimately arrive before its
  /// target (ADR 0011). Unresolvable is a state to handle, not an error.
  final String targetId;

  final BindingKind kind;

  /// What the scan reads: the target's uuid for a [BindingKind.tag] or a
  /// [BindingKind.label], the raw product code for a [BindingKind.barcode].
  ///
  /// Unique per (kind, value) — PLAN.md — so one code resolves to exactly one
  /// target, while the same target can carry a tag and a label at once.
  final String value;

  final DateTime createdAt;
  final DateTime updatedAt;

  @override
  String toString() => 'Binding($id, ${kind.name} $value -> $targetId)';
}

/// The URI scheme carried by tags and labels (ADR 0009).
const scanUriScheme = 'nem';

/// The single-letter host that says a scanned URI names a target.
const _targetHost = 't';

/// The URI a tag is written with and a label encodes: `nem://t/<uuid>`
/// (ADR 0009).
///
/// A custom scheme rather than an https URL, deliberately: an https URI would
/// need a registered domain with a hosted `apple-app-site-association`, and
/// from Android 16 it would also have lost the seamless tap-to-launch that was
/// the only argument for it.
String labelUriFor(String targetId) =>
    '$scanUriScheme://$_targetHost/$targetId';

/// The target id inside a scanned `nem://t/<uuid>`, or null when [raw] is not
/// one of ours.
///
/// Null is the normal answer, not a failure: every product barcode in the world
/// arrives here first. Anything that is not exactly scheme `nem`, host `t` and
/// one non-empty path segment is somebody else's code, and is treated as a raw
/// value to be bound rather than as a malformed nem URI.
String? targetIdFromScanUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() != scanUriScheme) return null;
  if (uri.host.toLowerCase() != _targetHost) return null;
  final segments = uri.pathSegments;
  if (segments.length != 1 || segments.single.isEmpty) return null;
  return segments.single;
}
