import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/binding_repository.dart';
import '../data/database.dart';
import '../data/digest_settings_repository.dart';
import '../data/target_repository.dart';
import '../data/task_repository.dart';
import '../domain/binding.dart';
import '../domain/completion.dart';
import '../domain/completion_history.dart';
import '../domain/digest.dart';
import '../domain/due_list.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import '../nfc/nfc_tag_gateway.dart';
import '../nfc/tag_gateway.dart';
import '../notifications/digest_notifier.dart';
import '../notifications/digest_scheduler.dart';
import '../notifications/local_digest_notifier.dart';
import '../notifications/local_reminder_notifier.dart';
import '../notifications/reminder_notifier.dart';
import '../notifications/reminder_scheduler.dart';
import 'app.dart';
import 'clock.dart';
import 'task_completions.dart';

/// Manual providers throughout — Riverpod 3 recommends `@riverpod` codegen only
/// where build_runner is already earning its keep elsewhere (PLAN.md,
/// assumption 2).

/// The local SQLite database, which is the source of truth (ADR 0001).
final databaseProvider = Provider<NemDatabase>((ref) {
  final db = NemDatabase();
  ref.onDispose(db.close);
  return db;
});

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => TaskRepository(ref.watch(databaseProvider)),
);

/// Every live task, soonest due first.
final dueListProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchDueList(),
);

/// Every retired task, most recently archived first.
///
/// Deliberately a separate query rather than a filter over [dueListProvider]:
/// the due list excludes archived tasks in SQL, and the archive is the other
/// half of that same `where`.
final archivedTasksProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchArchivedTasks(),
);

/// The due list grouped Overdue / Today / Soon.
///
/// Reads the clock through [nowProvider] so the grouping can be pinned in
/// tests.
final dueSectionsProvider = Provider<AsyncValue<List<DueSection>>>((ref) {
  final now = ref.watch(nowProvider);
  return ref
      .watch(dueListProvider)
      .whenData((tasks) => groupByDueStatus(tasks, now));
});

final targetRepositoryProvider = Provider<TargetRepository>(
  (ref) => TargetRepository(ref.watch(databaseProvider)),
);

/// Every live target, alphabetically.
final targetListProvider = StreamProvider<List<Target>>(
  (ref) => ref.watch(targetRepositoryProvider).watchTargets(),
);

/// One target, or null once it has been deleted — which is how the detail
/// screen learns to close itself.
final targetProvider = StreamProvider.family<Target?, String>(
  (ref, id) => ref.watch(targetRepositoryProvider).watchTarget(id),
);

/// The tasks at one target, soonest due first.
final targetTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, targetId) =>
      ref.watch(taskRepositoryProvider).watchTasksForTarget(targetId),
);

final bindingRepositoryProvider = Provider<BindingRepository>(
  (ref) => BindingRepository(ref.watch(databaseProvider)),
);

/// The codes bound to one target — its label, and any barcode it has adopted.
final targetBindingsProvider = StreamProvider.family<List<Binding>, String>(
  (ref, targetId) =>
      ref.watch(bindingRepositoryProvider).watchBindingsForTarget(targetId),
);

/// The scan resolution flow (PLAN.md — Resolution).
///
/// One instance for the life of the app, which matters: the thirty-second
/// repeat window is state it holds, and a resolver rebuilt per scan screen
/// would forget that the same target was just scanned.
final scanResolverProvider = Provider<ScanResolver>(
  (ref) => ScanResolver(
    RepositoryScanLookup(
      bindings: ref.watch(bindingRepositoryProvider),
      targets: ref.watch(targetRepositoryProvider),
      tasks: ref.watch(taskRepositoryProvider),
    ),
  ),
);

/// The NFC hardware, behind the one interface that touches the plugin (#8).
///
/// The seam that `ScanPreviewBuilder` is for the camera: overridden with a fake
/// in every test, so writing a tag, a tag too small to hold nem's URI and a
/// phone with no NFC in it are all exercised on a machine with no NFC in it.
final tagGatewayProvider = Provider<TagGateway>((ref) => NfcTagGateway());

/// One task, live, or null once it is gone.
final taskProvider = StreamProvider.family<Task?, String>(
  (ref, taskId) => ref.watch(taskRepositoryProvider).watchTask(taskId),
);

/// A task's surviving completions, most recent work first.
///
/// The completion log itself — nothing derived, nothing cached (ADR 0004).
final completionsProvider = StreamProvider.family<List<Completion>, String>(
  (ref, taskId) =>
      ref.watch(taskRepositoryProvider).watchCompletionsFor(taskId),
);

