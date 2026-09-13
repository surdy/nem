/// A user-defined grouping that cuts across targets (CONTEXT.md — "Category").
///
/// Kitchen, car, admin. A category is *what kind* of work something is, where a
/// target is *where* the work is done — which is why a task can be in several
/// categories at once but sits at no more than one target, and why a category
/// is not a property of a target at all.
///
/// The word "tag" is never used for any of this. A tag is a physical NFC tag
/// and nothing else (CONTEXT.md — "Tag"); the collision is the reason the
/// glossary gives this idea a word of its own.
///
/// Immutable, and free of any persistence concern. Like [Target], the
/// soft-delete timestamp is deliberately absent: the repository only ever hands
/// back live categories, so a [Category] in hand is one that still exists.
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.color,
  });

  final String id;

  /// What the grouping is called — "Kitchen", "The car", "Admin".
  final String name;

  /// The swatch it is shown in, as a 32-bit ARGB value, or null when one was
  /// never chosen. [categorySwatches] holds the ones the UI offers.
  final int? color;

  final DateTime createdAt;
  final DateTime updatedAt;
}

/// The swatches a category can be coloured with.
///
/// Stored as plain ARGB integers rather than as `Color`s so that nothing in the
/// domain or the database layer depends on Flutter, and so the stored value is
/// the same number on both devices whatever either build's theme is.
///
/// Deliberately a short list. A free colour picker would let two categories be
/// told apart only by someone with the two chips side by side, and the point of
/// the colour is to be recognisable in a list at a glance.
const categorySwatches = <int>[
  0xFF4285F4, // blue
  0xFF34A853, // green
  0xFFFBBC05, // amber
  0xFFEA4335, // red
  0xFF9C27B0, // purple
  0xFF00ACC1, // teal
  0xFFFF7043, // orange
  0xFF795548, // brown
];

/// The swatch a category with no colour of its own is drawn in.
const uncolouredCategorySwatch = 0xFF9E9E9E;

/// [Category.color], or the neutral fallback.
int swatchFor(Category category) => category.color ?? uncolouredCategorySwatch;
