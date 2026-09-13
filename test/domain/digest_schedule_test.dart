import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/digest.dart';
import 'package:nem/src/domain/digest_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/task.dart';

/// A floating task contrived to be due exactly on [due].
///
/// A one-day interval from the day before gives a due date of [due] without
/// the test having to know anything about the due date engine.
Task taskDue(DateTime due, {String title = 'Task', bool isArchived = false}) {
  final start = addInterval(due, -1, IntervalUnit.day);
  return Task(
    id: title,
    title: title,
    scheduleMode: ScheduleMode.floating,
    floatingSchedule: FloatingSchedule(
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: start,
    ),
    startDate: start,
    isArchived: isArchived,
    createdAt: start,
    updatedAt: start,
  );
}

void main() {
  const enabled = DigestSettings(
    isEnabled: true,
    time: DigestTime(hour: 8, minute: 0),
  );

  DigestPlan plan(
    List<Task> tasks,
    DateTime now, {
    DigestSettings settings = enabled,
    int slots = digestNotificationBudget,
    int horizonDays = digestHorizonDays,
  }) => planDigests(
    settings: settings,
    tasks: tasks,
    now: now,
    slots: slots,
    horizonDays: horizonDays,
  );

  group('the scheduling window', () {
    test('starts today when the digest time is still ahead', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9)),
      ], DateTime(2026, 6, 15, 6));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 15, 8));
    });

    test('starts tomorrow when today is already past the digest time', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9)),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 16, 8));
    });

    test('does not schedule the digest time itself twice over', () {
      // Exactly on the hour counts as gone: scheduling a notification for the
      // instant that is passing is a notification that never arrives.
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9)),
      ], DateTime(2026, 6, 15, 8));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 16, 8));
    });

    test('every entry fires at the digest time', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        settings: const DigestSettings(
          isEnabled: true,
          time: DigestTime(hour: 19, minute: 45),
        ),
      );
      expect(result.entries, isNotEmpty);
      for (final entry in result.entries) {
        expect(entry.fireAt.hour, 19);
        expect(entry.fireAt.minute, 45);
      }
    });

    test('runs forward one calendar day at a time', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        slots: 3,
      );
      expect(result.entries.map((e) => e.fireAt), [
        DateTime(2026, 6, 16, 8),
        DateTime(2026, 6, 17, 8),
        DateTime(2026, 6, 18, 8),
      ]);
    });

    test('skips days with nothing due rather than announcing a zero', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 20))],
        DateTime(2026, 6, 15, 10),
        slots: 2,
      );
      // Nothing between the 16th and the 19th, so the window opens on the day
      // the task falls due.
      expect(result.entries.map((e) => e.fireAt), [
        DateTime(2026, 6, 20, 8),
        DateTime(2026, 6, 21, 8),
      ]);
    });

    test('is empty when nothing is due anywhere in the horizon', () {
      final result = plan([
        taskDue(DateTime(2026, 9, 1)),
      ], DateTime(2026, 6, 15, 10));
      expect(result.isEmpty, isTrue);
      expect(result.daysWithWork, 0);
    });

    test('is empty when the digest is switched off', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        settings: const DigestSettings(
          isEnabled: false,
          time: DigestTime(hour: 8, minute: 0),
        ),
      );
      expect(result.isEmpty, isTrue);
    });

    test('ignores archived tasks', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 10), title: 'Archived', isArchived: true),
      ], DateTime(2026, 6, 15, 10));
      expect(result.isEmpty, isTrue);
    });
  });

  group('what each digest says', () {
    final tasks = [
      taskDue(DateTime(2026, 6, 10), title: 'Long overdue'),
      taskDue(DateTime(2026, 6, 16), title: 'Due on the 16th'),
      taskDue(DateTime(2026, 6, 17), title: 'Due on the 17th'),
    ];

    test('counts what is due that day and what is already overdue', () {
      final result = plan(tasks, DateTime(2026, 6, 15, 10), slots: 2);

      expect(result.entries[0].fireAt, DateTime(2026, 6, 16, 8));
      expect(
        result.entries[0].counts,
        const DigestCounts(dueToday: 1, overdue: 1),
      );
      expect(result.entries[0].body, '1 task due today, 1 overdue');

      expect(result.entries[1].fireAt, DateTime(2026, 6, 17, 8));
      expect(
        result.entries[1].counts,
        const DigestCounts(dueToday: 1, overdue: 2),
      );
    });

    test('a day with only leftovers reads as overdue', () {
      final result = plan(tasks, DateTime(2026, 6, 15, 10), slots: 3);
      expect(result.entries[2].counts.dueToday, 0);
      expect(result.entries[2].counts.overdue, 3);
      expect(result.entries[2].title, 'Overdue');
    });

    test('counts agree with the due list grouping', () {
      // countFor is the same classification the Overdue/Today/Soon sections
      // use, so the digest can never contradict the screen it opens.
      final counts = countFor(tasks, DateTime(2026, 6, 16, 8));
      expect(counts.dueToday, 1);
      expect(counts.overdue, 1);
      expect(counts.total, 2);
    });
  });

  group('the 64-notification budget', () {
    test('the digest never asks for more than its own budget', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 10)),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.length, digestNotificationBudget);
      expect(digestNotificationBudget, lessThan(iosPendingNotificationLimit));
    });

    test('stops at the slots it is given, and says it was cut short', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        slots: 4,
        horizonDays: 10,
      );
      expect(result.entries.length, 4);
      // The 15th is already past its digest time, so the horizon of ten days
      // yields nine that can still be notified about.
      expect(result.daysWithWork, 9);
      expect(result.isTruncatedByBudget, isTrue);
      expect(result.coversUntil, DateTime(2026, 6, 19, 8));
    });

    test('is not cut short when the horizon fits', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 16))],
        DateTime(2026, 6, 15, 10),
        slots: 5,
        horizonDays: 3,
      );
      expect(result.entries.length, 2);
      expect(result.isTruncatedByBudget, isFalse);
    });

    test('schedules nothing at all when there are no slots left', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        slots: 0,
      );
      expect(result.isEmpty, isTrue);
    });

    test('ids come from the digest range and do not repeat', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 10)),
      ], DateTime(2026, 6, 15, 10));
      final ids = result.entries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every(isDigestNotificationId), isTrue);
      expect(ids.first, digestNotificationIdBase);
    });
  });

  group('digestSlots', () {
    test('is the full budget when nothing else is pending', () {
      expect(digestSlots(pendingIds: const []), digestNotificationBudget);
    });

    test('does not count the digest\'s own pending notifications', () {
      // They are about to be replaced, so they are not competition.
      final own = [
        for (var i = 0; i < digestNotificationBudget; i++)
          digestNotificationIdBase + i,
      ];
      expect(digestSlots(pendingIds: own), digestNotificationBudget);
    });

    test('yields ground to other pending notifications near the cap', () {
      // Per-task reminders (issue #16) will share this budget.
      final reminders = List.generate(55, (i) => i);
      expect(digestSlots(pendingIds: reminders), 9);
    });

    test('never goes negative once the cap is already reached', () {
      final reminders = List.generate(80, (i) => i);
      expect(digestSlots(pendingIds: reminders), 0);
    });

    test('the plan plus everything else stays inside the iOS cap', () {
      final reminders = List.generate(58, (i) => i);
      final slots = digestSlots(pendingIds: reminders);
      final result = plan(
        [taskDue(DateTime(2026, 6, 10))],
        DateTime(2026, 6, 15, 10),
        slots: slots,
      );
      expect(
        reminders.length + result.entries.length,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
    });
  });

  // These only bite when the test process runs in a zone that observes DST —
  // CI runs the suite a second time under TZ=America/New_York for exactly
  // this reason.
  group('daylight saving transitions', () {
    test('keeps the wall-clock time across a spring-forward', () {
      // US spring-forward 2026: Sunday 8 March, 02:00 -> 03:00.
      final result = plan(
        [taskDue(DateTime(2026, 3, 1))],
        DateTime(2026, 3, 6, 10),
        slots: 5,
      );
      expect(result.entries.map((e) => e.fireAt), [
        DateTime(2026, 3, 7, 8),
        DateTime(2026, 3, 8, 8),
        DateTime(2026, 3, 9, 8),
        DateTime(2026, 3, 10, 8),
        DateTime(2026, 3, 11, 8),
      ]);
    });

    test('keeps the wall-clock time across an autumn fall-back', () {
      // US fall-back 2026: Sunday 1 November, 02:00 -> 01:00.
      final result = plan(
        [taskDue(DateTime(2026, 10, 25))],
        DateTime(2026, 10, 30, 10),
        slots: 4,
      );
      for (final entry in result.entries) {
        expect(entry.fireAt.hour, 8, reason: '${entry.fireAt}');
      }
      expect(result.entries.last.fireAt.day, 3);
    });

    test('does not lose or double a day across a transition', () {
      final result = plan(
        [taskDue(DateTime(2026, 3, 1))],
        DateTime(2026, 3, 6, 10),
        slots: 5,
      );
      final days = result.entries.map((e) => e.fireAt.day).toList();
      expect(days, [7, 8, 9, 10, 11]);
    });

    test('lateness reported on the far side of a transition is right', () {
      // A task due 7 March, counted on the 9th — the day in between was 23
      // hours long, and the count is still two whole days.
      final counts = countFor([
        taskDue(DateTime(2026, 3, 7, 9)),
      ], DateTime(2026, 3, 9, 8));
      expect(counts.overdue, 1);
      expect(counts.dueToday, 0);
    });
  });
}
