import 'package:nem/src/domain/reminder_schedule.dart';
import 'package:nem/src/notifications/reminder_notifier.dart';

/// A [ReminderNotifier] that records what it was asked to do.
///
/// The counterpart to `FakeDigestNotifier`, and for the same reason:
/// everything a reminder decides is decided before it reaches this seam, so a
/// fake here is enough to test the whole feature short of the platform call
/// itself — which no test can make, and no test pretends to. Nothing in the
/// suite can observe a notification actually being delivered.
class FakeReminderNotifier implements ReminderNotifier {
  FakeReminderNotifier({
    this.permissionStatus = NotificationPermission.granted,
    this.permissionAfterRequest,
  });

  /// What the OS says now.
  NotificationPermission permissionStatus;

  /// What the OS says after being asked. Null means the request is granted.
  NotificationPermission? permissionAfterRequest;

  /// Notifications pending that the reminders do not own — the digest's
  /// window looks like this.
  final foreignPending = <int>[];

  /// Reminder notifications currently pending, by id.
  final scheduled = <int, PlannedReminder>{};

  int requestCount = 0;
  int cancelCount = 0;

  /// The task ids with at least one reminder pending.
  Set<String> get scheduledTaskIds => {
    for (final reminder in scheduled.values) reminder.taskId,
  };

  /// Every pending reminder for one task, soonest first.
  List<PlannedReminder> forTask(String taskId) => [
    for (final r in scheduled.values)
      if (r.taskId == taskId) r,
  ]..sort((a, b) => a.fireAt.compareTo(b.fireAt));

  @override
  Future<NotificationPermission> permission() async => permissionStatus;

  @override
  Future<NotificationPermission> requestPermission() async {
    requestCount++;
    permissionStatus = permissionAfterRequest ?? NotificationPermission.granted;
    return permissionStatus;
  }

  @override
  Future<List<int>> pendingIds() async => [
    ...foreignPending,
    ...scheduled.keys,
  ];

  @override
  Future<void> cancelReminders() async {
    cancelCount++;
    scheduled.clear();
  }

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    scheduled[reminder.id] = reminder;
  }
}
