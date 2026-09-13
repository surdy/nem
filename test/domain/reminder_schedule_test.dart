import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/digest_schedule.dart';
import 'package:nem/src/domain/due_status.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/reminder.dart';
import 'package:nem/src/domain/reminder_schedule.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/task.dart';

/// A floating task contrived to be due exactly on [due], reminding at [at].
///
/// A one-day interval from the day before gives a due date of [due] without
/// the test having to know anything about the due date engine.
Task taskDue(
  DateTime due, {
  ReminderTime? at,
  String title = 'Task',
  bool isArchived = false,
}) {
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
    reminderTime: at,
    isArchived: isArchived,
    createdAt: start,
    updatedAt: start,
  );
}

void main() {
  const sevenPm = ReminderTime(hour: 19);

  ReminderPlan plan(
    List<Task> tasks,
    DateTime now, {
    int slots = reminderNotificationBudget,
    int horizonDays = reminderHorizonDays,
  }) => planReminders(
    tasks: tasks,
    now: now,
    slots: slots,
    horizonDays: horizonDays,
  );

  group('opting in', () {
    test('a task with no reminder time is never reminded about', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9)),
      ], DateTime(2026, 6, 15, 10));
      expect(result.isEmpty, isTrue);
    });

    test('a task with a reminder time is', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 15, 9), at: sevenPm)],
        DateTime(2026, 6, 15, 10),
        horizonDays: 1,
      );
      expect(result.entries.single.fireAt, DateTime(2026, 6, 15, 19));
    });

    test('an archived task is not, whatever its reminder says', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm, isArchived: true),
      ], DateTime(2026, 6, 15, 10));
      expect(result.isEmpty, isTrue);
    });

    test('a task with no due date is not', () {
      // A fixed task whose stored rule this build cannot parse has no due
      // date, and a reminder that cannot say whether the work is due has
      // nothing to say at all.
      final unreadable = Task(
        id: 'broken',
        title: 'Imported rule',
        scheduleMode: ScheduleMode.fixed,
        rrule: 'RRULE:FREQ=NONSENSE',
        startDate: DateTime(2026, 6, 1),
        reminderTime: sevenPm,
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 1),
      );
      expect(plan([unreadable], DateTime(2026, 6, 15, 10)).isEmpty, isTrue);
    });
  });

  group('only when the task is due or overdue', () {
    test('nothing fires before the due date', () {
      // The criterion with teeth. A task due in three days gets no reminder
      // tonight, tomorrow night, or the night after.
      final result = plan([
        taskDue(DateTime(2026, 6, 18, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));

      expect(result.entries.first.fireAt, DateTime(2026, 6, 18, 19));
      expect(
        result.entries.every((e) => !e.fireAt.isBefore(DateTime(2026, 6, 18))),
        isTrue,
      );
    });

    test('the first one is on the due day itself', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 20, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 20, 19));
    });

    test('a task due earlier in the day is still due at reminder time', () {
      // Whole calendar days, exactly as the due list groups: due at 09:00 is
      // "due today" to a reminder at 19:00, not already overdue.
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.first.status, DueStatus.dueToday);
      expect(result.entries.first.body, 'Due today');
    });

    test('it keeps firing while the task stays overdue', () {
      // Overdue is a state, not an event: the work is still not done tomorrow
      // night either, so the reminder is still true.
      final result = plan([
        taskDue(DateTime(2026, 6, 10, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));

      expect(result.entries.length, greaterThan(1));
      expect(result.entries.map((e) => e.fireAt).take(3), [
        DateTime(2026, 6, 15, 19),
        DateTime(2026, 6, 16, 19),
        DateTime(2026, 6, 17, 19),
      ]);
      expect(
        result.entries.every((e) => e.status == DueStatus.overdue),
        isTrue,
      );
    });

    test("nothing is scheduled after the horizon's end", () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 15, 9), at: sevenPm)],
        DateTime(2026, 6, 15, 10),
        horizonDays: 5,
      );
      expect(result.entries.length, 5);
      expect(result.entries.last.fireAt, DateTime(2026, 6, 19, 19));
    });
  });

  group('the reminder time itself', () {
    test("today's reminder time having passed moves the first to tomorrow", () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 20));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 16, 19));
    });

    test('the reminder time exactly now counts as gone', () {
      // Scheduling a notification for the instant that is passing is a
      // notification that never arrives.
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 19));
      expect(result.entries.first.fireAt, DateTime(2026, 6, 16, 19));
    });

    test('each task fires at its own time, not a shared one', () {
      final result = plan([
        taskDue(
          DateTime(2026, 6, 15, 9),
          at: const ReminderTime(hour: 7, minute: 30),
          title: 'Bins',
        ),
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm, title: 'Water'),
      ], DateTime(2026, 6, 15, 6));

      expect(result.entries.first.taskTitle, 'Bins');
      expect(result.entries.first.fireAt, DateTime(2026, 6, 15, 7, 30));
      expect(
        result.entries.firstWhere((e) => e.taskTitle == 'Water').fireAt,
        DateTime(2026, 6, 15, 19),
      );
    });
  });

  group('what a reminder says', () {
    test('the title is the task, because that is what a tap opens', () {
      final result = plan([
        taskDue(
          DateTime(2026, 6, 15, 9),
          at: sevenPm,
          title: 'Put the bins out',
        ),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.first.title, 'Put the bins out');
      expect(result.entries.first.taskId, 'Put the bins out');
    });

    test('the body counts lateness the same way the due list does', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 12, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));

      expect(result.entries[0].body, '3 days late');
      expect(result.entries[1].body, '4 days late');
    });

    test('one day late is singular', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 14, 9), at: sevenPm),
      ], DateTime(2026, 6, 15, 10));
      expect(result.entries.first.body, '1 day late');
    });
  });

  group('the 64-notification budget', () {
    test('reminders never ask for more than their own budget', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 1, 9), at: sevenPm, title: 'A'),
        taskDue(DateTime(2026, 6, 1, 9), at: sevenPm, title: 'B'),
        taskDue(DateTime(2026, 6, 1, 9), at: sevenPm, title: 'C'),
      ], DateTime(2026, 6, 15, 10));

      expect(result.entries.length, reminderNotificationBudget);
      expect(result.isTruncatedByBudget, isTrue);
    });

    test('and never more than the slots they are handed', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 1, 9), at: sevenPm)],
        DateTime(2026, 6, 15, 10),
        slots: 4,
      );
      expect(result.entries.length, 4);
      expect(result.slots, 4);
      expect(result.isTruncatedByBudget, isTrue);
    });

    test('no slots means nothing is scheduled at all', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 1, 9), at: sevenPm)],
        DateTime(2026, 6, 15, 10),
        slots: 0,
      );
      expect(result.isEmpty, isTrue);
    });

    test('a plan that fits is not reported as cut short', () {
      final result = plan(
        [taskDue(DateTime(2026, 6, 15, 9), at: sevenPm)],
        DateTime(2026, 6, 15, 10),
        horizonDays: 3,
      );
      expect(result.isTruncatedByBudget, isFalse);
    });

    test('ids come from the reminder range and do not repeat', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 10, 9), at: sevenPm, title: 'A'),
        taskDue(DateTime(2026, 6, 10, 9), at: sevenPm, title: 'B'),
      ], DateTime(2026, 6, 15, 10));

      final ids = result.entries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every(isReminderNotificationId), isTrue);
    });

    test('the reminder and digest ranges do not overlap', () {
      // The one invariant that lets each scheduler clear its own pending
      // notifications without taking the other's with it.
      for (var id = digestNotificationIdBase; id < 3000; id++) {
        expect(
          isDigestNotificationId(id) && isReminderNotificationId(id),
          isFalse,
          reason: '$id',
        );
      }
    });

    test('one neglected task cannot silence every other task', () {
      // Three tasks, each overdue for a month, with room for only four
      // notifications. Without the round-robin the first task would take all
      // four and the other two would never be heard from.
      final result = plan(
        [
          taskDue(DateTime(2026, 5, 1, 9), at: sevenPm, title: 'A'),
          taskDue(DateTime(2026, 5, 1, 9), at: sevenPm, title: 'B'),
          taskDue(DateTime(2026, 5, 1, 9), at: sevenPm, title: 'C'),
        ],
        DateTime(2026, 6, 15, 10),
        slots: 4,
      );

      expect(result.taskIds, {'A', 'B', 'C'});
      // Every task's first night, then one second night.
      expect(result.entries.map((e) => (e.taskId, e.fireAt.day)).toList(), [
        ('A', 15),
        ('B', 15),
        ('C', 15),
        ('A', 16),
      ]);
    });

    test('a task due later still gets its first night before anyone gets '
        'a second', () {
      final result = plan(
        [
          taskDue(DateTime(2026, 6, 1, 9), at: sevenPm, title: 'Overdue'),
          taskDue(DateTime(2026, 6, 20, 9), at: sevenPm, title: 'Later'),
        ],
        DateTime(2026, 6, 15, 10),
        slots: 2,
      );
      expect(result.taskIds, {'Overdue', 'Later'});
    });

    test('entries are ordered by the moment they fire', () {
      final result = plan([
        taskDue(DateTime(2026, 6, 15, 9), at: sevenPm, title: 'Evening'),
        taskDue(
          DateTime(2026, 6, 15, 9),
          at: const ReminderTime(hour: 7),
          title: 'Morning',
        ),
      ], DateTime(2026, 6, 15, 6));

      final times = result.entries.map((e) => e.fireAt).toList();
      expect(times, [...times]..sort());
      expect(result.coversUntil, times.last);
    });
  });

  group('reminderSlots', () {
    test('is the full budget when nothing else is pending', () {
      expect(reminderSlots(pendingIds: const []), reminderNotificationBudget);
    });

    test("does not count the reminders' own pending notifications", () {
      final mine = List.generate(
        reminderNotificationBudget,
        (i) => reminderNotificationIdBase + i,
      );
      expect(reminderSlots(pendingIds: mine), reminderNotificationBudget);
    });

    test('yields ground to everything else near the cap', () {
      // 40 foreign notifications leaves 24, which is under the budget.
      expect(reminderSlots(pendingIds: List.generate(40, (i) => i)), 24);
      expect(reminderSlots(pendingIds: List.generate(64, (i) => i)), 0);
      expect(reminderSlots(pendingIds: List.generate(90, (i) => i)), 0);
    });

    test('a full digest window still leaves reminders their whole budget', () {
      // The point of the arrangement: 14 plus 40 is 54, so the digest running
      // first costs the reminders nothing.
      final digest = List.generate(
        digestNotificationBudget,
        (i) => digestNotificationIdBase + i,
      );
      expect(reminderSlots(pendingIds: digest), reminderNotificationBudget);
    });

    test('neither feature can push the other over the iOS cap', () {
      // Whichever runs second sees the other already pending, and the two
      // budgets together stay inside 64 either way round.
      final reminders = List.generate(
        reminderNotificationBudget,
        (i) => reminderNotificationIdBase + i,
      );
      final digest = List.generate(
        digestNotificationBudget,
        (i) => digestNotificationIdBase + i,
      );

      expect(
        digestSlots(pendingIds: reminders) + reminders.length,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
      expect(
        reminderSlots(pendingIds: digest) + digest.length,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
      expect(
        digestNotificationBudget + reminderNotificationBudget,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
    });
  });

  group('daylight saving transitions', () {
    // These assert wall-clock stability, which only means anything when the
    // suite runs in a zone that actually transitions. Run under
    // TZ=America/New_York as well as the default.
    test('keeps the reminder time across a spring-forward', () {
      // The US spring-forward is 08 March 2026; the day is 23 hours long.
      final result = plan([
        taskDue(DateTime(2026, 3, 5, 9), at: sevenPm),
      ], DateTime(2026, 3, 6, 20));

      for (final entry in result.entries) {
        expect(entry.fireAt.hour, 19, reason: '${entry.fireAt}');
        expect(entry.fireAt.minute, 0);
      }
    });

    test('keeps the reminder time across a fall-back', () {
      // The US fall-back is 01 November 2026; the day is 25 hours long.
      final result = plan([
        taskDue(DateTime(2026, 10, 29, 9), at: sevenPm),
      ], DateTime(2026, 10, 30, 20));

      for (final entry in result.entries) {
        expect(entry.fireAt.hour, 19, reason: '${entry.fireAt}');
      }
    });

    test('consecutive reminders are consecutive calendar days', () {
      final result = plan(
        [taskDue(DateTime(2026, 3, 5, 9), at: sevenPm)],
        DateTime(2026, 3, 6, 20),
        horizonDays: 6,
      );

      final days = result.entries.map((e) => e.fireAt.day).toList();
      expect(days, [7, 8, 9, 10, 11]);
    });
  });
}
