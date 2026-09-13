import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/digest_settings_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/digest.dart';
import 'package:nem/src/domain/digest_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/notifications/digest_notifier.dart';
import 'package:nem/src/notifications/digest_scheduler.dart';

import 'fake_digest_notifier.dart';

void main() {
  late NemDatabase db;
  late TaskRepository tasks;
  late DigestSettingsRepository settings;
  late FakeDigestNotifier notifier;

  var now = DateTime(2026, 6, 15, 10);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    settings = DigestSettingsRepository(db);
    notifier = FakeDigestNotifier();
    now = DateTime(2026, 6, 15, 10);
  });

  tearDown(() => db.close());

  DigestScheduler scheduler() => DigestScheduler(
    notifier: notifier,
    settings: settings,
    tasks: tasks,
    clock: () => now,
  );

  /// A task due on [due], by way of a floating schedule that started
  /// [intervalN] days earlier. Calendar arithmetic, not `Duration(days:)`.
  Future<void> addTaskDue(String title, DateTime due, {int intervalN = 1}) =>
      tasks.createFloatingTask(
        title: title,
        intervalN: intervalN,
        intervalUnit: IntervalUnit.day,
        startDate: addInterval(due, -intervalN, IntervalUnit.day),
      );

  Future<void> enableDigest({int hour = 8}) => settings.write(
    DigestSettings(isEnabled: true, time: DigestTime(hour: hour, minute: 0)),
  );

  test('schedules nothing while the digest is switched off', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));

    final plan = await scheduler().refresh();

    expect(plan.isEmpty, isTrue);
    expect(notifier.scheduled, isEmpty);
  });

  test('schedules the window once the digest is switched on', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();

    final plan = await scheduler().refresh();

    expect(plan.entries, isNotEmpty);
    expect(notifier.scheduled.keys.toSet(), {
      for (final entry in plan.entries) entry.id,
    });
    expect(notifier.scheduled.values.first.fireAt, DateTime(2026, 6, 16, 8));
  });

  test('honours the stored digest time', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest(hour: 19);

    await scheduler().refresh();

    // Nothing is due on the 15th, so the first digest is the evening of the
    // 16th — at the hour that was stored, not the default.
    expect(notifier.scheduled.values.first.fireAt, DateTime(2026, 6, 16, 19));
  });

  test('re-topping leaves exactly the same notifications pending', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();

    final first = await scheduler().refresh();
    final firstPending = Map.of(notifier.scheduled);

    final second = await scheduler().refresh();

    expect(second.entries.length, first.entries.length);
    expect(notifier.scheduled.keys, firstPending.keys);
    expect(
      notifier.scheduled.values.map((d) => d.fireAt),
      firstPending.values.map((d) => d.fireAt),
    );
  });

  test('re-topping after a day has passed moves the window forward', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();

    await scheduler().refresh();
    expect(notifier.scheduled[digestNotificationIdBase]!.fireAt.day, 16);

    now = DateTime(2026, 6, 17, 10);
    await scheduler().refresh();

    expect(notifier.scheduled[digestNotificationIdBase]!.fireAt.day, 18);
  });

  test('re-topping picks up a completion', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16), intervalN: 7);
    await addTaskDue('Replace the filter', DateTime(2026, 6, 16));
    await enableDigest();

    await scheduler().refresh();
    expect(notifier.scheduled[digestNotificationIdBase]!.counts.dueToday, 2);

    final all = await tasks.allTasks();
    await tasks.recordCompletion(
      all.firstWhere((t) => t.title == 'Water the plants').id,
      completedAt: DateTime(2026, 6, 15, 11),
      now: DateTime(2026, 6, 15, 11),
    );
    await scheduler().refresh();

    // The completed task is not due again for another week, so only the other
    // one is left on the 16th.
    expect(notifier.scheduled[digestNotificationIdBase]!.counts.dueToday, 1);
  });

  test('leaves room for notifications it does not own', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 10));
    await enableDigest();
    // 58 per-task reminders already pending (issue #16).
    notifier.foreignPending.addAll(List.generate(58, (i) => i));

    final plan = await scheduler().refresh();

    expect(plan.entries.length, 6);
    expect(
      notifier.foreignPending.length + notifier.scheduled.length,
      lessThanOrEqualTo(iosPendingNotificationLimit),
    );
  });

  test('does not count its own pending window against its budget', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 10));
    await enableDigest();

    await scheduler().refresh();
    final firstCount = notifier.scheduled.length;
    await scheduler().refresh();

    expect(notifier.scheduled.length, firstCount);
    expect(firstCount, digestNotificationBudget);
  });

  test('clearing takes back the whole pending window', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();

    await scheduler().refresh();
    expect(notifier.scheduled, isNotEmpty);

    await scheduler().clear();

    expect(notifier.scheduled, isEmpty);
  });

  test('archived tasks are not announced', () async {
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();
    await db.customStatement('UPDATE tasks SET is_archived = 1');

    final plan = await scheduler().refresh();

    expect(plan.isEmpty, isTrue);
  });

  test('schedules even when permission has been refused', () async {
    // Nothing throws and nothing is silently dropped: if the user allows
    // notifications later, the window is already there. The settings screen is
    // what tells them it will not arrive until then.
    await addTaskDue('Water the plants', DateTime(2026, 6, 16));
    await enableDigest();
    notifier.permissionStatus = NotificationPermission.denied;

    final plan = await scheduler().refresh();

    expect(plan.entries, isNotEmpty);
    expect(notifier.scheduled, isNotEmpty);
  });
}
