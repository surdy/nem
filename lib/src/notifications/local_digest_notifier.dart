import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/digest_schedule.dart';
import 'digest_notifier.dart';

/// The payload every digest carries, so a tap can be told apart from issue
/// #16's per-task reminders, which will carry a task id.
const digestPayload = 'digest';

const _channelId = 'digest';
const _channelName = 'Daily digest';
const _channelDescription = 'One notification a day listing what is due.';

/// [DigestNotifier] backed by `flutter_local_notifications`.
///
/// Every API here is the post-20.0.0 shape: named parameters throughout,
/// `notificationDetails` rather than `details`, and
/// `requestNotificationsPermission` — plural — rather than the
/// `requestPermission` that most tutorials still show.
class LocalDigestNotifier implements DigestNotifier {
  LocalDigestNotifier({FlutterLocalNotificationsPlugin? plugin, this.onTapped})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Called when a digest is tapped while the app is running.
  final void Function(String? payload)? onTapped;

  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _initializeTimeZone();

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // All three false on purpose: with the defaults the system prompt
        // fires during initialisation, which on iOS means on first launch,
        // before the user has seen what nem is. Permission is asked for in
        // [requestPermission] instead, when the digest is switched on.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) =>
          onTapped?.call(response.payload),
    );
  }

  /// Loads the time zone database and points `tz.local` at the device's zone.
  ///
  /// `tz.local` is UTC until it is set, and a digest scheduled at "08:00 UTC"
  /// for a user in New York arrives at 03:00 or 04:00 — the same class of bug
  /// the date arithmetic here works so hard to avoid.
  ///
  /// The IANA name comes from `flutter_timezone` because there is no other
  /// reliable source: `DateTime.timeZoneName` gives an abbreviation ("EST"),
  /// which is ambiguous between zones and changes twice a year.
  Future<void> _initializeTimeZone() async {
    tz_data.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } on Object catch (error) {
      // An unknown or unavailable zone leaves tz.local as UTC, which shifts
      // the digest but does not break the app. Better a digest at the wrong
      // hour than a launch that fails.
      debugPrint('nem: could not resolve the local time zone ($error)');
    }
  }

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
  Future<void> cancelDigests() async {
    for (var offset = 0; offset < digestNotificationBudget; offset++) {
      await _plugin.cancel(id: digestNotificationIdBase + offset);
    }
  }

  @override
  Future<void> schedule(PlannedDigest digest) async {
    await _plugin.zonedSchedule(
      id: digest.id,
      title: digest.title,
      body: digest.body,
      scheduledDate: _toTz(digest.fireAt),
      payload: digestPayload,
      androidScheduleMode: await _scheduleMode(),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Deliberately absent: `matchDateTimeComponents`. See the note on
      // [planDigests] — an OS-level repeat would keep announcing whichever
      // count was true on the day it was scheduled.
    );
  }

  /// A dated local instant, in the zone the user is actually in.
  ///
  /// `TZDateTime` from the wall-clock parts rather than from the epoch, so the
  /// digest lands at 08:00 on the day either side of a transition.
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
  /// alarms and timers, and a digest that arrives a few minutes late is still
  /// a digest. Where exact scheduling happens to be allowed anyway it is used,
  /// which is what `canScheduleExactNotifications` is for.
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
