import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/due_list.dart';
import 'package:nem/src/domain/due_status.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/task.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const london = 'Europe/London';
const newYork = 'America/New_York';

/// 1 January 2026 is a Thursday; the Tuesdays are the 6th, 13th, 20th and 27th.
FixedSchedule weekly({
  Set<int> weekdays = const {DateTime.tuesday},
  int interval = 1,
  DateTime? startDate,
  String zoneId = london,
}) => FixedSchedule.build(
  frequency: FixedFrequency.weekly,
  interval: interval,
  weekdays: weekdays,
  startDate: startDate ?? DateTime(2026, 1, 1),
  zoneId: zoneId,
);

FixedSchedule every(
  FixedFrequency frequency,
  DateTime startDate, {
  int interval = 1,
  String zoneId = london,
}) => FixedSchedule.build(
  frequency: frequency,
  interval: interval,
  startDate: startDate,
  zoneId: zoneId,
);

String two(int value) => value.toString().padLeft(2, '0');

String date(DateTime value) =>
    '${value.year}-${two(value.month)}-${two(value.day)}';

/// The first [count] occurrence dates, as `yyyy-mm-dd`.
///
/// Always bounded: [FixedSchedule.occurrencesFrom] is endless for every rule
/// the editor can author, so nothing may drain it.
List<String> dates(FixedSchedule schedule, DateTime from, int count) =>
    schedule.occurrencesFrom(from).take(count).map(date).toList();