/// A task's history: its completions, the gap between each consecutive pair,
/// and the trailing-window counts.
final taskHistoryProvider = Provider.family<AsyncValue<TaskHistory>, String>((
  ref,
  taskId,
) {
  final now = ref.watch(nowProvider);
  final task = ref.watch(taskProvider(taskId));
  final completions = ref.watch(completionsProvider(taskId));
  return task.when(
    loading: () => const AsyncValue<TaskHistory>.loading(),
    error: AsyncValue<TaskHistory>.error,
    data: (task) => task == null
        ? const AsyncValue.data(TaskHistory.empty)
        : completions.whenData(
            (completions) =>
                historyFor(task: task, completions: completions, now: now),
          ),
  );
});

/// The current moment, overridable in tests.
///
/// Live rather than frozen: it is recomputed every time [currentDayProvider]
/// moves, which is once per calendar day boundary and once per foreground.
/// Everything downstream — the due list's grouping, the lateness badges, the
/// trailing windows in [taskHistoryProvider] — is counted in calendar days, so
/// the day is the only granularity at which any of it can change, and a
/// finer-grained clock would rebuild the list for nothing.
///
/// Anything measuring *elapsed* time reads [clockProvider] instead: the scan
/// flow's repeat window is thirty seconds, and a clock that only moves at
/// midnight would report every scan as simultaneous.
///
/// Still overridable with a plain value, which is how every test pins it.
final nowProvider = Provider<DateTime>((ref) {
  ref.watch(currentDayProvider);
  return ref.watch(clockProvider)();
});

/// The IANA zone id a newly authored fixed schedule is anchored in (ADR 0010).
///
/// Reads `tz.local`, which `initialiseTimeZones` points at the device's zone on
/// launch. It is a provider so a test can pin it, and so the zone is read once
/// at authoring time rather than every time a due date is computed — a task
/// created in London stays a London task after the phone lands in Tokyo.
final zoneIdProvider = Provider<String>((ref) => tz.local.name);

final digestSettingsRepositoryProvider = Provider<DigestSettingsRepository>(
  (ref) => DigestSettingsRepository(ref.watch(databaseProvider)),
);

/// The single plugin handle both notification features drive.
///
/// One instance, not two. `FlutterLocalNotificationsPlugin` is a thin handle
/// onto one platform channel, so a second instance would address the same OS
/// queue — but `initialize` registers exactly one tap callback, and calling it
/// twice would silently unhook the first. Sharing the handle is also what lets
/// each feature's `pendingIds` see the other's notifications, which is what
/// the shared 64-slot budget is counted from.
///
/// Never reached in tests: every test overrides the notifier providers below.
final notificationPluginProvider = Provider<FlutterLocalNotificationsPlugin>(
  (ref) => FlutterLocalNotificationsPlugin(),
);

/// The digest's seam onto the plugin. Overridden with a fake in tests, which
/// is the whole point of the seam.
///
/// This is also the instance that calls `initialize`, and therefore the one
/// whose callback receives *every* tap — reminders included. It routes on the
/// payload rather than assuming the tap was a digest's.
final digestNotifierProvider = Provider<DigestNotifier>(
  (ref) => LocalDigestNotifier(
    plugin: ref.watch(notificationPluginProvider),
    onTapped: showNotificationTarget,
  ),
);

/// Per-task reminders' seam onto the same plugin (CONTEXT.md — "Reminder").
final reminderNotifierProvider = Provider<ReminderNotifier>(
  (ref) => LocalReminderNotifier(ref.watch(notificationPluginProvider)),
);

final digestSchedulerProvider = Provider<DigestScheduler>(
  (ref) => DigestScheduler(
    notifier: ref.watch(digestNotifierProvider),
    settings: ref.watch(digestSettingsRepositoryProvider),
    tasks: ref.watch(taskRepositoryProvider),
  ),
);

/// The stored digest configuration. Invalidated after every write so the
/// settings screen and the scheduler read the same thing.
final digestSettingsProvider = FutureProvider<DigestSettings>(
  (ref) => ref.watch(digestSettingsRepositoryProvider).read(),
);

/// What the OS currently allows, read without prompting.
final digestPermissionProvider = FutureProvider<NotificationPermission>(
  (ref) => ref.watch(digestNotifierProvider).permission(),
);

/// Keeps the reminders' pending notifications in step with the tasks.
///
/// Reads the wall clock through [clockProvider] — `DateTime.now` in
/// production — rather than calling it directly, so a test can pin the window
/// the same way it pins the due list's grouping.
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final clock = ref.watch(clockProvider);
  return ReminderScheduler(
    notifier: ref.watch(reminderNotifierProvider),
    tasks: ref.watch(taskRepositoryProvider),
    clock: () => clock(),
  );
});

/// The one way the UI records and takes back a completion. See
/// [TaskCompletions] for why it is not `TaskRepository` directly.
final taskCompletionsProvider = Provider<TaskCompletions>(
  (ref) => TaskCompletions(
    tasks: ref.watch(taskRepositoryProvider),
    reminders: ref.watch(reminderSchedulerProvider),
  ),
);
