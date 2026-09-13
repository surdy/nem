import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/interval_unit.dart';
import '../domain/schedule.dart';

/// Reads the wall clock. The one seam the app's sense of "now" is built on, so
/// a test can hand it a clock it controls.
typedef Clock = DateTime Function();

/// The wall clock, overridable in tests.
///
/// Deliberately *not* what records a completion: a completion timestamp is a
/// fact about the world and must be the real instant, so `TaskRepository`
/// keeps calling `DateTime.now()` directly. This clock only decides what the
/// due list is looking at.
final clockProvider = Provider<Clock>((ref) => DateTime.now);

/// Local midnight starting the calendar day [instant] falls in.
DateTime startOfDay(DateTime instant) {
  final local = instant.isUtc ? instant.toLocal() : instant;
  return DateTime(local.year, local.month, local.day);
}

/// The instant the calendar day after [instant] begins.
///
/// Built by calendar construction — [addInterval] — rather than by adding
/// `Duration(days: 1)`, because a day is not always 24 hours: the day
/// containing a spring-forward is 23 hours long and the one containing a
/// fall-back is 25. Adding a fixed duration would land an hour off the
/// boundary in both directions, which is exactly the hour the due list would
/// spend showing the wrong grouping.
///
/// In the handful of zones whose transition happens *at* midnight, the new
/// day's 00:00 does not exist; Dart's `DateTime` constructor resolves that to
/// the first instant that does, which is the start of the day either way.
DateTime nextDayBoundary(DateTime instant) =>
    addInterval(startOfDay(instant), 1, IntervalUnit.day);

/// How long from [instant] until the next calendar day begins.
///
/// A difference between two instants, so it is real elapsed time — 23 or 25
/// hours across a daylight saving transition, rather than a nominal 24.
Duration untilNextDayBoundary(DateTime instant) {
  final delay = nextDayBoundary(instant).difference(instant);
  return delay.isNegative ? Duration.zero : delay;
}

/// The calendar day the app is currently showing, as the instant it began.
///
/// Everything the due list classifies — Overdue / Today / Soon, and the
/// lateness badges — is a function of the calendar day rather than of the
/// minute, so this is the granularity the clock needs to change at. It moves
/// on two triggers:
///
/// * a timer armed for the next day boundary, which covers the app being left
///   open across midnight, and fires once a day rather than once a second;
/// * [sync] on foreground, because a suspended app's timers do not fire, so
///   coming back after a day or a week in the background needs an explicit
///   catch-up (see `app.dart`).
///
/// A device timezone change is handled by the same [sync]: changing the zone
/// means leaving nem for the system settings, and coming back runs the
/// catch-up, which both re-reads the day and re-arms the timer against the new
/// offset. A zone that changes *underneath* a foregrounded app — an automatic
/// update while travelling — is not detected at the moment it happens; the
/// grouping corrects itself at the next boundary or the next foreground. There
/// is no timezone-change event in Flutter to hang anything better off, and the
/// window is a rare few hours in which only the boundary time is wrong.
class CurrentDay extends Notifier<DateTime> {
  Timer? _boundary;

  @override
  DateTime build() {
    ref.onDispose(_cancel);
    final now = ref.watch(clockProvider)();
    _arm(now);
    return startOfDay(now);
  }

  /// Brings the day up to date and re-arms the boundary timer.
  ///
  /// Idempotent, and silent when nothing has changed: the state only moves if
  /// the calendar day actually has, so a foreground ten minutes later rebuilds
  /// nothing.
  void sync() {
    final now = ref.read(clockProvider)();
    _arm(now);
    state = startOfDay(now);
  }

  void _arm(DateTime now) {
    _cancel();
    _boundary = Timer(untilNextDayBoundary(now), sync);
  }

  void _cancel() {
    _boundary?.cancel();
    _boundary = null;
  }
}

/// The day the due list is grouped against. See [CurrentDay].
final currentDayProvider = NotifierProvider<CurrentDay, DateTime>(
  CurrentDay.new,
);
