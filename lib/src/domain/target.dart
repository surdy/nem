/// A physical place or object that work is done on (CONTEXT.md — "Target").
///
/// Tasks belong to targets, and scannable codes will be bound to targets rather
/// than to tasks (ADR 0008): one spot hosts several routines, so a target is
/// what a tag resolves to, not a category a task happens to sit in.
///
/// Immutable, and free of any persistence concern. The soft-delete timestamp is
/// deliberately absent — the repository only ever hands back live targets, so a
/// [Target] in hand is one that still exists.
class Target {
  const Target({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.description,
  });

  final String id;

  /// What the thing is called — "the boiler", "the front door".
  final String name;

  /// Where it is or which one it is, when the name alone is ambiguous.
  final String? description;

  final DateTime createdAt;
  final DateTime updatedAt;
}
