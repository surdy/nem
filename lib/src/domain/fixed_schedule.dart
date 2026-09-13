import 'package:rrule/rrule.dart';
import 'package:timezone/timezone.dart' as tz;

import 'interval_unit.dart';
import 'schedule.dart';

/// A fixed schedule: due dates that come from the calendar and ignore when the
/// work was actually done (CONTEXT.md — "Fixed schedule"; ADR 0005).
///
/// Deliberately a separate representation from [FloatingSchedule] rather than a
/// generalisation of it. RRULE cannot express floating mode at all, because
/// floating depends on completion history rather than on the calendar, so there
/// is nothing to unify (ADR 0005).
///
/// Three pieces make one schedule:
///
/// * [rule] — the recurrence itself, an RFC 5545 RRULE (ADR 0006).
/// * [anchor] — the rule's `DTSTART`, as a **wall-clock local time**: digits
///   with no offset and no instant behind them. "09:00 on Tuesdays" is 09:00
///   on both sides of a daylight saving transition, which is only expressible
///   without an offset (ADR 0010).
/// * [zoneId] — the IANA zone those digits are read in, e.g.
///   `Europe/London`. An IANA id and never a fixed offset, because the offset
///   is a function of the date and the id is not (ADR 0010).
///
/// Immutable and free of any persistence concern, like [FloatingSchedule], so
/// the due date engine can be exercised without a database.
class FixedSchedule {
  FixedSchedule({
    required this.rule,
    required this.anchor,
    required this.zoneId,
  });

  /// Reads the stored form written by [encode].
  ///
  /// [defaultAnchor] and [defaultZoneId] are used only when the stored text is
  /// a bare `RRULE:` line with no `DTSTART` — a rule that arrived by hand-edit
  /// or import rather than through the editor (ADR 0006). The task's own start
  /// date and the device zone are the sensible stand-ins.
  ///
  /// Throws [FormatException] on anything it cannot read.
  factory FixedSchedule.parse(
    String stored, {
    required DateTime defaultAnchor,
    required String defaultZoneId,
  }) {
    String? rruleLine;
    String? dtstartLine;
    for (final line in stored.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final upper = trimmed.toUpperCase();
      if (upper.startsWith('RRULE:')) {
        rruleLine = trimmed;
      } else if (upper.startsWith('DTSTART')) {
        dtstartLine = trimmed;
      }
    }
    if (rruleLine == null) {
      throw FormatException('No RRULE line in the stored schedule', stored);
    }

    var anchor = defaultAnchor;
    var zoneId = defaultZoneId;
    if (dtstartLine != null) {
      final (parsedAnchor, parsedZoneId) = _parseDtstart(dtstartLine);
      anchor = parsedAnchor;
      zoneId = parsedZoneId ?? defaultZoneId;
    }

    return FixedSchedule(
      rule: RecurrenceRule.fromString(rruleLine),
      anchor: anchor,
      zoneId: zoneId,
    );
  }

  /// Builds the schedule the minimal editor can author: a frequency, an
  /// interval, and — for a weekly rule — a set of weekdays (issue #3).
  ///
  /// Day-of-month, nth-weekday and end conditions are issue #4. They are absent
  /// here, not impossible: [rule] is a full [RecurrenceRule], so storage stays
  /// strictly more expressive than the editor (ADR 0006).
  factory FixedSchedule.build({
    required FixedFrequency frequency,
    int interval = 1,
    Set<int> weekdays = const {},
    required DateTime startDate,
    required String zoneId,
  }) {
    assert(interval > 0, 'A fixed interval must be at least 1');
    final byWeekDays = frequency == FixedFrequency.weekly
        ? [for (final day in weekdays.toList()..sort()) ByWeekDayEntry(day)]
        : const <ByWeekDayEntry>[];
    return FixedSchedule(
      rule: RecurrenceRule(
        frequency: frequency.frequency,
        // `INTERVAL=1` is the default and is left out rather than written, so
        // two schedules that mean the same thing store the same string.
        interval: interval == 1 ? null : interval,
        byWeekDays: byWeekDays,
      ),
      anchor: startDate,
      zoneId: zoneId,
    );
  }

  final RecurrenceRule rule;

  /// The `DTSTART` anchor, as wall-clock digits in [zoneId].
  ///
  /// This is not an instant. It is a local [DateTime] used only for its
  /// year/month/day/hour/minute, and it fixes the recurrence's *phase* — which
  /// weeks an `INTERVAL=2` weekly rule lands in, which day of the month a
  /// monthly rule keeps. It is not a lower bound on the occurrences.
  final DateTime anchor;

  /// An IANA zone id such as `Europe/London` (ADR 0010).
  final String zoneId;

  /// The zone [anchor]'s digits are read in.
  ///
  /// Resolved lazily so that constructing a schedule does not require the tz
  /// database to be loaded — only expanding one does.
  late final tz.Location location = tz.getLocation(zoneId);

