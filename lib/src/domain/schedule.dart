import 'interval_unit.dart';

/// A floating schedule: an interval measured forward from the last completion
/// (CONTEXT.md — "Floating schedule"; ADR 0005).
///
/// Immutable and free of any persistence concern, so the due date engine can be
/// exercised without a database.
class FloatingSchedule {
  const FloatingSchedule({
    required this.intervalN,
    required this.intervalUnit,
    required this.startDate,
  }) : assert(intervalN > 0, 'A floating interval must be at least 1');

  /// How many [intervalUnit]s pass between completions.
  final int intervalN;

  final IntervalUnit intervalUnit;

  /// The date the task begins, used as the base when there is no completion.
  final DateTime startDate;

  /// Human label for the interval, e.g. "Every 3 days".
  String get label => 'Every ${intervalUnit.labelFor(intervalN)}';

  @override
  String toString() =>
      'FloatingSchedule($intervalN ${intervalUnit.name}, from $startDate)';
}

/// The due date of a floating schedule.
///
/// `due date = (last completion ?? start date) + interval` (PLAN.md).
///
/// This is a DERIVED value (ADR 0004): it is a pure function of the schedule
/// and the completion history, never something the user edits. [lastCompletedAt]
/// is optional because a task that has never been completed falls back to its
/// start date — but the no-completion case is not special-cased, it is just the
/// absent argument.
DateTime floatingDueDate(
  FloatingSchedule schedule, {
  DateTime? lastCompletedAt,
}) {
  final base = lastCompletedAt ?? schedule.startDate;
  return addInterval(base, schedule.intervalN, schedule.intervalUnit);
}

/// Adds [n] [unit]s to [base] using calendar arithmetic rather than a fixed
/// [Duration].
///
/// Calendar arithmetic keeps the wall-clock time of day stable across daylight
/// saving transitions, and clamps to the end of a short month — 31 January plus
/// one month is 28 February, not 3 March.
DateTime addInterval(DateTime base, int n, IntervalUnit unit) {
  return switch (unit) {
    IntervalUnit.day => _addDays(base, n),
    IntervalUnit.week => _addDays(base, n * 7),
    IntervalUnit.month => _addMonths(base, n),
    IntervalUnit.year => _addMonths(base, n * 12),
  };
}

DateTime _addDays(DateTime base, int days) =>
    _rebuild(base, base.year, base.month, base.day + days);

DateTime _addMonths(DateTime base, int months) {
  final zeroBased = base.year * 12 + (base.month - 1) + months;
  final year = zeroBased ~/ 12;
  final month = zeroBased % 12 + 1;
  final lastDay = _daysInMonth(year, month);
  return _rebuild(base, year, month, base.day < lastDay ? base.day : lastDay);
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Rebuilds [base] on a new date, preserving its time of day and its UTC-ness.
DateTime _rebuild(DateTime base, int year, int month, int day) {
  return base.isUtc
      ? DateTime.utc(
          year,
          month,
          day,
          base.hour,
          base.minute,
          base.second,
          base.millisecond,
          base.microsecond,
        )
      : DateTime(
          year,
          month,
          day,
          base.hour,
          base.minute,
          base.second,
          base.millisecond,
          base.microsecond,
        );
}
