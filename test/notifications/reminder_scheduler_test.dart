import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/digest_settings_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/digest.dart';
import 'package:nem/src/domain/digest_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/reminder.dart';
import 'package:nem/src/domain/reminder_schedule.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/notifications/digest_scheduler.dart';
import 'package:nem/src/notifications/reminder_notifier.dart';
import 'package:nem/src/notifications/reminder_scheduler.dart';

import 'fake_digest_notifier.dart';
import 'fake_reminder_notifier.dart';

void main() {
  late NemDatabase db;
  late TaskRepository tasks;
  late FakeReminderNotifier notifier;

  const sevenPm = ReminderTime(hour: 19);
  var now = DateTime(2026, 6, 15, 10);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    notifier = FakeReminderNotifier();
    now = DateTime(2026, 6, 15, 10);
  });

  tearDown(() => db.close());

  ReminderScheduler scheduler() =>
      ReminderScheduler(notifier: notifier, tasks: tasks, clock: () => now);

  /// A task due on [due], by way of a floating schedule that started
  /// [intervalN] days earlier. Calendar arithmetic, not `Duration(days:)`.
  Future<String> addTaskDue(
    String title,
    DateTime due, {
    int intervalN = 1,
    ReminderTime? remindAt,
  }) async {
    final task = await tasks.createFloatingTask(
      title: title,
      intervalN: intervalN,
      intervalUnit: IntervalUnit.day,
      startDate: addInterval(due, -intervalN, IntervalUnit.day),
    );
    if (remindAt != null) {
      await tasks.setReminderTime(task.id, remindAt, now: now);
    }
    return task.id;
  }

  test('a task without a reminder is never scheduled', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));

    final plan = await scheduler().refresh();

    expect(plan.isEmpty, isTrue);
    expect(notifier.scheduled, isEmpty);
  });

  test('opting in schedules the window', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );

    final plan = await scheduler().refresh();

    expect(plan.entries, isNotEmpty);
    expect(notifier.scheduled.keys.toSet(), {
      for (final entry in plan.entries) entry.id,
    });
    expect(notifier.scheduled.values.first.fireAt, DateTime(2026, 6, 16, 19));
    expect(notifier.scheduled.values.first.title, 'Put the bins out');
  });

  test('nothing is scheduled before the task is due', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 20),
      remindAt: sevenPm,
    );

    await scheduler().refresh();

    expect(
      notifier.scheduled.values.every(
        (r) => !r.fireAt.isBefore(DateTime(2026, 6, 20)),
      ),
      isTrue,
    );
  });

  test('opting back out takes the whole window back', () async {
    final taskId = await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );
    await scheduler().refresh();
    expect(notifier.scheduled, isNotEmpty);

    await tasks.setReminderTime(taskId, null, now: now);
    final plan = await scheduler().refresh();

    expect(plan.isEmpty, isTrue);
    expect(notifier.scheduled, isEmpty);
  });

  test('completing a task cancels the reminder it had pending', () async {
    // The acceptance criterion, end to end. Nothing is cancelled by id: the
    // completed task stops being due, so the reminder it had pending for
    // tonight is simply not in the next plan. The next one is not until the
    // work comes round again.
    final bins = await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 15),
      intervalN: 7,
      remindAt: sevenPm,
    );
    final plants = await addTaskDue(
      'Water the plants',
      DateTime(2026, 6, 15),
      intervalN: 7,
      remindAt: sevenPm,
    );

    await scheduler().refresh();
    expect(notifier.forTask(bins).first.fireAt, DateTime(2026, 6, 15, 19));

    await tasks.recordCompletion(
      bins,
      completedAt: DateTime(2026, 6, 15, 11),
      now: DateTime(2026, 6, 15, 11),
    );
    await scheduler().refresh();

    // Tonight's is gone, and so is every night up to the new due date.
    expect(
      notifier.forTask(bins).first.fireAt,
      DateTime(2026, 6, 22, 19),
      reason: 'the bins are not due again until the 22nd',
    );
    // The other task is untouched — a completion re-plans, it does not wipe.
    expect(notifier.forTask(plants).first.fireAt, DateTime(2026, 6, 15, 19));
  });

  test('undoing a completion puts tonight\'s reminder back', () async {
    final bins = await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 15),
      intervalN: 7,
      remindAt: sevenPm,
    );

    final completion = await tasks.recordCompletion(
      bins,
      completedAt: DateTime(2026, 6, 15, 11),
      now: DateTime(2026, 6, 15, 11),
    );
    await scheduler().refresh();
    expect(notifier.forTask(bins).first.fireAt, DateTime(2026, 6, 22, 19));

    await tasks.undoCompletion(completion, now: DateTime(2026, 6, 15, 12));
    await scheduler().refresh();

    expect(notifier.forTask(bins).first.fireAt, DateTime(2026, 6, 15, 19));
  });

  test('re-topping leaves exactly the same notifications pending', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );

    final first = await scheduler().refresh();
    final firstPending = Map.of(notifier.scheduled);

    final second = await scheduler().refresh();

    expect(second.entries.length, first.entries.length);
    expect(notifier.scheduled.keys, firstPending.keys);
    expect(
      notifier.scheduled.values.map((r) => r.fireAt),
      firstPending.values.map((r) => r.fireAt),
    );
  });

  test('re-topping after a day has passed moves the window forward', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );

    await scheduler().refresh();
    expect(
      notifier.scheduled[reminderNotificationIdBase]!.fireAt,
      DateTime(2026, 6, 16, 19),
    );

    now = DateTime(2026, 6, 17, 10);
    await scheduler().refresh();

    expect(
      notifier.scheduled[reminderNotificationIdBase]!.fireAt,
      DateTime(2026, 6, 17, 19),
    );
  });

  test('does not count its own pending window against its budget', () async {
    // Two tasks overdue for a fortnight want more than the budget between
    // them, so a second refresh that counted its own window would come back
    // with fewer.
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 1),
      remindAt: sevenPm,
    );
    await addTaskDue(
      'Water the plants',
      DateTime(2026, 6, 1),
      remindAt: sevenPm,
    );

    final first = await scheduler().refresh();
    expect(first.slots, reminderNotificationBudget);
    expect(notifier.scheduled.length, reminderNotificationBudget);

    final second = await scheduler().refresh();

    expect(second.slots, reminderNotificationBudget);
    expect(notifier.scheduled.length, reminderNotificationBudget);
  });

  test('leaves room for notifications it does not own', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 1),
      remindAt: sevenPm,
    );
    // 50 notifications pending that the reminders did not schedule.
    notifier.foreignPending.addAll(List.generate(50, (i) => i));

    final plan = await scheduler().refresh();

    expect(plan.entries.length, 14);
    expect(
      notifier.foreignPending.length + notifier.scheduled.length,
      lessThanOrEqualTo(iosPendingNotificationLimit),
    );
  });

  test('clearing takes back the whole pending window', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );

    await scheduler().refresh();
    expect(notifier.scheduled, isNotEmpty);

    await scheduler().clear();

    expect(notifier.scheduled, isEmpty);
  });

  test('archived tasks are not reminded about', () async {
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );
    await db.customStatement('UPDATE tasks SET is_archived = 1');

    final plan = await scheduler().refresh();

    expect(plan.isEmpty, isTrue);
  });

  test('schedules even when permission has been refused', () async {
    // Nothing throws and nothing is silently dropped: if the user allows
    // notifications later, the window is already there.
    await addTaskDue(
      'Put the bins out',
      DateTime(2026, 6, 16),
      remindAt: sevenPm,
    );
    notifier.permissionStatus = NotificationPermission.denied;

    final plan = await scheduler().refresh();

    expect(plan.entries, isNotEmpty);
    expect(notifier.scheduled, isNotEmpty);
  });

  group('sharing the 64 slots with the digest', () {
    late FakeDigestNotifier digestNotifier;
    late DigestSettingsRepository settings;

    /// One plugin, one OS queue: whatever either feature has pending is
    /// visible to the other. The fakes are wired to each other to model that,
    /// which is the only way a test can see the cap at all — no test can ask
    /// the real `pendingNotificationRequests()` anything.
    void wireTogether() {
      digestNotifier.foreignPending
        ..clear()
        ..addAll(notifier.scheduled.keys);
      notifier.foreignPending
        ..clear()
        ..addAll(digestNotifier.scheduled.keys);
    }

    setUp(() async {
      digestNotifier = FakeDigestNotifier();
      settings = DigestSettingsRepository(db);
      await settings.write(
        const DigestSettings(
          isEnabled: true,
          time: DigestTime(hour: 8, minute: 0),
        ),
      );
    });

    DigestScheduler digestScheduler() => DigestScheduler(
      notifier: digestNotifier,
      settings: settings,
      tasks: tasks,
      clock: () => now,
    );

    test('neither starves the other, digest first', () async {
      // Enough overdue work that both features would take everything they
      // could get.
      for (var i = 0; i < 5; i++) {
        await addTaskDue('Task $i', DateTime(2026, 6, 1), remindAt: sevenPm);
      }

      wireTogether();
      await digestScheduler().refresh();
      wireTogether();
      await scheduler().refresh();

      expect(digestNotifier.scheduled.length, digestNotificationBudget);
      expect(notifier.scheduled.length, reminderNotificationBudget);
      expect(
        digestNotifier.scheduled.length + notifier.scheduled.length,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
    });

    test('neither starves the other, reminders first', () async {
      for (var i = 0; i < 5; i++) {
        await addTaskDue('Task $i', DateTime(2026, 6, 1), remindAt: sevenPm);
      }

      wireTogether();
      await scheduler().refresh();
      wireTogether();
      await digestScheduler().refresh();

      expect(notifier.scheduled.length, reminderNotificationBudget);
      expect(digestNotifier.scheduled.length, digestNotificationBudget);
      expect(
        digestNotifier.scheduled.length + notifier.scheduled.length,
        lessThanOrEqualTo(iosPendingNotificationLimit),
      );
    });

    test('their ids never collide', () async {
      for (var i = 0; i < 3; i++) {
        await addTaskDue('Task $i', DateTime(2026, 6, 1), remindAt: sevenPm);
      }

      await digestScheduler().refresh();
      await scheduler().refresh();

      expect(
        digestNotifier.scheduled.keys.toSet().intersection(
          notifier.scheduled.keys.toSet(),
        ),
        isEmpty,
      );
    });

    test('clearing one leaves the other alone', () async {
      await addTaskDue('Task', DateTime(2026, 6, 1), remindAt: sevenPm);

      await digestScheduler().refresh();
      await scheduler().refresh();
      expect(digestNotifier.scheduled, isNotEmpty);

      await scheduler().clear();

      expect(notifier.scheduled, isEmpty);
      expect(digestNotifier.scheduled, isNotEmpty);
    });
  });
}