  /// The stored form: an RFC 5545 `DTSTART` line and an `RRULE` line.
  ///
  /// Both live in the single `tasks.rrule` column. The alternative was two more
  /// columns for the wall-clock anchor and the zone id, and RFC 5545 already
  /// has a notation for exactly this pair — `DTSTART;TZID=<zone>:<local time>`
  /// — which keeps the fixed representation to one column (ADR 0005) and keeps
  /// the calendar-export path of ADR 0006 open.
  ///
  /// Note the value carries no trailing `Z`: that is deliberate, and is what
  /// makes it a wall-clock time in `TZID` rather than an instant (ADR 0010).
  String encode() {
    final d = anchor;
    String two(int value) => value.toString().padLeft(2, '0');
    final date =
        '${d.year.toString().padLeft(4, '0')}${two(d.month)}${two(d.day)}';
    final time = '${two(d.hour)}${two(d.minute)}${two(d.second)}';
    return 'DTSTART;TZID=$zoneId:${date}T$time\n$rule';
  }

  /// The occurrences at or after the wall-clock date-time [from], lazily.
  ///
  /// [from] is wall-clock digits in [zoneId], not an instant — the same kind of
  /// value as [anchor].
  ///
  /// **The returned iterable is endless** for a rule with no `COUNT` or
  /// `UNTIL`, which is every rule the editor can author. Take what you need and
  /// no more; never materialise it.
  Iterable<tz.TZDateTime> occurrencesFrom(
    DateTime from, {
    bool inclusive = true,
  }) sync* {
    final start = _floating(anchor);
    final cursor = _floating(from);
    for (final occurrence in rule.getInstances(
      // `start` is the rule's DTSTART anchor, which defines the recurrence's
      // phase. It is NOT the query lower bound — `after` is. Passing the cursor
      // here instead would silently change which days the rule produces: a
      // fortnightly rule would re-phase onto whichever week the cursor fell in.
      start: start,
      // The package refuses a bound earlier than its own anchor, so a cursor
      // before the schedule began drops the bound instead. It would have
      // excluded nothing anyway: no occurrence precedes the anchor.
      after: cursor.isBefore(start) ? null : cursor,
      includeAfter: inclusive,
    )) {
      // Each occurrence is resolved to a real instant on its own, against that
      // date's offset in this schedule's zone. Resolving once and adding seven
      // days would drift by an hour at every daylight saving transition
      // (ADR 0010).
      yield tz.TZDateTime(
        location,
        occurrence.year,
        occurrence.month,
        occurrence.day,
        occurrence.hour,
        occurrence.minute,
      );
    }
  }

  /// The calendar date [instant] falls on in this schedule's zone, as
  /// wall-clock digits at midnight.
  ///
  /// A completion is an instant; occurrences are calendar days. This is the
  /// conversion between them, and it happens in the schedule's zone rather than
  /// the device's — a task on a London calendar is late by London days even if
  /// the phone is in Tokyo.
  DateTime dayOf(DateTime instant) {
    final zoned = tz.TZDateTime.from(instant, location);
    return DateTime(zoned.year, zoned.month, zoned.day);
  }

  /// Human label for the schedule, e.g. "Every Tuesday", mirroring
  /// [FloatingSchedule.label].
  ///
  /// Falls back to the raw rule for anything the minimal editor cannot author,
  /// so a hand-edited or imported rule reads as itself rather than as a lie.
  /// Presenting such a rule properly is issue #4.
  String get label {
    final frequency = FixedFrequency.of(rule.frequency);
    if (frequency == null || !_isEditorAuthorable) return rule.toString();

    final n = rule.actualInterval;
    final every = n == 1
        ? 'Every ${frequency.unit.singular}'
        : 'Every ${frequency.unit.labelFor(n)}';

    if (frequency != FixedFrequency.weekly || rule.byWeekDays.isEmpty) {
      return every;
    }
    final days = (rule.byWeekDays.toList()..sort())
        .map((entry) => _weekdayNames[entry.day]!)
        .join(', ');
    return n == 1 ? 'Every $days' : '$every on $days';
  }

  /// Whether the minimal editor could have produced this rule.
  ///
  /// Anything else reached storage by hand-edit or import (ADR 0006).
  bool get _isEditorAuthorable =>
      rule.until == null &&
      rule.count == null &&
      rule.byMonthDays.isEmpty &&
      rule.byYearDays.isEmpty &&
      rule.byWeeks.isEmpty &&
      rule.byMonths.isEmpty &&
      rule.bySetPositions.isEmpty &&
      rule.byHours.isEmpty &&
      rule.byMinutes.isEmpty &&
      rule.bySeconds.isEmpty &&
      rule.byWeekDays.every((entry) => entry.hasNoOccurrence) &&
      (rule.byWeekDays.isEmpty || rule.frequency == Frequency.weekly);

  @override
  String toString() => 'FixedSchedule($rule, from $anchor in $zoneId)';
}

