import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Loads the IANA time zone database and points `tz.local` at the device's own
/// zone.
///
/// Fixed schedules are stored as a wall-clock time plus an IANA zone id and
/// resolved per occurrence against that zone (ADR 0010), so nothing in the due
/// date engine works until the database is loaded. Call this once, before the
/// first read of any task.
///
/// `timezone` ships the database but cannot say which zone the device is in —
/// that is an OS question — so `flutter_timezone` is here for the one call that
/// asks it. It is the only maintained plugin that returns the IANA identifier
/// (rather than an offset or an abbreviation) on both iOS and Android, and an
/// identifier is exactly what ADR 0010 requires: an offset cannot survive a
/// daylight saving transition.
///
/// Returns the zone that was adopted.
Future<String> initialiseTimeZones() async {
  tz_data.initializeTimeZones();
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(info.identifier));
  } catch (error) {
    // A zone the bundled tzdata snapshot has never heard of, or a platform
    // channel that is not there (a unit test, a plain Dart host). Neither is
    // worth failing a launch over: `tz.local` stays UTC, which keeps the app
    // usable and keeps every fixed schedule that names its own zone correct —
    // only newly authored ones would pick up the wrong default.
    debugPrint('nem: could not read the device time zone ($error); using UTC.');
  }
  return tz.local.name;
}
