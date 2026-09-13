import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/reminder_schedule.dart';
import 'reminder_notifier.dart';

/// The prefix every reminder's payload carries, so a tap can be told apart
/// from a digest tap — which carries `digestPayload` and no task.
const reminderPayloadPrefix = 'reminder:';

/// The payload a reminder for [taskId] carries.
String reminderPayload(String taskId) => '$reminderPayloadPrefix$taskId';

/// The task a tapped notification is about, or null when it is not a reminder.
///
/// Tolerant of null and of anything it does not recognise: a payload written
/// by an older build can still be sitting in the OS's pending queue when a
/// newer one reads it, and a tap that cannot be routed should land on the due
/// list rather than throw inside a platform callback.
String? reminderTaskId(String? payload) {
  if (payload == null || !payload.startsWith(reminderPayloadPrefix)) {
    return null;
  }
  final taskId = payload.substring(reminderPayloadPrefix.length);
  return taskId.isEmpty ? null : taskId;
}

const _channelId = 'reminders';
const _channelName = 'Task reminders';
const _channelDescription =
    'A reminder for one task, at the time you chose for it.';

/// [ReminderNotifier] backed by `flutter_local_notifications`.
///
/// Takes the plugin rather than making one. `FlutterLocalNotificationsPlugin`
/// is a thin handle onto a single platform channel, so two instances would
/// address the same OS queue — but only one `initialize` call's tap callback
/// survives, and calling it twice would silently unhook the other feature's
/// taps. One instance is created in `providers.dart`, initialised once by
/// `LocalDigestNotifier`, and shared. That is also what makes [pendingIds]
/// honest: it returns the digest's notifications too, which is exactly what
/// the budget arithmetic needs.
class LocalReminderNotifier implements ReminderNotifier {
  LocalReminderNotifier(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<NotificationPermission> permission() async {
    if (Platform.isAndroid) {
      final enabled = await _android?.areNotificationsEnabled();
      return switch (enabled) {
        true => NotificationPermission.granted,
        false => NotificationPermission.denied,
        null => NotificationPermission.notDetermined,
      };
    }
    if (Platform.isIOS) {
      final options = await _ios?.checkPermissions();
      if (options == null) return NotificationPermission.notDetermined;
      return options.isEnabled
          ? NotificationPermission.granted
          : NotificationPermission.denied;
    }
    return NotificationPermission.notDetermined;
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    final granted = Platform.isAndroid
        // Note the "s". `requestPermission()` was removed; Android 13+ needs
        // this for POST_NOTIFICATIONS and older versions return true.
        ? await _android?.requestNotificationsPermission()
        : await _ios?.requestPermissions(alert: true, badge: true, sound: true);

    return switch (granted) {
      true => NotificationPermission.granted,
      false => NotificationPermission.denied,
      null => permission(),
    };
  }

  @override
  Future<List<int>> pendingIds() async {
    final pending = await _plugin.pendingNotificationRequests();
    return [for (final request in pending) request.id];
  }

  @override
  Future<void> cancelReminders() async {
    for (var offset = 0; offset < reminderNotificationBudget; offset++) {
      await _plugin.cancel(id: reminderNotificationIdBase + offset);
    }
  }

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    await _plugin.zonedSchedule(
      id: reminder.id,
      title: reminder.title,
      body: reminder.body,
      scheduledDate: _toTz(reminder.fireAt),
      // The task id, so a tap opens that task rather than the due list.
      payload: reminderPayload(reminder.taskId),
      androidScheduleMode: await _scheduleMode(),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          // `channelId` and `channelName` are still positional.
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Deliberately absent: `matchDateTimeComponents`. See the note on
      // [planReminders] — an OS repeat cannot tell whether the task is due,
      // and `DateTimeComponents.time` throws away the date it was given, so it
      // would start firing tonight for a task that is not due for a week.
    );
  }

  /// A dated local instant, in the zone the user is actually in.
  ///
  /// `TZDateTime` built from the wall-clock parts rather than from the epoch,
  /// so "bins at 19:00" lands at 19:00 on the day either side of a daylight
  /// saving transition. Nothing downstream of here touches a naive local
  /// `DateTime` again.
  tz.TZDateTime _toTz(DateTime fireAt) {
    final local = fireAt.isUtc ? fireAt.toLocal() : fireAt;
    return tz.TZDateTime(
      tz.local,
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
  }

  /// Exact delivery where the OS permits it, inexact otherwise.
  ///
  /// nem does not declare `SCHEDULE_EXACT_ALARM`: Android reserves it for
  /// alarms and timers, and a reminder that arrives a few minutes late is
  /// still a reminder.
  Future<AndroidScheduleMode> _scheduleMode() async {
    if (!Platform.isAndroid) return AndroidScheduleMode.exactAllowWhileIdle;
    final canBeExact = await _android?.canScheduleExactNotifications() ?? false;
    return canBeExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();
}
