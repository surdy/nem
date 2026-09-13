import '../domain/digest_schedule.dart';
import 'notification_permission.dart';

export 'notification_permission.dart';

/// The whole of the digest's contact with the platform notification APIs.
///
/// Deliberately a narrow seam. Everything that decides *what* to schedule
/// lives in `domain/digest_schedule.dart` and is a pure function; everything
/// that talks to the OS lives behind this interface. That is what lets the
/// window and budget logic be tested without a plugin, a channel, or a device.
///
/// Per-task reminders have their own seam of the same shape
/// (`reminder_notifier.dart`) rather than sharing this one: they are a
/// different feature with a different id range and a different budget
/// (CONTEXT.md keeps "Digest" and "Reminder" apart). The two implementations
/// happen to drive the same plugin instance, which is what makes
/// [pendingIds] able to see the other feature's notifications.
abstract class DigestNotifier {
  /// Prepares the plugin and the time zone database. Safe to call twice.
  Future<void> initialize();

  /// What the OS currently allows, without prompting.
  Future<NotificationPermission> permission();

  /// Asks the user. On iOS the system prompt appears only the first time, so
  /// this is called at a moment the user has chosen — switching the digest on
  /// — rather than on launch.
  Future<NotificationPermission> requestPermission();

  /// The ids of every notification currently pending, digest or otherwise.
  ///
  /// Read against the iOS cap of 64 before planning
  /// (see [digestSlots]).
  Future<List<int>> pendingIds();

  /// Cancels every notification in the digest's reserved id range, leaving
  /// anything else pending — per-task reminders included — untouched.
  Future<void> cancelDigests();

  /// Schedules one digest at its wall-clock local time.
  Future<void> schedule(PlannedDigest digest);
}
