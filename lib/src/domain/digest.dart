/// The time of day the digest fires, as wall-clock hours and minutes.
///
/// Wall clock rather than an instant: "08:00" means eight in the morning every
/// morning, including the morning a daylight saving transition makes 23 or 25
/// hours long. The instant is resolved per day, against the device's zone, at
/// the point of scheduling (ADR 0010 takes the same line for occurrences).
class DigestTime implements Comparable<DigestTime> {
  const DigestTime({required this.hour, required this.minute})
    : assert(hour >= 0 && hour < 24, 'hour must be 0-23'),
      assert(minute >= 0 && minute < 60, 'minute must be 0-59');

  final int hour;
  final int minute;

  /// Parses "HH:mm", returning null for anything else.
  ///
  /// Tolerant on the way in because the value comes back out of storage, where
  /// a hand-edited or half-written row must not crash the launch path.
  static DigestTime? tryParse(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return DigestTime(hour: hour, minute: minute);
  }

  /// "08:00" — the storage form, and stable regardless of locale.
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
  int compareTo(DigestTime other) =>
      (hour * 60 + minute).compareTo(other.hour * 60 + other.minute);

  @override
  bool operator ==(Object other) =>
      other is DigestTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => 'DigestTime($asHhMm)';
}

/// Whether the digest is on, and when it fires (CONTEXT.md — "Digest").
///
/// This is the whole of the digest's configuration. Per-task reminders are a
/// separate notion with separate settings (CONTEXT.md — "Reminder"), and
/// nothing here should be reused for them.
class DigestSettings {
  const DigestSettings({required this.isEnabled, required this.time});

  /// Off until the user turns it on, so nothing schedules — and no permission
  /// is asked for — behind their back on first launch.
  static const defaults = DigestSettings(
    isEnabled: false,
    time: DigestTime(hour: 8, minute: 0),
  );

  final bool isEnabled;
  final DigestTime time;

  DigestSettings copyWith({bool? isEnabled, DigestTime? time}) =>
      DigestSettings(
        isEnabled: isEnabled ?? this.isEnabled,
        time: time ?? this.time,
      );

  @override
  bool operator ==(Object other) =>
      other is DigestSettings &&
      other.isEnabled == isEnabled &&
      other.time == time;

  @override
  int get hashCode => Object.hash(isEnabled, time);

  @override
  String toString() =>
      'DigestSettings(${isEnabled ? 'on' : 'off'}, ${time.asHhMm})';
}

/// What one day's digest has to say: how much is due, and how much is overdue.
///
/// Kept apart from the wording so the counting can be tested without pinning
/// the copy, and the copy without pinning the counting.
class DigestCounts {
  const DigestCounts({required this.dueToday, required this.overdue});

  static const none = DigestCounts(dueToday: 0, overdue: 0);

  final int dueToday;
  final int overdue;

  int get total => dueToday + overdue;

  /// True when there is nothing to say, and therefore nothing to send.
  bool get isEmpty => total == 0;

  /// The notification title.
  String get title => dueToday > 0 ? 'Due today' : 'Overdue';

  /// The notification body, e.g. "2 tasks due today, 3 overdue".
  ///
  /// Says "task"/"tasks" rather than chore or item, and "overdue" rather than
  /// late or outstanding (CONTEXT.md).
  String get body {
    final parts = <String>[
      if (dueToday > 0) '$dueToday ${_tasks(dueToday)} due today',
      if (overdue > 0)
        dueToday > 0
            ? '$overdue overdue'
            : '$overdue ${_tasks(overdue)} overdue',
    ];
    return parts.join(', ');
  }

  static String _tasks(int count) => count == 1 ? 'task' : 'tasks';

  @override
  bool operator ==(Object other) =>
      other is DigestCounts &&
      other.dueToday == dueToday &&
      other.overdue == overdue;

  @override
  int get hashCode => Object.hash(dueToday, overdue);

  @override
  String toString() => 'DigestCounts(due $dueToday, overdue $overdue)';
}
