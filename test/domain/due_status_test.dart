import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/due_status.dart';

void main() {
  final now = DateTime(2026, 6, 15, 14, 0);

  group('dueStatusFor', () {
    test('a due date in the past is overdue', () {
      expect(dueStatusFor(DateTime(2026, 6, 14), now), DueStatus.overdue);
    });

    test('a due date today is due today, not overdue', () {
      expect(dueStatusFor(DateTime(2026, 6, 15, 9), now), DueStatus.dueToday);
    });

    test('a due date later today is still due today', () {
      expect(dueStatusFor(DateTime(2026, 6, 15, 23), now), DueStatus.dueToday);
    });

    test('a due date in the future is upcoming', () {
      expect(dueStatusFor(DateTime(2026, 6, 16), now), DueStatus.upcoming);
    });
  });

  group('daysLate', () {
    test('counts whole calendar days, not elapsed hours', () {
      // Due at 09:00 yesterday, now 14:00 today — 29 hours, but one day late.
      expect(daysLate(DateTime(2026, 6, 14, 9), now), 1);
    });

    test('a task due several days ago', () {
      expect(daysLate(DateTime(2026, 6, 3), now), 12);
    });

    test('is zero on the due day', () {
      expect(daysLate(DateTime(2026, 6, 15, 23, 59), now), 0);
    });

    test('is negative for an upcoming task', () {
      expect(daysLate(DateTime(2026, 6, 20), now), -5);
    });
  });

  group('overdueLabel', () {
    test('is null when the task is not overdue', () {
      expect(overdueLabel(DateTime(2026, 6, 15), now), isNull);
      expect(overdueLabel(DateTime(2026, 7, 1), now), isNull);
    });

    test('reads singular at one day', () {
      expect(overdueLabel(DateTime(2026, 6, 14), now), '1 day late');
    });

    test('reads plural beyond one day', () {
      expect(overdueLabel(DateTime(2026, 6, 5), now), '10 days late');
    });
  });

  test('group headings are Overdue, Today and Soon', () {
    expect(DueStatus.overdue.groupHeading, 'Overdue');
    expect(DueStatus.dueToday.groupHeading, 'Today');
    expect(DueStatus.upcoming.groupHeading, 'Soon');
  });
}
