import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notifications/local_reminder_notifier.dart';
import '../sync/sync_providers.dart';
import '../ui/home_shell.dart';
import '../ui/tag_launch_host.dart';
import '../ui/task_detail_screen.dart';
import 'clock.dart';
import 'providers.dart';

/// Lets a tapped notification reach the navigator from outside the widget
/// tree.
final nemNavigatorKey = GlobalKey<NavigatorState>();

/// Where a tapped notification should land, decided from its payload.
///
/// The two features are told apart here and nowhere else: a reminder carries
/// the task it is about (CONTEXT.md — "Reminder"), a digest carries no task
/// because it is about everything at once. Anything unrecognised falls back to
/// the due list rather than throwing, because this runs inside a platform
/// callback where a throw goes nowhere useful — and because a payload written
/// by an older build can still be sitting in the OS's pending queue.
void showNotificationTarget(String? payload) {
  final taskId = reminderTaskId(payload);
  if (taskId == null) {
    showDueList();
  } else {
    showTask(taskId);
  }
}

/// Brings the due list forward — what tapping a digest does.
///
/// The due list is the app's home route, so a tap that cold-starts nem lands
/// there without any help. This is for the other case: a tap while nem is in
/// the background with, say, the settings screen or the task editor on top.
void showDueList() =>
    nemNavigatorKey.currentState?.popUntil((route) => route.isFirst);

/// Opens one task — what tapping its reminder does.
///
/// Pops back to the due list first, so tapping two reminders in a row leaves
/// one task screen on the stack rather than a pile of them, and so back from
/// the task always lands on the due list.
void showTask(String taskId) {
  final navigator = nemNavigatorKey.currentState;
  if (navigator == null) return;
  navigator
    ..popUntil((route) => route.isFirst)
    ..push(
      MaterialPageRoute<void>(builder: (_) => TaskDetailScreen(taskId: taskId)),
    );
}

class NemApp extends ConsumerStatefulWidget {
  const NemApp({super.key});

  @override
  ConsumerState<NemApp> createState() => _NemAppState();
}

class _NemAppState extends ConsumerState<NemApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  /// Everything that has to catch up with the world after nem was away.
  ///
  /// One listener rather than two, because both halves are the same idea: time
  /// passed while the process was suspended and nothing in it noticed.
  void _onResume() {
    // Re-tops the rolling window. Days fall off the front of it as they fire,
    // completions change what the remaining days should say, and nothing in the
    // OS can recompute either — so the window is rebuilt from the tasks as they
    // now stand.
    ref.read(digestSchedulerProvider).refresh();

    // And the same for the reminders, for the same reason plus one of their
    // own: a reminder only stands while its task is still due, and the window
    // has to be rebuilt against today's due dates rather than the ones that
    // were true when the app was last open.
    ref.read(reminderSchedulerProvider).refresh();

    // Re-reads the calendar day. The boundary timer that normally moves it does
    // not fire in a suspended process, so an app backgrounded on Monday and
    // reopened on Wednesday would otherwise still be grouping against Monday.
    // Also re-arms that timer, which is what picks up a timezone changed in the
    // system settings — leaving nem to change it is what got us here.
    ref.read(currentDayProvider.notifier).sync();

    // Pushes what was written while nem was away and pulls what the other
    // device wrote (PLAN.md — Sync: "on foreground"). Returns immediately
    // having done nothing on a device with no backend configured, which is why
    // this is safe to call unconditionally and why nothing here is awaited —
    // the foreground must not wait on a network.
    unawaited(ref.read(syncStatusProvider.notifier).sync());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nem',
      navigatorKey: nemNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F6B4F),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F6B4F),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // Wrapped rather than routed to: a tag tapped while nem is closed or in
      // the background resolves into whatever is already on screen (#9), and
      // the host is what gives that resolution a navigator to present into.
      home: const TagLaunchHost(child: HomeShell()),
    );
  }
}
