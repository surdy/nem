import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app.dart';
import 'src/app/providers.dart';
import 'src/app/time_zones.dart';
import 'src/sync/sync_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Before anything reads a task: a fixed schedule's occurrences are wall-clock
  // times in a named zone, and resolving one needs the tz database loaded
  // (ADR 0010).
  await initialiseTimeZones();

  final container = ProviderContainer();

  // Due dates and last-completed timestamps are recomputed from the completion
  // log on launch (PLAN.md, ADR 0004), so a date change or a timezone shift
  // since the last run cannot leave them stale. This is an explicit launch-time
  // call rather than drift's `beforeOpen`, which fires on every database open.
  await container.read(taskRepositoryProvider).recomputeDerivedState();

  // Prepares the plugin and the time zone database, and schedules the digest
  // against the due dates just recomputed. No permission is requested here —
  // the iOS prompt only ever appears once, and spending it on a cold first
  // launch, before the user has seen what nem is, wastes it. It is asked for
  // when the digest is switched on instead.
  await container.read(digestNotifierProvider).initialize();
  await container.read(digestSchedulerProvider).refresh();

  // Reminders second, against the same recomputed due dates. Order does not
  // decide who gets slots — the two budgets are fixed and disjoint, 14 plus 40
  // of the 64 iOS allows — it only decides which of them sees the other's
  // notifications already pending on this particular launch.
  await container.read(reminderSchedulerProvider).refresh();

  // Pushes anything the outbox is holding and pulls whatever the other device
  // wrote (#11). Deliberately not awaited: SQLite is the source of truth
  // (ADR 0001), so nothing on this screen is waiting on a server, and a phone
  // with no signal — or no account at all — must reach the due list exactly as
  // fast as one with both.
  unawaited(container.read(syncStatusProvider.notifier).sync());

  runApp(
    UncontrolledProviderScope(container: container, child: const NemApp()),
  );
}
