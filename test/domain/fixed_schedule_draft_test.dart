import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:timezone/data/latest.dart' as tz_data;

const london = 'Europe/London';
const newYork = 'America/New_York';
const lordHowe = 'Australia/Lord_Howe';

/// 2026 Tuesdays in January: the 6th, 13th, 20th and 27th. The 20th is the
/// third Tuesday; the 27th is the last.
FixedScheduleDraft draft({
  FixedFrequency frequency = FixedFrequency.weekly,
  int interval = 1,
  Set<int> weekdays = const {},
  MonthlyOn monthlyOn = MonthlyOn.dayOfMonth,
  FixedScheduleEnd end = const NeverEnds(),
  DateTime? startDate,
  String zoneId = london,
}) => FixedScheduleDraft(
  frequency: frequency,
  interval: interval,
  weekdays: weekdays,
  monthlyOn: monthlyOn,
  end: end,
  startDate: startDate ?? DateTime(2026, 1, 6),
  zoneId: zoneId,
);

/// The `RRULE:` line a draft stores, without its `DTSTART`.
String ruleOf(FixedScheduleDraft value) =>
    value.toSchedule().encode().split('\n').last;

String two(int value) => value.toString().padLeft(2, '0');

String date(DateTime value) =>
    '${value.year}-${two(value.month)}-${two(value.day)}';

/// The occurrence dates of a draft, at most [count] of them.
///
/// Bounded even for a rule that ends, because a rule that does not is the
/// default and draining one never returns.
List<String> dates(FixedScheduleDraft value, {int count = 6, DateTime? from}) {
  final schedule = value.toSchedule();
  return schedule
      .occurrencesFrom(from ?? schedule.anchor)
      .take(count)
      .map(date)
      .toList();
}

/// A draft written out to storage and read back in: editor → storage → editor.
///
/// The defaults are deliberately nothing like the draft's own anchor and zone,
/// so a round trip that quietly fell back to them would be visible rather than
/// coincidentally right.
FixedScheduleDraft? roundTrip(FixedScheduleDraft value) => FixedSchedule.parse(
  value.toSchedule().encode(),
  defaultAnchor: DateTime(1999, 9, 9),
  defaultZoneId: 'Etc/UTC',
).draft;

/// Reads a rule that arrived by hand-edit or import (ADR 0006).
FixedSchedule stored(String text, {DateTime? anchor, String zoneId = london}) =>
    FixedSchedule.parse(
      text,
      defaultAnchor: anchor ?? DateTime(2026, 1, 6),
      defaultZoneId: zoneId,
    );

/// Every rule the editor can author, as one table.
///
/// The cross product is the point: each frequency, each monthly shape and each
/// weekday set is taken through each end condition, because the end condition
/// is the part that changes whether the rule terminates at all.
List<FixedScheduleDraft> supportedRules() {
  final ends = [
    const NeverEnds(),
    EndsOnDate(DateTime(2027, 3, 31)),
    const EndsAfter(5),
  ];
  final rules = <FixedScheduleDraft>[];
  for (final end in ends) {
    for (final interval in [1, 2]) {
      rules.addAll([
        draft(frequency: FixedFrequency.daily, interval: interval, end: end),
        draft(interval: interval, end: end),
        draft(interval: interval, weekdays: {DateTime.tuesday}, end: end),
        draft(
          interval: interval,
          weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
          end: end,
        ),
        draft(
          interval: interval,
          weekdays: {
            DateTime.monday,
            DateTime.tuesday,
            DateTime.wednesday,
            DateTime.thursday,
            DateTime.friday,
            DateTime.saturday,
            DateTime.sunday,
          },
          end: end,
        ),
        draft(
          frequency: FixedFrequency.monthly,
          interval: interval,
          startDate: DateTime(2026, 1, 15),
          end: end,
        ),
        // Past the 28th, so the rule skips the short months rather than
        // clamping into them (ADR 0005).
        draft(
          frequency: FixedFrequency.monthly,
          interval: interval,
          startDate: DateTime(2026, 1, 31),
          end: end,
        ),
        draft(
          frequency: FixedFrequency.monthly,
          interval: interval,
          monthlyOn: MonthlyOn.nthWeekday,
          startDate: DateTime(2026, 1, 20),
          end: end,
        ),
        draft(
          frequency: FixedFrequency.monthly,
          interval: interval,
          monthlyOn: MonthlyOn.lastWeekday,
          startDate: DateTime(2026, 1, 27),
          end: end,
        ),
        draft(
          frequency: FixedFrequency.yearly,
          interval: interval,
          startDate: DateTime(2024, 2, 29),
          end: end,
        ),
        // A time of day and a zone that is neither the device's nor UTC.
        draft(
          interval: interval,
          weekdays: {DateTime.sunday},
          startDate: DateTime(2026, 3, 1, 9, 30),
          zoneId: newYork,
          end: end,
        ),
      ]);
    }
  }
  return rules;
}

