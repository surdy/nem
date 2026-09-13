import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/due_status.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/snooze.dart';

void main() {
  group('snoozedUntilFrom', () {
    test('measures from now when the task is already overdue', () {
      // Ten days late. Three days from the due date would be a week ago, so
      // the task would come straight back overdue.
      expect(
        snoozedUntilFrom(
          now: DateTime(2026, 6, 15, 10),
          dueDate: DateTime(2026, 6, 5, 9),
          n: 3,
          unit: IntervalUnit.day,
        ),
        DateTime(2026, 6, 18, 10),
      );
    });

    test('measures from the due date when that is still ahead', () {
      // Otherwise snoozing a task due next month would pull it forward to
      // three days from today, which is the opposite of pushing it out.
      expect(
        snoozedUntilFrom(
          now: DateTime(2026, 6, 15, 10),
          dueDate: DateTime(2026, 7, 1, 9),
          n: 3,
          unit: IntervalUnit.day,
        ),
        DateTime(2026, 7, 4, 9),
      );
    });

    test('falls back to now when there is no due date at all', () {
      expect(
        snoozedUntilFrom(
          now: DateTime(2026, 6, 15, 10),
          n: 1,
          unit: IntervalUnit.week,
        ),
        DateTime(2026, 6, 22, 10),
      );
    });

    test('three days across the American spring-forward is three calendar '
        'days, at the same wall-clock time', () {
      // 8 March 2026, 02:00 in America/New_York. A `Duration(days: 3)` would
      // land at 08:00 on the 9th, an hour early — and for a task due near
      // midnight, a whole calendar day early.
      final snoozed = snoozedUntilFrom(
        now: DateTime(2026, 3, 6, 9),
        n: 3,
        unit: IntervalUnit.day,
      );
      expect(snoozed, DateTime(2026, 3, 9, 9));
      expect(calendarDaysBetween(DateTime(2026, 3, 6, 9), snoozed), 3);
    });

    test('three days across the European spring-forward is three calendar '
        'days, at the same wall-clock time', () {
      // 29 March 2026, 01:00 in Europe/London — so this suite catches the same
      // bug whichever side of the Atlantic it is run on.
      final snoozed = snoozedUntilFrom(
        now: DateTime(2026, 3, 27, 9),
        n: 3,
        unit: IntervalUnit.day,
      );
      expect(snoozed, DateTime(2026, 3, 30, 9));
      expect(calendarDaysBetween(DateTime(2026, 3, 27, 9), snoozed), 3);
    });

    test('a week is seven calendar days, not 168 hours', () {
      final snoozed = snoozedUntilFrom(
        now: DateTime(2026, 3, 6, 9),
        n: 1,
        unit: IntervalUnit.week,
      );
      expect(snoozed, DateTime(2026, 3, 13, 9));
    });
  });

  group('effectiveDueDate', () {
    final scheduled = DateTime(2026, 6, 5, 9);

    test('is the schedule when there is no snooze', () {
      expect(effectiveDueDate(scheduled: scheduled), scheduled);
    });

    test('is the snooze when it pushes the schedule out', () {
      expect(
        effectiveDueDate(
          scheduled: scheduled,
          snoozedUntil: DateTime(2026, 6, 18, 10),
          snoozedAt: DateTime(2026, 6, 15, 10),
        ),
        DateTime(2026, 6, 18, 10),
      );
    });

    test('never pulls a due date backwards', () {
      // The schedule has moved past the snooze — a completion, or a fixed
      // rule's next occurrence. The snooze goes quietly inert rather than
      // dragging the task back onto the list.
      expect(
        effectiveDueDate(
          scheduled: DateTime(2026, 7, 20, 9),
          snoozedUntil: DateTime(2026, 6, 18, 10),
          snoozedAt: DateTime(2026, 6, 15, 10),
        ),
        DateTime(2026, 7, 20, 9),
      );
    });

    test('a completion after the snooze spends it', () {
      // The work was done, so the schedule takes over again — even though the
      // snooze it was given reaches further out.
      expect(
        effectiveDueDate(
          scheduled: DateTime(2026, 6, 20, 9),
          snoozedUntil: DateTime(2026, 12, 1, 10),
          snoozedAt: DateTime(2026, 6, 15, 10),
          lastCompletedAt: DateTime(2026, 6, 16, 8),
        ),
        DateTime(2026, 6, 20, 9),
      );
    });

    test('a completion before the snooze leaves it standing', () {
      // Back-dating a completion does not un-say the snooze: the snooze is
      // still the most recent thing said about when to show this task.
      expect(
        effectiveDueDate(
          scheduled: DateTime(2026, 6, 12, 9),
          snoozedUntil: DateTime(2026, 6, 18, 10),
          snoozedAt: DateTime(2026, 6, 15, 10),
          lastCompletedAt: DateTime(2026, 6, 10, 8),
        ),
        DateTime(2026, 6, 18, 10),
      );
    });

    test(
      'a snooze on a task whose rule cannot be read is still a due date',
      () {
        expect(
          effectiveDueDate(
            scheduled: null,
            snoozedUntil: DateTime(2026, 6, 18, 10),
            snoozedAt: DateTime(2026, 6, 15, 10),
          ),
          DateTime(2026, 6, 18, 10),
        );
      },
    );
  });

  group('snoozeHoldsAt', () {
    final scheduled = DateTime(2026, 6, 5, 9);
    final snoozedAt = DateTime(2026, 6, 15, 10);
    final snoozedUntil = DateTime(2026, 6, 18, 10);

    bool holds(DateTime now, {DateTime? lastCompletedAt}) => snoozeHoldsAt(
      now: now,
      scheduled: scheduled,
      snoozedUntil: snoozedUntil,
      snoozedAt: snoozedAt,
      lastCompletedAt: lastCompletedAt,
    );

    test('holds while the snooze is still ahead', () {
      expect(holds(DateTime(2026, 6, 15, 10)), isTrue);
      expect(holds(DateTime(2026, 6, 17, 23, 59)), isTrue);
    });

    test('stops on the day the snooze comes due', () {
      // The task is due today, not still snoozed — and by calendar day, so it
      // is not "still snoozed" for the hours before 10:00.
      expect(holds(DateTime(2026, 6, 18, 8)), isFalse);
      expect(holds(DateTime(2026, 6, 19, 8)), isFalse);
    });

    test('stops once a completion has spent it', () {
      expect(
        holds(DateTime(2026, 6, 16, 9), lastCompletedAt: DateTime(2026, 6, 16)),
        isFalse,
      );
    });

    test('is false with nothing stored', () {
      expect(
        snoozeHoldsAt(now: DateTime(2026, 6, 15), scheduled: scheduled),
        isFalse,
      );
    });
  });

  group('snoozeOptions', () {
    test('are labelled by the amount, never "tomorrow"', () {
      expect(snoozeOptions.map((option) => option.label), [
        '1 day',
        '3 days',
        '1 week',
      ]);
    });
  });
}
