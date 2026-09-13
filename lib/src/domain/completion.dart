/// How a completion came to be recorded.
///
/// Only [manual] is reachable so far. The three scanning sources arrive with
/// the scan flow in P2, and are listed here already because the column is a
/// constrained value in PLAN.md and drift persists the enum by name — adding a
/// value is additive, and the order of the values carries no meaning.
enum CompletionSource {
  /// Ticked off by hand from the due list.
  manual,

  /// Resolved by scanning an NFC tag (CONTEXT.md — "Tag").
  tag,

  /// Resolved by scanning a nem-generated QR label (CONTEXT.md — "Label").
  label,

  /// Resolved by scanning a pre-existing product barcode (CONTEXT.md —
  /// "Barcode").
  barcode,
}

/// A record that a task was performed at a particular moment (CONTEXT.md —
/// "Completion").
///
/// Completions are immutable events (ADR 0004). Nothing in nem rewrites one:
/// taking a completion back means tombstoning it with [deletedAt], and
/// correcting one means tombstoning it and appending a replacement. The task's
/// due date and last-completed timestamp are derived from the surviving
/// completions, never the other way round.
class Completion {
  const Completion({
    required this.id,
    required this.taskId,
    required this.completedAt,
    required this.source,
    required this.deviceId,
    required this.createdAt,
    this.note,
    this.deletedAt,
  });

  final String id;
  final String taskId;

  /// When the work was done. Not the same as [createdAt]: a completion can be
  /// recorded after the fact, or out of order once two devices sync.
  final DateTime completedAt;

  final CompletionSource source;
  final String? note;

  /// Which device recorded this, so an append-only merge can still say where a
  /// completion came from (PLAN.md — "Sync").
  final String deviceId;

  /// When the row was written, as opposed to when the work happened.
  final DateTime createdAt;

  /// Set when this completion has been taken back. A tombstoned completion
  /// stops counting towards the derived state but is never deleted, so a
  /// tombstone merges with the other device's copy instead of losing to it.
  final DateTime? deletedAt;

  bool get isTombstoned => deletedAt != null;

  @override
  String toString() =>
      'Completion($id, task $taskId, at $completedAt, ${source.name}'
      '${isTombstoned ? ', tombstoned' : ''})';
}
