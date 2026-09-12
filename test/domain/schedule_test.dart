import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';

FloatingSchedule scheduleOf(int n, IntervalUnit unit, {DateTime? startDate}) =>
    FloatingSchedule(
      intervalN: n,
      intervalUnit: unit,
      startDate: startDate ?? DateTime(2026, 1, 1),
    );

void main() {
  group('floatingDueDate — never completed', () {
    test('falls back to the start date plus the interval', () {
      final schedule = scheduleOf(
        3,
        IntervalUnit.day,
        startDate: DateTime(2026, 3, 1),
      );
      expect(floatingDueDate(schedule), DateTime(2026, 3, 4));
    });

    test('omitting lastCompletedAt matches passing null explicitly', () {
      final schedule = scheduleOf(2, IntervalUnit.week);
      expect(
        floatingDueDate(schedule),
        floatingDueDate(schedule, lastCompletedAt: null),
      );
    });

    test('preserves the start date time of day', () {
      final schedule = scheduleOf(
        1,
        IntervalUnit.day,
        startDate: DateTime(2026, 3, 1, 9, 30),
      );
      expect(floatingDueDate(schedule), DateTime(2026, 3, 2, 9, 30));
    });
  });

  group('floatingDueDate — measured from the last completion', () {
    test('uses the completion, not the start date', () {
      final schedule = scheduleOf(
        7,
        IntervalUnit.day,
        startDate: DateTime(2026, 1, 1),
      );
      expect(
        floatingDueDate(schedule, lastCompletedAt: DateTime(2026, 5, 10)),
        DateTime(2026, 5, 17),
      );
    });

    test('a late completion pushes the due date out, it does not catch up', () {
      // Start 1 Jan, every 3 days, but the work was actually done on 20 Jan.
      final schedule = scheduleOf(
        3,
        IntervalUnit.day,
        startDate: DateTime(2026, 1, 1),
      );
      expect(
        floatingDueDate(schedule, lastCompletedAt: DateTime(2026, 1, 20)),
        DateTime(2026, 1, 23),
      );
    });
  });

  group('floatingDueDate — each interval unit', () {
    final start = DateTime(2026, 1, 15);

    test('days', () {
      expect(
        floatingDueDate(scheduleOf(5, IntervalUnit.day, startDate: start)),
        DateTime(2026, 1, 20),
      );
    });

    test('weeks', () {
      expect(
        floatingDueDate(scheduleOf(2, IntervalUnit.week, startDate: start)),
        DateTime(2026, 1, 29),
      );
    });

    test('months', () {
      expect(
        floatingDueDate(scheduleOf(3, IntervalUnit.month, startDate: start)),
        DateTime(2026, 4, 15),
      );
    });

    test('years', () {
      expect(
        floatingDueDate(scheduleOf(1, IntervalUnit.year, startDate: start)),
        DateTime(2027, 1, 15),
      );
    });
  });

  group('calendar arithmetic edge cases', () {
    test('a day interval rolls over the end of the month', () {
      expect(
        floatingDueDate(
          scheduleOf(5, IntervalUnit.day, startDate: DateTime(2026, 1, 30)),
        ),
        DateTime(2026, 2, 4),
      );
    });

    test('a month interval clamps to the end of a shorter month', () {
      expect(
        floatingDueDate(
          scheduleOf(1, IntervalUnit.month, startDate: DateTime(2026, 1, 31)),
        ),
        DateTime(2026, 2, 28),
      );
    });

    test('a month interval clamps to 29 February in a leap year', () {
      expect(
        floatingDueDate(
          scheduleOf(1, IntervalUnit.month, startDate: DateTime(2028, 1, 31)),
        ),
        DateTime(2028, 2, 29),
      );
    });

    test('a year interval clamps 29 February to 28 February', () {
      expect(
        floatingDueDate(
          scheduleOf(1, IntervalUnit.year, startDate: DateTime(2028, 2, 29)),
        ),
        DateTime(2029, 2, 28),
      );
    });

    test('a month interval crosses the year boundary', () {
      expect(
        floatingDueDate(
          scheduleOf(2, IntervalUnit.month, startDate: DateTime(2026, 11, 30)),
        ),
        DateTime(2027, 1, 30),
      );
    });

    test('12 month intervals equal one year interval', () {
      final start = DateTime(2026, 6, 10);
      expect(
        floatingDueDate(scheduleOf(12, IntervalUnit.month, startDate: start)),
        floatingDueDate(scheduleOf(1, IntervalUnit.year, startDate: start)),
      );
    });

    test('a UTC start date yields a UTC due date', () {
      final due = floatingDueDate(
        scheduleOf(1, IntervalUnit.day, startDate: DateTime.utc(2026, 1, 1)),
      );
      expect(due.isUtc, isTrue);
      expect(due, DateTime.utc(2026, 1, 2));
    });

    test('a week interval keeps the weekday', () {
      final start = DateTime(2026, 3, 4); // Wednesday
      final due = floatingDueDate(
        scheduleOf(1, IntervalUnit.week, startDate: start),
      );
      expect(due.weekday, start.weekday);
    });
  });

  test('an interval below 1 is rejected', () {
    expect(
      () => FloatingSchedule(
        intervalN: 0,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 1, 1),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('label reads in the domain vocabulary', () {
    expect(scheduleOf(1, IntervalUnit.day).label, 'Every 1 day');
    expect(scheduleOf(3, IntervalUnit.day).label, 'Every 3 days');
    expect(scheduleOf(2, IntervalUnit.month).label, 'Every 2 months');
  });
}