void main() {
  setUpAll(tz_data.initializeTimeZones);

  group('monthly, as a day of the month', () {
    test('writes no BYMONTHDAY, because the anchor already says it', () {
      final value = draft(
        frequency: FixedFrequency.monthly,
        startDate: DateTime(2026, 1, 15),
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY');
      expect(dates(value, count: 3), [
        '2026-01-15',
        '2026-02-15',
        '2026-03-15',
      ]);
    });

    test('skips the months too short for it rather than clamping', () {
      // The consequence ADR 0005 records, and the editor says so out loud
      // rather than quietly correcting it.
      final value = draft(
        frequency: FixedFrequency.monthly,
        startDate: DateTime(2026, 1, 31),
      );
      expect(value.skipsShortMonths, isTrue);
      expect(dates(value, count: 3), [
        '2026-01-31',
        '2026-03-31',
        '2026-05-31',
      ]);
    });

    test('and says nothing about short months when it cannot hit one', () {
      expect(
        draft(
          frequency: FixedFrequency.monthly,
          startDate: DateTime(2026, 1, 15),
        ).skipsShortMonths,
        isFalse,
      );
      // Nor when the rule is a weekday one, which never misses a month.
      expect(
        draft(
          frequency: FixedFrequency.monthly,
          monthlyOn: MonthlyOn.lastWeekday,
          startDate: DateTime(2026, 1, 31),
        ).skipsShortMonths,
        isFalse,
      );
    });
  });

  group('monthly, as an nth weekday', () {
    test('reads the ordinal and the weekday off the start date', () {
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.nthWeekday,
        startDate: DateTime(2026, 1, 20),
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=3TU');
      expect(value.summary, 'Every month on the third Tuesday');
      expect(dates(value, count: 4), [
        '2026-01-20',
        '2026-02-17',
        '2026-03-17',
        '2026-04-21',
      ]);
    });

    test('the last weekday is a different rule from the fifth', () {
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.lastWeekday,
        startDate: DateTime(2026, 1, 27),
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=-1TU');
      expect(value.summary, 'Every month on the last Tuesday');
      // Every month has one, including the months with only four Tuesdays.
      expect(dates(value, count: 4), [
        '2026-01-27',
        '2026-02-24',
        '2026-03-31',
        '2026-04-28',
      ]);
    });

    test('a fifth-week start date is offered as the last, not the fifth', () {
      // 31 March 2026 is the fifth Tuesday of its month. `BYDAY=5TU` would skip
      // every month without one, which is not what "the same slot each month"
      // means, so the editor never offers it.
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.nthWeekday,
        startDate: DateTime(2026, 3, 31),
      );
      expect(value.monthlyOptions, [
        MonthlyOn.dayOfMonth,
        MonthlyOn.lastWeekday,
      ]);
      expect(value.effectiveMonthlyOn, MonthlyOn.lastWeekday);
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=-1TU');
    });

    test('a start date in the last week can be either the nth or the last', () {
      // 27 January 2026 is both the fourth Tuesday and the last one.
      expect(
        draft(
          frequency: FixedFrequency.monthly,
          startDate: DateTime(2026, 1, 27),
        ).monthlyOptions,
        [MonthlyOn.dayOfMonth, MonthlyOn.nthWeekday, MonthlyOn.lastWeekday],
      );
      // And they are genuinely different rules from February on.
      expect(
        dates(
          draft(
            frequency: FixedFrequency.monthly,
            monthlyOn: MonthlyOn.nthWeekday,
            startDate: DateTime(2026, 1, 27),
          ),
          count: 3,
        ),
        ['2026-01-27', '2026-02-24', '2026-03-24'],
      );
      expect(
        dates(
          draft(
            frequency: FixedFrequency.monthly,
            monthlyOn: MonthlyOn.lastWeekday,
            startDate: DateTime(2026, 1, 27),
          ),
          count: 3,
        ),
        ['2026-01-27', '2026-02-24', '2026-03-31'],
      );
    });

    test('a start date early in the month cannot be the last weekday', () {
      expect(
        draft(
          frequency: FixedFrequency.monthly,
          startDate: DateTime(2026, 1, 6),
        ).monthlyOptions,
        [MonthlyOn.dayOfMonth, MonthlyOn.nthWeekday],
      );
    });

    test('a weekday rule crosses a leap February without skipping it', () {
      // The last Thursday of February 2024 is the 29th.
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.lastWeekday,
        startDate: DateTime(2024, 2, 29),
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=-1TH');
      expect(dates(value, count: 4), [
        '2024-02-29',
        '2024-03-28',
        '2024-04-25',
        '2024-05-30',
      ]);
      // And in a common year February still has one, unlike a day-of-month
      // rule on the 29th.
      expect(
        dates(
          draft(
            frequency: FixedFrequency.monthly,
            monthlyOn: MonthlyOn.lastWeekday,
            startDate: DateTime(2025, 2, 27),
          ),
          count: 3,
        ),
        ['2025-02-27', '2025-03-27', '2025-04-24'],
      );
    });

    test('an interval keeps the shape, not just the month', () {
      expect(
        dates(
          draft(
            frequency: FixedFrequency.monthly,
            interval: 3,
            monthlyOn: MonthlyOn.nthWeekday,
            startDate: DateTime(2026, 1, 20),
          ),
          count: 3,
        ),
        ['2026-01-20', '2026-04-21', '2026-07-21'],
      );
    });

    test('the shape follows the start date when it moves', () {
      final third = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.nthWeekday,
        startDate: DateTime(2026, 1, 20),
      );
      final moved = third.copyWith(startDate: DateTime(2026, 2, 11));
      expect(moved.summary, 'Every month on the second Wednesday');
      expect(ruleOf(moved), 'RRULE:FREQ=MONTHLY;BYDAY=2WE');
    });
  });

  group('end conditions', () {
    test('never is the default and writes neither UNTIL nor COUNT', () {
      final value = draft(weekdays: {DateTime.tuesday});
      expect(value.end, const NeverEnds());
      expect(ruleOf(value), 'RRULE:FREQ=WEEKLY;BYDAY=TU');
      expect(value.summary, 'Every Tuesday');
    });

    test('a count stops after exactly that many occurrences', () {
      final value = draft(
        weekdays: {DateTime.tuesday},
        end: const EndsAfter(3),
      );
      expect(ruleOf(value), 'RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=TU');
      expect(value.summary, 'Every Tuesday, for 3 occurrences');
      // Asking for more than there are must terminate rather than hang.
      expect(dates(value, count: 10), [
        '2026-01-06',
        '2026-01-13',
        '2026-01-20',
      ]);
    });

    test('a count is counted from the start date, not from the question', () {
      final value = draft(
        weekdays: {DateTime.tuesday},
        end: const EndsAfter(3),
      );
      expect(dates(value, from: DateTime(2026, 1, 14), count: 10), [
        '2026-01-20',
      ]);
      // Past the last one there is nothing left, rather than three more.
      expect(dates(value, from: DateTime(2026, 2, 1), count: 10), isEmpty);
    });

    test('a count of one is a single occurrence', () {
      final value = draft(
        weekdays: {DateTime.tuesday},
        end: const EndsAfter(1),
      );
      expect(value.summary, 'Every Tuesday, for 1 occurrence');
      expect(dates(value, count: 5), ['2026-01-06']);
    });

    test('a date includes the whole of the last day', () {
      // The `UNTIL` sits at 23:59:59 so that an occurrence later in the day
      // than the anchor still counts. A midnight `UNTIL` would drop it.
      final value = draft(
        weekdays: {DateTime.tuesday},
        startDate: DateTime(2026, 1, 6, 9),
        end: EndsOnDate(DateTime(2026, 1, 20)),
      );
      expect(ruleOf(value), 'RRULE:FREQ=WEEKLY;UNTIL=20260120T235959;BYDAY=TU');
      expect(value.summary, 'Every Tuesday, until 20 January 2026');
      expect(dates(value, count: 10), [
        '2026-01-06',
        '2026-01-13',
        '2026-01-20',
      ]);
    });

    test('and excludes the day after it', () {
      expect(
        dates(
          draft(
            weekdays: {DateTime.tuesday},
            end: EndsOnDate(DateTime(2026, 1, 19)),
          ),
          count: 10,
        ),
        ['2026-01-06', '2026-01-13'],
      );
    });

    test('a date that precedes the start date produces nothing at all', () {
      final value = draft(
        weekdays: {DateTime.tuesday},
        end: EndsOnDate(DateTime(2025, 12, 1)),
      );
      expect(dates(value, count: 5), isEmpty);
      // Which the editor says out loud rather than leaving as a schedule that
      // is simply never due.
      expect(value.endsBeforeItStarts, isTrue);
    });

    test('ending on the start date itself is a schedule, not a mistake', () {
      final value = draft(
        weekdays: {DateTime.tuesday},
        startDate: DateTime(2026, 1, 6, 9),
        end: EndsOnDate(DateTime(2026, 1, 6)),
      );
      expect(value.endsBeforeItStarts, isFalse);
      expect(dates(value, count: 5), ['2026-01-06']);
    });

    test('an end date is wall-clock, so a DST shift cannot move it', () {
      // 8 March 2026 is the spring-forward Sunday in New York, and 5 April is
      // Lord Howe's half-hour shift. The last day is the same day either side.
      expect(
        dates(
          draft(
            frequency: FixedFrequency.daily,
            startDate: DateTime(2026, 3, 6, 9),
            zoneId: newYork,
            end: EndsOnDate(DateTime(2026, 3, 9)),
          ),
          count: 10,
        ),
        ['2026-03-06', '2026-03-07', '2026-03-08', '2026-03-09'],
      );
      expect(
        dates(
          draft(
            frequency: FixedFrequency.daily,
            startDate: DateTime(2026, 4, 3, 9),
            zoneId: lordHowe,
            end: EndsOnDate(DateTime(2026, 4, 6)),
          ),
          count: 10,
        ),
        ['2026-04-03', '2026-04-04', '2026-04-05', '2026-04-06'],
      );
    });

    test('a bounded rule runs out of due dates instead of repeating', () {
      final schedule = draft(
        weekdays: {DateTime.tuesday},
        end: const EndsAfter(2),
      ).toSchedule();
      expect(date(fixedDueDate(schedule)!), '2026-01-06');
      expect(
        date(
          fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2026, 1, 6))!,
        ),
        '2026-01-13',
      );
      expect(
        fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2026, 1, 13)),
        isNull,
      );
    });
  });

  group('an nth weekday across a daylight saving transition (ADR 0010)', () {
    test('keeps its wall-clock time on the day the clocks go forward', () {
      // The second Sunday of March is the transition day itself in New York.
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.nthWeekday,
        startDate: DateTime(2026, 3, 8, 9),
        zoneId: newYork,
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=2SU');

      final occurrences = value
          .toSchedule()
          .occurrencesFrom(DateTime(2026, 3, 8))
          .take(2)
          .toList();
      expect(occurrences.map(date), ['2026-03-08', '2026-04-12']);
      expect(occurrences.every((o) => o.hour == 9), isTrue);
      expect(occurrences[0].timeZoneOffset, const Duration(hours: -4));
    });

    test('and across a 30-minute transition', () {
      // Lord Howe Island shifts by half an hour on 5 April 2026, which is the
      // first Sunday of that month — so consecutive occurrences of this rule
      // straddle it.
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.nthWeekday,
        startDate: DateTime(2026, 3, 1, 9),
        zoneId: lordHowe,
      );
      expect(ruleOf(value), 'RRULE:FREQ=MONTHLY;BYDAY=1SU');

      final occurrences = value
          .toSchedule()
          .occurrencesFrom(DateTime(2026, 3, 1))
          .take(2)
          .toList();
      expect(occurrences.map(date), ['2026-03-01', '2026-04-05']);
      // The wall clock is what is held fixed, so the half hour comes out of
      // the elapsed time instead.
      expect(occurrences.every((o) => o.hour == 9), isTrue);
      expect(
        occurrences[0].timeZoneOffset - occurrences[1].timeZoneOffset,
        const Duration(minutes: 30),
      );
    });
  });

  group('the summary', () {
    test('names the weekdays of a weekly rule', () {
      expect(draft(weekdays: {DateTime.tuesday}).summary, 'Every Tuesday');
      expect(
        draft(
          interval: 2,
          weekdays: {DateTime.friday, DateTime.tuesday},
        ).summary,
        'Every 2 weeks on Tuesday, Friday',
      );
      expect(draft().summary, 'Every week');
    });

    test('names the day of the month, with its ordinal', () {
      String monthly(int day) => draft(
        frequency: FixedFrequency.monthly,
        startDate: DateTime(2026, 1, day),
      ).summary;
      expect(monthly(1), 'Every month on the 1st');
      expect(monthly(2), 'Every month on the 2nd');
      expect(monthly(3), 'Every month on the 3rd');
      expect(monthly(4), 'Every month on the 4th');
      expect(monthly(11), 'Every month on the 11th');
      expect(monthly(12), 'Every month on the 12th');
      expect(monthly(13), 'Every month on the 13th');
      expect(monthly(21), 'Every month on the 21st');
      expect(monthly(22), 'Every month on the 22nd');
      expect(monthly(23), 'Every month on the 23rd');
      expect(monthly(31), 'Every month on the 31st');
    });

    test('reads the other frequencies as intervals', () {
      expect(draft(frequency: FixedFrequency.daily).summary, 'Every day');
      expect(
        draft(frequency: FixedFrequency.daily, interval: 3).summary,
        'Every 3 days',
      );
      expect(draft(frequency: FixedFrequency.yearly).summary, 'Every year');
    });

    test('ends with the end condition', () {
      expect(
        draft(
          weekdays: {DateTime.tuesday},
          end: EndsOnDate(DateTime(2026, 12, 31)),
        ).summary,
        'Every Tuesday, until 31 December 2026',
      );
      expect(
        draft(
          frequency: FixedFrequency.monthly,
          interval: 2,
          monthlyOn: MonthlyOn.nthWeekday,
          startDate: DateTime(2026, 1, 20),
          end: const EndsAfter(12),
        ).summary,
        'Every 2 months on the third Tuesday, for 12 occurrences',
      );
    });

    test('is what the schedule labels itself with', () {
      final value = draft(
        frequency: FixedFrequency.monthly,
        monthlyOn: MonthlyOn.lastWeekday,
        startDate: DateTime(2026, 1, 27),
        end: const EndsAfter(4),
      );
      expect(value.toSchedule().label, value.summary);
      expect(
        value.toSchedule().label,
        'Every month on the last Tuesday, '
        'for 4 occurrences',
      );
    });
  });

  group('round trip — editor to storage and back', () {
    for (final original in supportedRules()) {
      test('${original.summary}, from ${date(original.startDate)}', () {
        final stored = original.toSchedule().encode();
        final returned = roundTrip(original);

        expect(
          returned,
          isNotNull,
          reason: 'the editor could not read back what it wrote: $stored',
        );
        expect(returned, original);
        // And re-encoding it changes nothing, so an edit-and-save cycle that
        // touches nothing stores the same bytes.
        expect(returned!.toSchedule().encode(), stored);
        expect(returned.summary, original.summary);
      });
    }
  });

  group('a rule the editor cannot represent (ADR 0006)', () {
    // Each of these can reach storage by hand-edit or by a future calendar
    // import. None of them may crash, and none may be rewritten into the
    // nearest thing the editor could have said.
    const unrepresentable = {
      'a weekday that is not the anchor\'s': 'RRULE:FREQ=MONTHLY;BYDAY=1MO',
      'a fifth weekday rather than the last': 'RRULE:FREQ=MONTHLY;BYDAY=5TU',
      'several weekdays in a monthly rule': 'RRULE:FREQ=MONTHLY;BYDAY=1MO,3MO',
      'several days of the month': 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15',
      'a day of the month that is not the anchor\'s':
          'RRULE:FREQ=MONTHLY;BYMONTHDAY=15',
      'a day of the month and a weekday at once':
          'RRULE:FREQ=MONTHLY;BYMONTHDAY=6;BYDAY=TU',
      'an UNTIL partway through a day':
          'RRULE:FREQ=WEEKLY;UNTIL=20261231T120000Z;BYDAY=TU',
      'a set position': 'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
      'a month filter': 'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU',
      'a week number': 'RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO',
      'a day of the year': 'RRULE:FREQ=YEARLY;BYYEARDAY=100',
      'a time of day': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=30',
      'a weekday on a daily rule': 'RRULE:FREQ=DAILY;BYDAY=MO',
      'a day of the month on a yearly rule': 'RRULE:FREQ=YEARLY;BYMONTHDAY=15',
      'a sub-daily frequency': 'RRULE:FREQ=HOURLY;INTERVAL=6',
    };

    for (final entry in unrepresentable.entries) {
      test('${entry.key} is read-only', () {
        final schedule = stored(entry.value);
        expect(schedule.draft, isNull);
        expect(schedule.isEditable, isFalse);
        // Shown as the rule itself rather than described as something else.
        // The parts come back in the package's own order, which is why this is
        // not compared to the stored text byte for byte — the stored text
        // itself is never touched, which `task_repository_test` pins down.
        expect(schedule.label, startsWith('RRULE:FREQ='));
        expect(schedule.label, isNot(startsWith('Every')));
      });
    }

    test('and still produces due dates', () {
      // Read-only is not inert: the rule the editor cannot say is still the
      // rule the task is on.
      final schedule = stored(
        'DTSTART;TZID=Europe/London:20260301T000000\n'
        'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU',
      );
      expect(schedule.isEditable, isFalse);
      expect(schedule.occurrencesFrom(DateTime(2026, 3, 1)).take(2).map(date), [
        '2026-03-08',
        '2027-03-14',
      ]);
      expect(date(fixedDueDate(schedule)!), '2026-03-08');
    });

    test('an explicit BYMONTHDAY that agrees with the anchor is editable', () {
      // The same rule spelled out: RFC 5545 reads an absent BYMONTHDAY as the
      // anchor's own day. The editor can say this one, so it offers it.
      final schedule = stored(
        'DTSTART;TZID=Europe/London:20260115T000000\n'
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=15',
      );
      expect(schedule.isEditable, isTrue);
      expect(schedule.draft!.monthlyOn, MonthlyOn.dayOfMonth);
      expect(schedule.label, 'Every month on the 15th');
    });

    test('WKST=MO is the standard default and says nothing extra', () {
      final schedule = stored(
        'DTSTART;TZID=Europe/London:20260106T000000\n'
        'RRULE:FREQ=WEEKLY;BYDAY=TU;WKST=MO',
      );
      expect(schedule.isEditable, isTrue);
      expect(schedule.label, 'Every Tuesday');
    });

    test('a rule that breaks RFC 5545 is unreadable, not a crash', () {
      // "The second Tuesday, weekly" is not a rule at all. The package
      // validates by assertion, so this is an AssertionError in a debug build
      // and nothing in release; either way it is text nem cannot read.
      expect(
        () => stored('RRULE:FREQ=WEEKLY;BYDAY=2TU'),
        throwsFormatException,
      );
    });
  });
}
