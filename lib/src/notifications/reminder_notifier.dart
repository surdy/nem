import '../domain/reminder_schedule.dart';
import 'notification_permission.dart';

export 'notification_permission.dart';

/// The whole of per-task reminders' contact with the platform notification
/// APIs (CONTEXT.md — "Reminder").
///
/// The same shape as `DigestNotifier`, and deliberately a separate interface:
/// reminders own a different id range, answer to a different budget, and
/// cancel on a different event. Everything that decides *what* to schedule
/// lives in `domain/reminder_schedule.dart` and is a pure function; everything
/// that talks to the OS lives behind here, which is what lets the planning and
/// the budget be tested without a plugin, a channel, or a device.
abstract class ReminderNotifier {
  /// What the OS currently allows, without prompting.
  Future<NotificationPermission> permission();

  /// Asks the user. On iOS the system prompt appears only the first time in
  /// the life of an install, so this is called at a moment the user has
  /// chosen — switching a reminder on — rather than on launch. Whichever of
  /// the digest and a reminder is switched on first is the one that spends it.
  Future<NotificationPermission> requestPermission();

  /// The ids of every notification currently pending, reminder or otherwise.
  ///
  /// Read against the iOS cap of 64 before planning (see [reminderSlots]).
  Future<List<int>> pendingIds();

  /// Cancels every notification in the reminders' reserved id range, leaving
  /// anything else pending — the digest included — untouched.
  Future<void> cancelReminders();

  /// Schedules one reminder at its wall-clock local time.
  Future<void> schedule(PlannedReminder reminder);
}
