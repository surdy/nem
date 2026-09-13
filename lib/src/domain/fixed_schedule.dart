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

    final RecurrenceRule rule;
    try {
      rule = RecurrenceRule.fromString(rruleLine);
    } on FormatException {
      rethrow;
    } catch (error) {
      // `rrule` validates RFC 5545's combination rules with assertions —
      // "the second Tuesday, weekly" is not a rule at all — so an impossible
      // one arrives as an AssertionError in a debug build and as nothing in
      // release. Either way it is text nem cannot read, which callers already
      // handle; a rule that reached storage by hand must not crash a screen
      // in one build mode and not the other (ADR 0006).
      throw FormatException('$error', rruleLine);
    }

    return FixedSchedule(rule: rule, anchor: anchor, zoneId: zoneId);
  }

  /// Builds the schedule the editor can author: a frequency, an interval, a set
  /// of weekdays for a weekly rule, the shape of a monthly rule, and an end
  /// condition.
  ///
  /// That is the whole of the editor's vocabulary and deliberately not the
  /// whole of RFC 5545's — [rule] is a full [RecurrenceRule], so storage stays
  /// strictly more expressive than the editor (ADR 0006). [FixedScheduleDraft]
  /// is the same vocabulary as a value, and is what reads a stored rule back
  /// into it.
  factory FixedSchedule.build({
    required FixedFrequency frequency,
    int interval = 1,
    Set<int> weekdays = const {},
    MonthlyOn monthlyOn = MonthlyOn.dayOfMonth,
    FixedScheduleEnd end = const NeverEnds(),
    required DateTime startDate,
    required String zoneId,
  }) {
    assert(interval > 0, 'A fixed interval must be at least 1');
    return FixedSchedule(
      rule: RecurrenceRule(
        frequency: frequency.frequency,
        // `INTERVAL=1` is the default and is left out rather than written, so
        // two schedules that mean the same thing store the same string.
        interval: interval == 1 ? null : interval,
        byWeekDays: _byWeekDaysFor(
          frequency: frequency,
          weekdays: weekdays,
          monthlyOn: monthlyOn,
          startDate: startDate,
        ),
        // `UNTIL` is written in the same floating wall-clock frame as the
        // anchor, and at the last second of the chosen day so that the day
        // itself is included whatever time of day the occurrences fall at
        // (ADR 0010; `rrule` compares it against the floating occurrence).
        until: switch (end) {
          EndsOnDate(:final date) => DateTime.utc(
            date.year,
            date.month,
            date.day,
            23,
            59,
            59,
          ),
          _ => null,
        },
        count: switch (end) {
          EndsAfter(:final occurrences) => occurrences,
          _ => null,
        },
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
  /// `UNTIL` — the default end condition, and so most rules. Take what you need
  /// and no more; never materialise it without knowing the rule is bounded.
  ///
  /// A `COUNT` is counted from the anchor and not from [from], so asking from
  /// past the last occurrence yields nothing rather than a fresh run of `COUNT`
  /// more.
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

  /// This rule read back into the editor's vocabulary, or null when the editor
  /// cannot say it (ADR 0006).
  ///
  /// Null is the normal, expected answer for a rule that reached storage by
  /// hand-edit or import. Such a rule is shown as itself and read-only; nothing
  /// in nem rewrites it into something the editor could have authored.
  ///
  /// Computed once: decoding walks every `BYxxx` part.
  late final FixedScheduleDraft? draft = FixedScheduleDraft.of(this);

  /// Whether the editor could author this rule, and so whether it may be
  /// offered for editing rather than shown read-only (ADR 0006).
  bool get isEditable => draft != null;

  /// Human label for the schedule, e.g. "Every Tuesday", mirroring
  /// [FloatingSchedule.label].
  ///
  /// Falls back to the raw rule for anything the editor cannot author, so a
  /// hand-edited or imported rule reads as itself rather than as a lie.
  String get label => draft?.summary ?? rule.toString();

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

/// Which shape a monthly rule takes — the choice the editor offers, and the
/// whole of it.
///
/// Both weekday shapes read their weekday and their ordinal off the start date
/// rather than asking for them separately, which is what Google Calendar's
/// dialog does: choosing 20 January 2026 offers "the third Tuesday", not a
/// weekday picker and an ordinal picker to disagree with each other.
enum MonthlyOn {
  /// `BYMONTHDAY` — implied by the anchor, so nothing is written.
  ///
  /// RFC 5545 **skips** a month with no such day rather than clamping to its
  /// last one, which is the opposite of what a floating monthly interval does.
  /// Both are correct for what they mean and neither is quietly corrected into
  /// the other (ADR 0005).
  dayOfMonth,

  /// `BYDAY=<n><day>`, e.g. `BYDAY=3TU` — "the third Tuesday".
  nthWeekday,

  /// `BYDAY=-1<day>`, e.g. `BYDAY=-1TU` — "the last Tuesday".
  ///
  /// Distinct from a fifth weekday, which is not the same rule: `BYDAY=5TU`
  /// skips the months that have only four Tuesdays, and `BYDAY=-1TU` does not.
  /// The editor only ever writes the latter.
  lastWeekday,
}

/// When a fixed schedule stops producing occurrences: never, on a date, or
/// after a number of them.
sealed class FixedScheduleEnd {
  const FixedScheduleEnd();
}

/// Repeats for ever — neither `UNTIL` nor `COUNT`, and the default.
final class NeverEnds extends FixedScheduleEnd {
  const NeverEnds();

  @override
  bool operator ==(Object other) => other is NeverEnds;

  @override
  int get hashCode => (NeverEnds).hashCode;

  @override
  String toString() => 'NeverEnds()';
}

/// Repeats up to and including [date] — `UNTIL`.
///
/// [date] is a calendar date in the schedule's own zone, with no time of day:
/// "ends on 31 December" ends at the end of that day wherever the occurrences
/// sit within it.
final class EndsOnDate extends FixedScheduleEnd {
  const EndsOnDate(this.date);

  final DateTime date;

  @override
  bool operator ==(Object other) =>
      other is EndsOnDate &&
      other.date.year == date.year &&
      other.date.month == date.month &&
      other.date.day == date.day;

  @override
  int get hashCode => Object.hash(date.year, date.month, date.day);

  @override
  String toString() => 'EndsOnDate($date)';
}

/// Repeats [occurrences] times and then stops — `COUNT`.
///
/// Counted from the anchor, so the count survives however late the work is
/// done: a schedule of ten occurrences produces ten whatever the completion log
/// says.
final class EndsAfter extends FixedScheduleEnd {
  const EndsAfter(this.occurrences)
    : assert(occurrences > 0, 'A schedule ends after at least one occurrence');

  final int occurrences;

  @override
  bool operator ==(Object other) =>
      other is EndsAfter && other.occurrences == occurrences;

  @override
  int get hashCode => Object.hash(EndsAfter, occurrences);

  @override
  String toString() => 'EndsAfter($occurrences)';
}

/// Everything the fixed-schedule editor can say, as one value.
///
/// This is the narrow authoring vocabulary of ADR 0006 written down: frequency,
/// interval, weekday set, the shape of a monthly rule, and an end condition —
/// Google Calendar's custom recurrence dialog and no more. [toSchedule] writes
/// it out as an RRULE and [of] reads one back, so a rule this editor wrote
/// always survives the round trip through storage unchanged.
///
/// [of] returns **null** for a rule outside that vocabulary, which is not an
/// error: storage is deliberately more expressive than the UI, and such a rule
/// is shown as itself, read-only, rather than being rewritten into the nearest
/// thing the editor could have said.
class FixedScheduleDraft {
  const FixedScheduleDraft({
    required this.frequency,
    required this.startDate,
    required this.zoneId,
    this.interval = 1,
    this.weekdays = const {},
    this.monthlyOn = MonthlyOn.dayOfMonth,
    this.end = const NeverEnds(),
  }) : assert(interval > 0, 'A fixed interval must be at least 1');

  /// Reads [schedule] back into the editor's vocabulary, or returns null when
  /// it says something the editor cannot (ADR 0006).
  ///
  /// Strict on purpose. Every rule part is either understood or refused: an
  /// unrecognised part means the rule means something this build does not know,
  /// and guessing would hand the user an editor that silently drops it on save.
  static FixedScheduleDraft? of(FixedSchedule schedule) {
    final rule = schedule.rule;
    final frequency = FixedFrequency.of(rule.frequency);
    if (frequency == null) return null;

    // Parts the editor has no vocabulary for at all.
    if (rule.bySeconds.isNotEmpty ||
        rule.byMinutes.isNotEmpty ||
        rule.byHours.isNotEmpty ||
        rule.byYearDays.isNotEmpty ||
        rule.byWeeks.isNotEmpty ||
        rule.byMonths.isNotEmpty ||
        rule.bySetPositions.isNotEmpty) {
      return null;
    }
    // `WKST=MO` is RFC 5545's own default, so it says nothing the editor is not
    // already saying. The package refuses any other value.
    if (rule.weekStart != null && rule.weekStart != DateTime.monday) {
      return null;
    }

    final end = _endOf(rule);
    if (end == null) return null;

    final anchor = schedule.anchor;
    var weekdays = const <int>{};
    var monthlyOn = MonthlyOn.dayOfMonth;

    switch (frequency) {
      case FixedFrequency.daily:
      case FixedFrequency.yearly:
        if (rule.byWeekDays.isNotEmpty || rule.byMonthDays.isNotEmpty) {
          return null;
        }
      case FixedFrequency.weekly:
        if (rule.byMonthDays.isNotEmpty) return null;
        // "The second Tuesday" is meaningless weekly, and the editor's weekday
        // chips cannot express it.
        if (rule.byWeekDays.any((entry) => entry.hasOccurrence)) return null;
        weekdays = {for (final entry in rule.byWeekDays) entry.day};
      case FixedFrequency.monthly:
        final byMonthDays = rule.byMonthDays;
        final byWeekDays = rule.byWeekDays;
        // A day of the month or an nth weekday, never both.
        if (byMonthDays.isNotEmpty && byWeekDays.isNotEmpty) return null;
        if (byWeekDays.isNotEmpty) {
          final resolved = _monthlyOnOf(byWeekDays, anchor);
          if (resolved == null) return null;
          monthlyOn = resolved;
        } else if (byMonthDays.isNotEmpty) {
          // The editor writes no `BYMONTHDAY`, because RFC 5545 already reads
          // an absent one as the anchor's day. An explicit one saying exactly
          // that is the same rule spelled out, so it is editable; any other day
          // is a rule the editor cannot re-say and is left alone.
          if (byMonthDays.length != 1 || byMonthDays.single != anchor.day) {
            return null;
          }
        }
    }

    return FixedScheduleDraft(
      frequency: frequency,
      interval: rule.actualInterval,
      weekdays: weekdays,
      monthlyOn: monthlyOn,
      end: end,
      startDate: anchor,
      zoneId: schedule.zoneId,
    );
  }

  final FixedFrequency frequency;

  /// How many [frequency] units pass between occurrences — `INTERVAL`.
  final int interval;

  /// The weekdays a weekly rule repeats on, as `DateTime.monday`… — `BYDAY`.
  ///
  /// Empty means no `BYDAY` at all, which RFC 5545 reads as the anchor's own
  /// weekday, so the schedule means the same thing either way. Ignored by every
  /// frequency but [FixedFrequency.weekly].
  final Set<int> weekdays;

  /// The shape of a monthly rule. Ignored by every other frequency.
  final MonthlyOn monthlyOn;

  final FixedScheduleEnd end;

  /// The rule's `DTSTART` — wall-clock digits in [zoneId] (ADR 0010).
  ///
  /// Part of the draft rather than beside it, because the monthly shapes are
  /// read off it: "the third Tuesday" is a fact about this date.
  final DateTime startDate;

  final String zoneId;

  FixedScheduleDraft copyWith({
    FixedFrequency? frequency,
    int? interval,
    Set<int>? weekdays,
    MonthlyOn? monthlyOn,
    FixedScheduleEnd? end,
    DateTime? startDate,
    String? zoneId,
  }) => FixedScheduleDraft(
    frequency: frequency ?? this.frequency,
    interval: interval ?? this.interval,
    weekdays: weekdays ?? this.weekdays,
    monthlyOn: monthlyOn ?? this.monthlyOn,
    end: end ?? this.end,
    startDate: startDate ?? this.startDate,
    zoneId: zoneId ?? this.zoneId,
  );

  /// This draft as a schedule, ready to encode and store.
  FixedSchedule toSchedule() => FixedSchedule.build(
    frequency: frequency,
    interval: interval,
    weekdays: weekdays,
    monthlyOn: effectiveMonthlyOn,
    end: end,
    startDate: startDate,
    zoneId: zoneId,
  );

  /// The monthly shapes [startDate] can take — what the editor offers.
  ///
  /// A date in the last week of its month can be "the last Tuesday"; a date in
  /// the fifth week cannot be "the fifth Tuesday", because the editor does not
  /// author a rule that skips the months without one.
  List<MonthlyOn> get monthlyOptions => [
    MonthlyOn.dayOfMonth,
    if (_weekOfMonth(startDate) <= 4) MonthlyOn.nthWeekday,
    if (_isLastWeekOfMonth(startDate)) MonthlyOn.lastWeekday,
  ];

  /// [monthlyOn] corrected for a start date that has since moved.
  ///
  /// Changing the start date can take the chosen shape away — the 20th is the
  /// third Tuesday, the 29th is no numbered Tuesday at all. The intent survives
  /// the move rather than the setting silently going stale: a weekday shape
  /// stays a weekday shape.
  MonthlyOn get effectiveMonthlyOn {
    if (monthlyOptions.contains(monthlyOn)) return monthlyOn;
    return _isLastWeekOfMonth(startDate)
        ? MonthlyOn.lastWeekday
        : MonthlyOn.nthWeekday;
  }

  /// How a monthly shape reads in a sentence, e.g. "the 15th", "the third
  /// Tuesday". Also what the editor labels its options with.
  String monthlyClause(MonthlyOn on) => switch (on) {
    MonthlyOn.dayOfMonth => 'the ${_ordinal(startDate.day)}',
    MonthlyOn.nthWeekday =>
      'the ${_ordinalWords[_weekOfMonth(startDate)]} '
          '${_weekdayNames[startDate.weekday]}',
    MonthlyOn.lastWeekday => 'the last ${_weekdayNames[startDate.weekday]}',
  };

  /// Whether this rule skips the months that are too short for it.
  ///
  /// True only of a day-of-month rule past the 28th. Worth saying out loud in
  /// the editor: RFC 5545 drops February rather than clamping to its last day,
  /// which is the opposite of a floating monthly interval (ADR 0005), and it is
  /// not something to quietly correct.
  bool get skipsShortMonths =>
      frequency == FixedFrequency.monthly &&
      effectiveMonthlyOn == MonthlyOn.dayOfMonth &&
      startDate.day > 28;

  /// Whether the end condition falls before the schedule begins, so the rule
  /// produces no occurrences at all.
  ///
  /// The date picker cannot reach such a date, but moving the start date
  /// afterwards can, and a task with nothing ever due is worth saying out loud
  /// rather than leaving as a silently empty schedule.
  bool get endsBeforeItStarts => switch (end) {
    EndsOnDate(:final date) => DateTime(
      date.year,
      date.month,
      date.day,
    ).isBefore(DateTime(startDate.year, startDate.month, startDate.day)),
    _ => false,
  };

  /// The rule in plain language, e.g. "Every 2 weeks on Tuesday, Friday, for 10
  /// occurrences".
  ///
  /// Shown live while the rule is being built, and used as the schedule's label
  /// everywhere else, so what the editor promises and what the list says are
  /// one string with one definition.
  String get summary {
    final every = interval == 1
        ? 'Every ${frequency.unit.singular}'
        : 'Every ${frequency.unit.labelFor(interval)}';

    final base = switch (frequency) {
      FixedFrequency.daily || FixedFrequency.yearly => every,
      FixedFrequency.weekly when weekdays.isEmpty => every,
      FixedFrequency.weekly => () {
        final days = (weekdays.toList()..sort())
            .map((day) => _weekdayNames[day]!)
            .join(', ');
        return interval == 1 ? 'Every $days' : '$every on $days';
      }(),
      FixedFrequency.monthly =>
        '$every on ${monthlyClause(effectiveMonthlyOn)}',
    };

    return switch (end) {
      NeverEnds() => base,
      EndsOnDate(:final date) => '$base, until ${_formatDate(date)}',
      EndsAfter(:final occurrences) =>
        '$base, for $occurrences '
            '${occurrences == 1 ? 'occurrence' : 'occurrences'}',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is FixedScheduleDraft &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.weekdays.length == weekdays.length &&
      other.weekdays.containsAll(weekdays) &&
      other.effectiveMonthlyOn == effectiveMonthlyOn &&
      other.end == end &&
      other.startDate == startDate &&
      other.zoneId == zoneId;

  @override
  int get hashCode => Object.hash(
    frequency,
    interval,
    Object.hashAllUnordered(weekdays),
    effectiveMonthlyOn,
    end,
    startDate,
    zoneId,
  );

  @override
  String toString() =>
      'FixedScheduleDraft($summary, from $startDate in $zoneId)';
}

/// The end condition [rule] carries, or null when it has one the editor cannot
/// re-say.
///
/// An `UNTIL` is only editable when it sits at the last second of its day,
/// which is where [FixedSchedule.build] puts one. Anything else ends partway
/// through a day — a real distinction for a schedule with a time of day — and
/// re-saving it from a date picker would quietly move it.
FixedScheduleEnd? _endOf(RecurrenceRule rule) {
  final count = rule.count;
  if (count != null) return EndsAfter(count);

  final until = rule.until;
  if (until == null) return const NeverEnds();
  if (until.hour != 23 || until.minute != 59 || until.second != 59) return null;
  return EndsOnDate(DateTime(until.year, until.month, until.day));
}

/// Which monthly shape a `BYDAY` list says, given the anchor it is read
/// against, or null for one the editor cannot author.
MonthlyOn? _monthlyOnOf(List<ByWeekDayEntry> byWeekDays, DateTime anchor) {
  if (byWeekDays.length != 1) return null;
  final entry = byWeekDays.single;
  // The editor derives the weekday from the start date, so a rule naming a
  // different one is a rule it could not have written and cannot rewrite.
  if (entry.day != anchor.weekday) return null;

  if (entry.occurrence == -1 && _isLastWeekOfMonth(anchor)) {
    return MonthlyOn.lastWeekday;
  }
  final week = _weekOfMonth(anchor);
  if (entry.occurrence == week && week <= 4) return MonthlyOn.nthWeekday;
  return null;
}

/// The `BYDAY` list for a rule of this shape.
List<ByWeekDayEntry> _byWeekDaysFor({
  required FixedFrequency frequency,
  required Set<int> weekdays,
  required MonthlyOn monthlyOn,
  required DateTime startDate,
}) => switch (frequency) {
  FixedFrequency.weekly => [
    for (final day in weekdays.toList()..sort()) ByWeekDayEntry(day),
  ],
  FixedFrequency.monthly => switch (monthlyOn) {
    MonthlyOn.dayOfMonth => const [],
    // A fifth weekday is written as the last one rather than as `5`: the
    // editor never offers a rule that skips the months without a fifth.
    MonthlyOn.nthWeekday => [
      ByWeekDayEntry(startDate.weekday, switch (_weekOfMonth(startDate)) {
        final week when week <= 4 => week,
        _ => -1,
      }),
    ],
    MonthlyOn.lastWeekday => [ByWeekDayEntry(startDate.weekday, -1)],
  },
  FixedFrequency.daily || FixedFrequency.yearly => const [],
};

/// Which week of its month [date] falls in, 1–5.
int _weekOfMonth(DateTime date) => (date.day - 1) ~/ 7 + 1;

/// Whether [date] is in the last seven days of its month, and so is the last
/// such weekday in it.
bool _isLastWeekOfMonth(DateTime date) =>
    date.day + 7 > DateTime(date.year, date.month + 1, 0).day;

String _ordinal(int day) {
  final suffix = day >= 11 && day <= 13
      ? 'th'
      : switch (day % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$day$suffix';
}

String _formatDate(DateTime date) =>
    '${date.day} ${_monthNames[date.month - 1]} ${date.year}';

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

const _ordinalWords = {1: 'first', 2: 'second', 3: 'third', 4: 'fourth'};

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _weekdayNames = {
  DateTime.monday: 'Monday',
  DateTime.tuesday: 'Tuesday',
  DateTime.wednesday: 'Wednesday',
  DateTime.thursday: 'Thursday',
  DateTime.friday: 'Friday',
  DateTime.saturday: 'Saturday',
  DateTime.sunday: 'Sunday',
};