Task fixedTask(FixedSchedule schedule, {DateTime? lastCompletedAt}) => Task(
  id: 'task-1',
  title: 'Put the bins out',
  scheduleMode: ScheduleMode.fixed,
  rrule: schedule.encode(),
  fixedSchedule: schedule,
  startDate: schedule.anchor,
  lastCompletedAt: lastCompletedAt,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  // Every fixed schedule resolves its occurrences against the tz database
  // (ADR 0010), which the app loads in `initialiseTimeZones` on launch.
  setUpAll(tz_data.initializeTimeZones);

  group('the stored form', () {
    test('is a DTSTART line with an IANA zone id, and an RRULE line', () {
      expect(
        weekly().encode(),
        'DTSTART;TZID=Europe/London:20260101T000000\n'
        'RRULE:FREQ=WEEKLY;BYDAY=TU',
      );
    });

    test('leaves INTERVAL out when it is 1', () {
      expect(weekly().encode(), isNot(contains('INTERVAL')));
      expect(weekly(interval: 2).encode(), contains('INTERVAL=2'));
    });

    test('keeps the anchor time of day, with no trailing Z', () {
      final schedule = weekly(startDate: DateTime(2026, 1, 1, 9, 30));
      expect(schedule.encode(), contains(':20260101T093000'));
      // A trailing Z would make it an instant rather than a wall-clock time,
      // which is the whole distinction ADR 0010 rests on.
      expect(schedule.encode(), isNot(contains('T093000Z')));
    });

    test('round-trips through parse', () {
      final original = weekly(
        weekdays: {DateTime.monday, DateTime.thursday},
        interval: 2,
        startDate: DateTime(2026, 3, 8, 9),
        zoneId: newYork,
      );
      final parsed = FixedSchedule.parse(
        original.encode(),
        defaultAnchor: DateTime(1999),
        defaultZoneId: 'Etc/UTC',
      );

      expect(parsed.anchor, DateTime(2026, 3, 8, 9));
      expect(parsed.zoneId, newYork);
      expect(parsed.encode(), original.encode());
    });

    test('falls back to the defaults for a bare RRULE', () {
      // A rule that reached storage by hand-edit or import rather than through
      // the editor — storage is more expressive than the UI (ADR 0006).
      final parsed = FixedSchedule.parse(
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=1',
        defaultAnchor: DateTime(2026, 5, 4),
        defaultZoneId: london,
      );
      expect(parsed.anchor, DateTime(2026, 5, 4));
      expect(parsed.zoneId, london);
      expect(dates(parsed, DateTime(2026, 5, 4), 2), [
        '2026-06-01',
        '2026-07-01',
      ]);
    });

    test('rejects text with no RRULE line', () {
      expect(
        () => FixedSchedule.parse(
          'DTSTART;TZID=Europe/London:20260101T000000',
          defaultAnchor: DateTime(2026),
          defaultZoneId: london,
        ),
        throwsFormatException,
      );
    });

    test('rejects a DTSTART that is an instant rather than a wall clock', () {
      expect(
        () => FixedSchedule.parse(
          'DTSTART:20260101T000000Z\nRRULE:FREQ=WEEKLY',
          defaultAnchor: DateTime(2026),
          defaultZoneId: london,
        ),
        throwsFormatException,
      );
    });
  });

  group('occurrences — the anchor sets the phase, not the lower bound', () {
    test('a fortnightly rule keeps the anchor weeks whatever is asked for', () {
      final schedule = weekly(
        weekdays: {DateTime.monday, DateTime.thursday},
        interval: 2,
        startDate: DateTime(2026, 1, 5),
      );
      expect(dates(schedule, DateTime(2026, 1, 5), 6), [
        '2026-01-05',
        '2026-01-08',
        '2026-01-19',
        '2026-01-22',
        '2026-02-02',
        '2026-02-05',
      ]);

      // Asking from inside the skipped week must not re-phase the rule onto
      // that week. If this ever returns 2026-01-26, the cursor has been passed
      // as the rule's `start` instead of as its `after` bound.
      expect(dates(schedule, DateTime(2026, 1, 14), 2), [
        '2026-01-19',
        '2026-01-22',
      ]);
    });

    test('the anchor itself counts when the rule lands on it', () {
      expect(
        dates(weekly(startDate: DateTime(2026, 1, 6)), DateTime(2026, 1, 6), 1),
        ['2026-01-06'],
      );
    });

    test('an anchor the rule does not land on is not an occurrence', () {
      // Start on a Thursday, repeat on Tuesdays.
      expect(dates(weekly(), DateTime(2026, 1, 1), 2), [
        '2026-01-06',
        '2026-01-13',
      ]);
    });

    test('weekdays are ignored by the frequencies that cannot use them', () {
      // Day-of-month and nth-weekday are issue #4; a monthly rule here simply
      // repeats on the anchor's day of the month.
      final schedule = FixedSchedule.build(
        frequency: FixedFrequency.monthly,
        weekdays: {DateTime.tuesday},
        startDate: DateTime(2026, 1, 15),
        zoneId: london,
      );
      expect(schedule.encode(), isNot(contains('BYDAY')));
      expect(dates(schedule, DateTime(2026, 1, 15), 3), [
        '2026-01-15',
        '2026-02-15',
        '2026-03-15',
      ]);
    });
  });

  group('month ends', () {
    test('a monthly rule skips months with no such day, it does not clamp', () {
      // RFC 5545 drops a month that has no 31st rather than moving to its last
      // day. This is the opposite of what a *floating* monthly interval does,
      // and the difference is deliberate: the floating side is nem's own
      // calendar arithmetic, this side is the standard's (ADR 0006).
      final schedule = every(FixedFrequency.monthly, DateTime(2026, 1, 31));
      expect(dates(schedule, DateTime(2026, 1, 31), 5), [
        '2026-01-31',
        '2026-03-31',
        '2026-05-31',
        '2026-07-31',
        '2026-08-31',
      ]);
      expect(
        addInterval(DateTime(2026, 1, 31), 1, IntervalUnit.month),
        DateTime(2026, 2, 28),
      );
    });

    test('the 30th skips only February', () {
      expect(
        dates(
          every(FixedFrequency.monthly, DateTime(2026, 1, 30)),
          DateTime(2026, 1, 30),
          4,
        ),
        ['2026-01-30', '2026-03-30', '2026-04-30', '2026-05-30'],
      );
    });

    test('the 28th survives every month', () {
      expect(
        dates(
          every(FixedFrequency.monthly, DateTime(2026, 1, 28)),
          DateTime(2026, 1, 28),
          3,
        ),
        ['2026-01-28', '2026-02-28', '2026-03-28'],
      );
    });

    test('a quarterly rule anchored on the 31st keeps the quarters', () {
      expect(
        dates(
          every(FixedFrequency.monthly, DateTime(2026, 1, 31), interval: 3),
          DateTime(2026, 1, 31),
          4,
        ),
        // Only April is dropped: it is the one quarter month with no 31st.
        ['2026-01-31', '2026-07-31', '2026-10-31', '2027-01-31'],
      );
    });
  });

  group('leap years', () {
    test('a yearly rule on 29 February only fires in leap years', () {
      expect(
        dates(
          every(FixedFrequency.yearly, DateTime(2024, 2, 29)),
          DateTime(2024, 2, 29),
          3,
        ),
        ['2024-02-29', '2028-02-29', '2032-02-29'],
      );
    });

    test('a monthly rule on the 29th includes February in a leap year', () {
      expect(
        dates(
          every(FixedFrequency.monthly, DateTime(2024, 1, 29)),
          DateTime(2024, 1, 29),
          3,
        ),
        ['2024-01-29', '2024-02-29', '2024-03-29'],
      );
    });

    test('and skips it in a common year', () {
      expect(
        dates(
          every(FixedFrequency.monthly, DateTime(2026, 1, 29)),
          DateTime(2026, 1, 29),
          3,
        ),
        ['2026-01-29', '2026-03-29', '2026-04-29'],
      );
    });

    test('2100 is not a leap year', () {
      expect(
        dates(
          every(FixedFrequency.yearly, DateTime(2096, 2, 29)),
          DateTime(2096, 2, 29),
          3,
        ),
        ['2096-02-29', '2104-02-29', '2108-02-29'],
      );
    });
  });

  group('daylight saving (ADR 0010)', () {
    test('each occurrence keeps its wall-clock time across spring forward', () {
      // Sundays at 09:00 in New York, over the 8 March 2026 transition.
      final schedule = every(
        FixedFrequency.weekly,
        DateTime(2026, 3, 1, 9),
        zoneId: newYork,
      );
      final occurrences = schedule
          .occurrencesFrom(DateTime(2026, 3, 1))
          .take(3)
          .toList();

      expect(occurrences.map(date), ['2026-03-01', '2026-03-08', '2026-03-15']);
      for (final occurrence in occurrences) {
        expect(occurrence.hour, 9);
        expect(occurrence.minute, 0);
      }

      // The instants are 167 hours apart, not 168: the wall clock is what is
      // held fixed, so the elapsed time is what gives. Resolving once and
      // adding seven days would have produced 10:00 on the far side.
      expect(
        occurrences[1].difference(occurrences[0]),
        const Duration(hours: 167),
      );
      expect(occurrences[0].timeZoneOffset, const Duration(hours: -5));
      expect(occurrences[1].timeZoneOffset, const Duration(hours: -4));
    });

    test('and across a 30-minute transition', () {
      // Lord Howe Island shifts by half an hour, on 5 April 2026.
      final schedule = every(
        FixedFrequency.weekly,
        DateTime(2026, 3, 29, 9),
        zoneId: 'Australia/Lord_Howe',
      );
      final occurrences = schedule
          .occurrencesFrom(DateTime(2026, 3, 29))
          .take(2)
          .toList();

      expect(occurrences.every((o) => o.hour == 9), isTrue);
      expect(
        occurrences[1].difference(occurrences[0]),
        const Duration(hours: 168, minutes: 30),
      );
    });

    test('a wall-clock time that does not exist resolves forward', () {
      // 02:30 on 8 March 2026 never happens in New York. ADR 0010 records that
      // this resolves silently; this test is what makes "silently" visible.
      final schedule = every(
        FixedFrequency.daily,
        DateTime(2026, 3, 7, 2, 30),
        zoneId: newYork,
      );
      final occurrences = schedule
          .occurrencesFrom(DateTime(2026, 3, 7))
          .take(3)
          .toList();

      expect(occurrences.map(date), ['2026-03-07', '2026-03-08', '2026-03-09']);
      expect(occurrences[1].hour, 3);
      expect(occurrences[1].minute, 30);
    });

    test('lateness counts whole days across a transition', () {
      // The standing landmine: differencing two local times over a
      // spring-forward truncates the day count down by one.
      final schedule = every(
        FixedFrequency.weekly,
        DateTime(2026, 3, 1, 9),
        zoneId: newYork,
      );
      final due = fixedDueDate(schedule)!;
      expect(daysLate(due, DateTime(2026, 3, 15, 9)), 14);
      expect(overdueLabel(due, DateTime(2026, 3, 15, 9)), '14 days late');
    });

    test('a completion is dated by the schedule\'s zone, not the device\'s', () {
      // Kiritimati is UTC+14, so 11:00Z on Monday is already Tuesday there —
      // and the Tuesday occurrence counts as completed.
      final schedule = weekly(
        startDate: DateTime(2026, 1, 6),
        zoneId: 'Pacific/Kiritimati',
      );
      expect(date(schedule.dayOf(DateTime.utc(2026, 1, 5, 11))), '2026-01-06');
      expect(
        date(
          fixedDueDate(
            schedule,
            lastCompletedAt: DateTime.utc(2026, 1, 5, 11),
          )!,
        ),
        '2026-01-13',
      );
      // An hour earlier it is still Monday there, so the Tuesday is still due.
      expect(
        date(
          fixedDueDate(
            schedule,
            lastCompletedAt: DateTime.utc(2026, 1, 4, 11),
          )!,
        ),
        '2026-01-06',
      );
    });
  });

  group('fixedDueDate — never completed', () {
    test('is the first occurrence the rule produces', () {
      expect(date(fixedDueDate(weekly())!), '2026-01-06');
    });

    test('which is in the past when the start date is', () {
      final schedule = weekly(startDate: DateTime(2020, 1, 1));
      final due = fixedDueDate(schedule)!;
      expect(date(due), '2020-01-07');
      expect(dueStatusFor(due, DateTime(2026, 1, 22)), DueStatus.overdue);
    });

    test('is null once a bounded rule has run out', () {
      // COUNT cannot be authored by the minimal editor, but it can reach
      // storage (ADR 0006), so the engine has to survive it.
      final schedule = FixedSchedule.parse(
        'DTSTART;TZID=Europe/London:20260106T000000\n'
        'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=2',
        defaultAnchor: DateTime(2026, 1, 6),
        defaultZoneId: london,
      );
      expect(date(fixedDueDate(schedule)!), '2026-01-06');
      expect(
        fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2026, 1, 13)),
        isNull,
      );
    });
  });

  group('fixedDueDate — after a completion (ADR 0007)', () {
    final schedule = weekly(startDate: DateTime(2026, 1, 6));

    test('advances to the occurrence after the one just completed', () {
      expect(
        date(
          fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2026, 1, 6, 8))!,
        ),
        '2026-01-13',
      );
    });

    test('completing later the same day still completes that occurrence', () {
      expect(
        date(
          fixedDueDate(
            schedule,
            lastCompletedAt: DateTime.utc(2026, 1, 6, 23, 59),
          )!,
        ),
        '2026-01-13',
      );
    });

    test('completing the day before does not', () {
      expect(
        date(
          fixedDueDate(
            schedule,
            lastCompletedAt: DateTime.utc(2026, 1, 5, 23, 59),
          )!,
        ),
        '2026-01-06',
      );
    });

    test(
      'a completion before the schedule starts leaves the first in place',
      () {
        expect(
          date(
            fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2025, 12, 1))!,
          ),
          '2026-01-06',
        );
      },
    );

    test('doing the work late does not push the calendar out', () {
      // Unlike a floating schedule, where a late completion moves the next due
      // date out by a whole interval.
      expect(
        date(
          fixedDueDate(schedule, lastCompletedAt: DateTime.utc(2026, 1, 9))!,
        ),
        '2026-01-13',
      );
    });
  });

  group('missed occurrences collapse (ADR 0007)', () {
    // Tuesdays from 6 January 2026. By Thursday 22 January the 6th, 13th and
    // 20th have all passed with nothing done.
    final schedule = weekly(startDate: DateTime(2026, 1, 6));
    final now = DateTime(2026, 1, 22, 10);

    test(
      'the due date pins to the FIRST missed occurrence, not the next one',
      () {
        final due = fixedDueDate(schedule)!;
        expect(date(due), '2026-01-06');
        // Not the next future occurrence, which would have been the 27th.
        expect(date(due), isNot('2026-01-27'));
      },
    );

    test('three misses are one row, not three', () {
      final sections = groupByDueStatus([fixedTask(schedule)], now);
      expect(sections, hasLength(1));
      expect(sections.single.status, DueStatus.overdue);
      expect(sections.single.tasks, hasLength(1));
    });

    test('and the row says how late it is, counted from the first miss', () {
      final due = fixedDueDate(schedule)!;
      expect(daysLate(due, now), 16);
      expect(overdueLabel(due, now), '16 days late');
    });

    test('completing skips every intervening miss in one go', () {
      final after = fixedTask(
        schedule,
        lastCompletedAt: DateTime.utc(2026, 1, 22, 10),
      );
      // The first occurrence after today — the 13th and the 20th are gone for
      // good, recoverable only from the gap in the completion log.
      expect(date(after.dueDate!), '2026-01-27');
      expect(after.dueStatusAt(now), DueStatus.upcoming);
      expect(groupByDueStatus([after], now).single.status, DueStatus.upcoming);
    });

    test('it stays one row however many are missed', () {
      final stale = weekly(startDate: DateTime(2025, 1, 7));
      final task = fixedTask(stale);
      expect(date(task.dueDate!), '2025-01-07');
      expect(daysLate(task.dueDate!, now), 380);
      expect(groupByDueStatus([task], now).single.tasks, hasLength(1));
    });
  });

  group('label', () {
    test('names the weekdays of a weekly rule', () {
      expect(weekly().label, 'Every Tuesday');
      expect(
        weekly(weekdays: {DateTime.thursday, DateTime.monday}).label,
        'Every Monday, Thursday',
      );
      expect(
        weekly(weekdays: {DateTime.monday}, interval: 2).label,
        'Every 2 weeks on Monday',
      );
    });

    test('falls back to the frequency when no weekday is chosen', () {
      expect(weekly(weekdays: const {}).label, 'Every week');
    });

    test('reads the other frequencies as intervals', () {
      expect(every(FixedFrequency.daily, DateTime(2026)).label, 'Every day');
      expect(
        every(FixedFrequency.monthly, DateTime(2026), interval: 3).label,
        'Every 3 months',
      );
      expect(every(FixedFrequency.yearly, DateTime(2026)).label, 'Every year');
    });

    test('shows a rule the editor cannot author as itself', () {
      // Rather than describing it wrongly. Presenting it properly is issue #4.
      final schedule = FixedSchedule.parse(
        'RRULE:FREQ=MONTHLY;BYDAY=1MO',
        defaultAnchor: DateTime(2026),
        defaultZoneId: london,
      );
      expect(schedule.label, 'RRULE:FREQ=MONTHLY;BYDAY=1MO');
    });
  });

  group('the two modes stay apart (ADR 0005)', () {
    test('a fixed task derives its due date from the calendar', () {
      final task = fixedTask(weekly(startDate: DateTime(2026, 1, 6)));
      expect(task.floatingSchedule, isNull);
      expect(task.fixedSchedule, isNotNull);
      expect(date(task.dueDate!), '2026-01-06');
      expect(task.scheduleLabel, 'Every Tuesday');
    });

    test('a fixed task with an unreadable rule simply has no due date', () {
      final task = Task(
        id: 'task-2',
        title: 'Something imported',
        scheduleMode: ScheduleMode.fixed,
        rrule: 'RRULE:FREQ=NONSENSE',
        startDate: DateTime(2026),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(task.dueDate, isNull);
      expect(groupByDueStatus([task], DateTime(2026, 6, 1)), isEmpty);
    });
  });

  test('an occurrence is a real instant in the schedule\'s zone', () {
    final occurrence = weekly(
      startDate: DateTime(2026, 7, 7, 9),
    ).occurrencesFrom(DateTime(2026, 7, 7)).first;
    expect(occurrence, isA<tz.TZDateTime>());
    expect(occurrence.location.name, london);
    // British Summer Time in July.
    expect(occurrence.toUtc(), DateTime.utc(2026, 7, 7, 8));
  });
}
