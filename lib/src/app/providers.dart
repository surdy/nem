import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/binding_repository.dart';
import '../data/category_filter_repository.dart';
import '../data/category_repository.dart';
import '../data/database.dart';
import '../data/digest_settings_repository.dart';
import '../data/scan_repeat_repository.dart';
import '../data/target_repository.dart';
import '../data/task_repository.dart';
import '../domain/binding.dart';
import '../domain/category.dart';
import '../domain/completion.dart';
import '../domain/completion_history.dart';
import '../domain/digest.dart';
import '../domain/due_list.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import '../nfc/nfc_tag_gateway.dart';
import '../nfc/platform_tag_launch.dart';
import '../nfc/tag_gateway.dart';
import '../nfc/tag_launch.dart';
import '../notifications/digest_notifier.dart';
import '../notifications/digest_scheduler.dart';
import '../notifications/local_digest_notifier.dart';
import '../notifications/local_reminder_notifier.dart';
import '../notifications/reminder_notifier.dart';
import '../notifications/reminder_scheduler.dart';
import '../photos/photo_providers.dart';
import 'app.dart';
import 'clock.dart';
import 'task_completions.dart';
import 'task_deletion.dart';

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

final categoryRepositoryProvider = Provider<CategoryRepository>(
  (ref) => CategoryRepository(ref.watch(databaseProvider)),
);

/// Every live category, alphabetically (CONTEXT.md — "Category").
final categoryListProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(categoryRepositoryProvider).watchCategories(),
);

/// The live categories one task is in.
final taskCategoriesProvider = StreamProvider.family<List<Category>, String>(
  (ref, taskId) =>
      ref.watch(categoryRepositoryProvider).watchCategoriesForTask(taskId),
);

final categoryFilterRepositoryProvider = Provider<CategoryFilterRepository>(
  (ref) => CategoryFilterRepository(ref.watch(databaseProvider)),
);

/// Which categories the due list is currently filtered to, kept across
/// launches. Empty means no filter — everything.
///
/// Device-local UI state, stored in `sync_state` and never pushed; the argument
/// for that is in [CategoryFilterRepository].
///
/// It watches [categoryListProvider] so that the set can be pruned against the
/// categories that actually exist. A category deleted here — or on the other
/// phone, arriving in a pull — must not leave the due list filtered to an id
/// that names nothing, which would show an empty list with no way to see why.
/// The pruned set is written back, so the staleness is resolved once rather
/// than on every read.
class CategoryFilterStore extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final repository = ref.watch(categoryFilterRepositoryProvider);
    final live = {
      for (final category in await ref.watch(categoryListProvider.future))
        category.id,
    };
    final stored = await repository.read();
    final pruned = stored.intersection(live);
    if (pruned.length != stored.length) await repository.write(pruned);
    return pruned;
  }

  /// Filters to exactly [categoryIds]; an empty set is no filter at all.
  Future<void> select(Set<String> categoryIds) async {
    await ref.read(categoryFilterRepositoryProvider).write(categoryIds);
    state = AsyncValue.data(categoryIds);
  }

  /// Adds or removes one category from the filter.
  Future<void> toggle(String categoryId) async {
    final next = {...await future};
    if (!next.remove(categoryId)) next.add(categoryId);
    await select(next);
  }

  /// Back to everything.
  Future<void> clear() => select(const {});
}

final categoryFilterProvider =
    AsyncNotifierProvider<CategoryFilterStore, Set<String>>(
      CategoryFilterStore.new,
    );

/// Every live task, soonest due first, narrowed to the categories the filter
/// names.
///
/// The filter is awaited rather than read, because it comes off disk: reading
/// it synchronously would mean showing the unfiltered list for a frame on every
/// launch, which is the one moment the filter is most surprising to lose.
final dueListProvider = StreamProvider<List<Task>>((ref) async* {
  final categoryIds = await ref.watch(categoryFilterProvider.future);
  yield* ref
      .watch(taskRepositoryProvider)
      .watchDueList(categoryIds: categoryIds);
});

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

/// Where the repeat window's anchor is kept between processes.
///
/// Device-local key/value state in `sync_state`, which is why this needs no
/// schema change — see [ScanRepeatRepository].
final scanRepeatStoreProvider = Provider<ScanRepeatStore>(
  (ref) => ScanRepeatRepository(ref.watch(databaseProvider)),
);

/// The scan resolution flow (PLAN.md — Resolution).
///
/// One instance for the life of the app, which matters: the thirty-second
/// repeat window is state it holds, and a resolver rebuilt per scan screen
/// would forget that the same target was just scanned. It is also state that
/// has to outlive the app itself now that a tag can launch it from closed
/// (#9), which is what the store is for.
final scanResolverProvider = Provider<ScanResolver>(
  (ref) => ScanResolver(
    RepositoryScanLookup(
      bindings: ref.watch(bindingRepositoryProvider),
      targets: ref.watch(targetRepositoryProvider),
      tasks: ref.watch(taskRepositoryProvider),
    ),
    repeats: ref.watch(scanRepeatStoreProvider),
  ),
);

/// The NFC hardware, behind the one interface that touches the plugin (#8).
///
/// The seam that `ScanPreviewBuilder` is for the camera: overridden with a fake
/// in every test, so writing a tag, a tag too small to hold nem's URI and a
/// phone with no NFC in it are all exercised on a machine with no NFC in it.
final tagGatewayProvider = Provider<TagGateway>((ref) => NfcTagGateway());

/// Tags tapped while nem was closed or in the background (#9).
///
/// A separate seam from [tagGatewayProvider] on purpose: nothing about a launch
/// goes through the plugin, or through an NFC session at all — the OS read the
/// tag and handed nem a URI through Android's intent system.
final tagLaunchGatewayProvider = Provider<TagLaunchGateway>((ref) {
  final gateway = PlatformTagLaunchGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

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

/// The one way the UI deletes a task, for the same reason: deleting one has to
/// take its reference photos and its pending reminders with it, in that order.
final taskDeletionProvider = Provider<TaskDeletion>(
  (ref) => TaskDeletion(
    tasks: ref.watch(taskRepositoryProvider),
    photos: ref.watch(photoRepositoryProvider),
    reminders: ref.watch(reminderSchedulerProvider),
  ),
);
