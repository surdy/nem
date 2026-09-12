/// The unit of a floating schedule's interval.
///
/// A floating schedule is expressed as an interval — a count plus a unit —
/// measured forward from the last completion (CONTEXT.md, ADR 0005).
enum IntervalUnit {
  day,
  week,
  month,
  year;

  /// Label for one unit, e.g. "day".
  String get singular => switch (this) {
    IntervalUnit.day => 'day',
    IntervalUnit.week => 'week',
    IntervalUnit.month => 'month',
    IntervalUnit.year => 'year',
  };

  /// Label for more than one unit, e.g. "days".
  String get plural => '${singular}s';

  /// Label for [count] units, e.g. "3 days".
  String labelFor(int count) => '$count ${count == 1 ? singular : plural}';
}
