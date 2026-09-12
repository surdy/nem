/// Where a task's due date sits relative to today (PLAN.md — "States").
///
/// The due list groups by this: Overdue, Today, Soon.
enum DueStatus {
  /// The due date has passed — "Overdue" in CONTEXT.md.
  overdue,

  /// The due date is today.
  dueToday,

  /// The due date is still ahead.
  upcoming;

  /// The heading this status appears under on the due list.
  String get groupHeading => switch (this) {
    DueStatus.overdue => 'Overdue',
    DueStatus.dueToday => 'Today',
    DueStatus.upcoming => 'Soon',
  };
}

/// Whole calendar days between [due] and [now], positive when [due] is in the
/// past.
///
/// Compared by calendar day rather than elapsed hours, so a task due at 09:00
/// is not "1 day late" at 08:00 the following morning — it is one day late all
/// of that day.
int daysLate(DateTime due, DateTime now) =>
    _dateOnly(now).difference(_dateOnly(due)).inDays;

/// Classifies a due date against [now].
DueStatus dueStatusFor(DateTime due, DateTime now) {
  final late = daysLate(due, now);
  if (late > 0) return DueStatus.overdue;
  if (late == 0) return DueStatus.dueToday;
  return DueStatus.upcoming;
}

/// The badge text for an overdue task, e.g. "3 days late".
///
/// Returns null when the task is not overdue.
String? overdueLabel(DateTime due, DateTime now) {
  final late = daysLate(due, now);
  if (late <= 0) return null;
  return late == 1 ? '1 day late' : '$late days late';
}

DateTime _dateOnly(DateTime value) {
  final local = value.isUtc ? value.toLocal() : value;
  return DateTime(local.year, local.month, local.day);
}
