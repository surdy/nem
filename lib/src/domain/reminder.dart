/// The time of day a task's reminder fires, as wall-clock hours and minutes
/// (CONTEXT.md — "Reminder").
///
/// Wall clock rather than an instant: "19:00" means seven in the evening every
/// evening, including the evening a daylight saving transition makes 23 or 25
/// hours long. The instant is resolved per day, against the device's zone, at
/// the point of scheduling (ADR 0010 takes the same line for occurrences).
///
/// Deliberately not `DigestTime`, and deliberately not a shared "time of day"
/// abstraction. The digest and a reminder are different features that happen to
/// agree on a storage format today (CONTEXT.md keeps them apart, and
/// `domain/digest.dart` says in as many words that nothing of the digest's
/// configuration should be reused here). Unifying them would mean a change to
/// one silently becoming a change to the other.
class ReminderTime implements Comparable<ReminderTime> {
  /// [minute] defaults to zero, because reminders are chosen on the hour far
  /// more often than not — "bins at 7pm".
  const ReminderTime({required this.hour, this.minute = 0})
    : assert(hour >= 0 && hour < 24, 'hour must be 0-23'),
      assert(minute >= 0 && minute < 60, 'minute must be 0-59');

  final int hour;
  final int minute;

  /// Parses "HH:mm" out of `tasks.reminder_time`, returning null for anything
  /// else.
  ///
  /// Tolerant on the way in because the value comes back out of storage, where
  /// a hand-edited or half-synced row must not crash the due list. A row that
  /// cannot be read is a task with no reminder, which is also the state of
  /// every task that never opted in.
  static ReminderTime? tryParse(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return ReminderTime(hour: hour, minute: minute);
  }

  /// "19:00" — the storage form, and stable regardless of locale.
  String get asHhMm =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// This time of day on the calendar day of [day], in [day]'s own time zone.
  ///
  /// Built from the date parts rather than by adding a [Duration], so the
  /// result is the wall-clock time asked for even on a day that is not 24
  /// hours long.
  DateTime onDayOf(DateTime day) {
    final local = day.isUtc ? day.toLocal() : day;
    return DateTime(local.year, local.month, local.day, hour, minute);
  }

  @override
  int compareTo(ReminderTime other) =>
      (hour * 60 + minute).compareTo(other.hour * 60 + other.minute);

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => 'ReminderTime($asHhMm)';
}