/// The due date of a fixed schedule: the **earliest occurrence after the last
/// completed occurrence**, and not the next future occurrence (ADR 0007).
///
/// This is the difference that produces the collapse. If three Tuesdays pass
/// uncompleted, this stays pinned on the *first* missed Tuesday, so the task is
/// one row reading "15 days late" rather than three rows of backlog. Completing
/// then advances it past every missed occurrence at once, to the first
/// occurrence after the day the work was done.
///
/// **So the returned date is routinely in the past, and that is correct.** It
/// looks like stale data and is not: a fixed schedule's due date only moves
/// when a completion moves it, never merely because time passed.
///
/// A derived value (ADR 0004), like [floatingDueDate] — a pure function of the
/// schedule and the completion history. Returns null only when the rule has run
/// out of occurrences, which needs an end condition the editor cannot author.
///
/// The "last completed occurrence" is found by calendar day in the schedule's
/// own zone, so completing a task on the day it was due counts as completing
/// that occurrence whatever time of day the work happened.
///
/// ADR 0007 words the advance as "the first occurrence after today", which is
/// the same thing whenever the work is recorded as it is done. A completion
/// back-dated to last week advances to the occurrence after *that* day instead,
/// which can still be in the past — the completion log is the truth and the due
/// date follows it (ADR 0004), rather than the clock overriding what was said.
DateTime? fixedDueDate(FixedSchedule schedule, {DateTime? lastCompletedAt}) {
  if (lastCompletedAt == null) {
    // Never completed: the first occurrence the rule produces at all, which for
    // an overdue new task is already in the past.
    return _firstOrNull(schedule.occurrencesFrom(schedule.anchor));
  }
  // The first occurrence on a later calendar day than the completion. Adding a
  // day with `addInterval` rather than `Duration(days: 1)` keeps this exact
  // across daylight saving, where a day is not always 24 hours.
  final nextDay = addInterval(
    schedule.dayOf(lastCompletedAt),
    1,
    IntervalUnit.day,
  );
  return _firstOrNull(schedule.occurrencesFrom(nextDay));
}

/// The frequency a fixed schedule repeats on — the editor's whole vocabulary
/// for `FREQ`, and deliberately narrower than RFC 5545's (ADR 0006).
enum FixedFrequency {
  daily(Frequency.daily, IntervalUnit.day),
  weekly(Frequency.weekly, IntervalUnit.week),
  monthly(Frequency.monthly, IntervalUnit.month),
  yearly(Frequency.yearly, IntervalUnit.year);

  const FixedFrequency(this.frequency, this.unit);

  /// The RFC 5545 `FREQ` value.
  final Frequency frequency;

  /// The unit its interval counts in, shared with floating schedules so both
  /// editors say "weeks" the same way.
  final IntervalUnit unit;

  /// The matching value for [frequency], or null for the sub-daily frequencies
  /// the editor does not offer.
  static FixedFrequency? of(Frequency frequency) {
    for (final value in values) {
      if (value.frequency == frequency) return value;
    }
    return null;
  }
}

/// Relabels a wall-clock local time as UTC, preserving the digits.
///
/// This is the single most confusing line in the scheduling code and it is
/// deliberate (ADR 0010). `copyWith(isUtc: true)` does not convert: 09:00 local
/// goes in and 09:00 UTC comes out, which is precisely what is wanted, because
/// the `rrule` package refuses non-UTC input and knows nothing about time
/// zones. What it expands is therefore a *floating* time — "Tuesday at 09:00",
/// with no instant behind it — and [FixedSchedule.occurrencesFrom] turns each
/// result back into a real instant afterwards.
///
/// Sub-minute precision is dropped because the stored `DTSTART` carries none.
DateTime _floating(DateTime wallClock) =>
    wallClock.copyWith(isUtc: true, second: 0, millisecond: 0, microsecond: 0);

/// The first element, or null — without draining an endless iterable.
T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

/// Reads `DTSTART;TZID=Europe/London:20260106T090000`, returning the wall-clock
/// digits and the zone id.
(DateTime, String?) _parseDtstart(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) {
    throw FormatException('DTSTART has no value', line);
  }
  final parameters = line.substring(0, colon);
  final value = line.substring(colon + 1).trim();

  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$',
  ).firstMatch(value);
  if (match == null) {
    // A trailing `Z` lands here too: a UTC instant is not a wall-clock time,
    // and silently treating it as one would move the task by the zone offset.
    throw FormatException('DTSTART is not a local date-time', value);
  }
  int group(int index) => int.parse(match.group(index)!);

  String? zoneId;
  for (final parameter in parameters.split(';').skip(1)) {
    final equals = parameter.indexOf('=');
    if (equals < 0) continue;
    if (parameter.substring(0, equals).toUpperCase() == 'TZID') {
      zoneId = parameter.substring(equals + 1);
    }
  }

  return (
    DateTime(group(1), group(2), group(3), group(4), group(5), group(6)),
    zoneId,
  );
}

const _weekdayNames = {
  DateTime.monday: 'Monday',
  DateTime.tuesday: 'Tuesday',
  DateTime.wednesday: 'Wednesday',
  DateTime.thursday: 'Thursday',
  DateTime.friday: 'Friday',
  DateTime.saturday: 'Saturday',
  DateTime.sunday: 'Sunday',
};
