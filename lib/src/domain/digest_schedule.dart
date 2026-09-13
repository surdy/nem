import 'digest.dart';
import 'due_status.dart';
import 'interval_unit.dart';
import 'schedule.dart';
import 'task.dart';

/// iOS keeps only the **last 64** pending notifications, silently: number 65
/// displaces an earlier one with no error, and on some iOS versions crossing
/// the line has been reported to stop the lot from firing. So the cap is
/// enforced here rather than left to the platform to degrade gracefully.
const iosPendingNotificationLimit = 64;

/// How many of those 64 slots the digest may hold at once.
///
/// Deliberately far below the cap. Per-task reminders (issue #16) share the
/// same budget and there is one of those per task, so the digest — of which
/// there is exactly one a day — has no business taking a large share.
const digestNotificationBudget = 14;

/// How far ahead the planner looks for days worth notifying about.
///
/// Larger than [digestNotificationBudget] because days with nothing due are
/// skipped rather than scheduled, so the horizon and the slot count are not
/// the same quantity.
const digestHorizonDays = 30;

/// Digest notifications own the id range
/// `[digestNotificationIdBase, digestNotificationIdBase + digestNotificationBudget)`.
///
/// Reserved as a block so the scheduler can clear its own pending
/// notifications without touching anyone else's, and so issue #16's per-task
/// reminders can take a disjoint range.
const digestNotificationIdBase = 1000;

/// Whether [id] belongs to the digest's reserved range.
bool isDigestNotificationId(int id) =>
    id >= digestNotificationIdBase &&
    id < digestNotificationIdBase + digestNotificationBudget;

/// How many slots the digest may use, given everything currently pending.
///
/// Notifications already scheduled by the digest do not count against it —
/// they are about to be replaced. Anything else pending does, which is how the
/// digest yields ground to per-task reminders rather than crowding them out.
int digestSlots({required Iterable<int> pendingIds}) {
  final foreign = pendingIds.where((id) => !isDigestNotificationId(id)).length;
  final free = iosPendingNotificationLimit - foreign;
  return free.clamp(0, digestNotificationBudget);
}

/// One digest notification, ready to hand to the platform.
class PlannedDigest {
  const PlannedDigest({
    required this.id,
    required this.fireAt,
    required this.counts,
  });

  /// Drawn from the digest's reserved id range.
  final int id;

  /// The local wall-clock moment this fires.
  final DateTime fireAt;

  final DigestCounts counts;

  String get title => counts.title;
  String get body => counts.body;

  @override
  String toString() => 'PlannedDigest($id at $fireAt, $counts)';
}

/// The full set of digest notifications that should be pending right now.
///
/// A plan is absolute, not a delta: applying it means clearing the digest's
/// range and scheduling exactly these. That is what makes re-topping on
/// foreground idempotent.
class DigestPlan {
  const DigestPlan({
    required this.entries,
    required this.slots,
    required this.daysWithWork,
  });

  static const empty = DigestPlan(entries: [], slots: 0, daysWithWork: 0);

  final List<PlannedDigest> entries;

  /// How many slots were available when this was planned.
  final int slots;

  /// How many days in the horizon had something due. Larger than
  /// `entries.length` when the budget ran out first.
  final int daysWithWork;

  bool get isEmpty => entries.isEmpty;

  /// True when the horizon held more days worth notifying about than the
  /// budget allowed. The digest then simply stops after the last scheduled
  /// day, until the next foreground re-tops it.
  bool get isTruncatedByBudget => daysWithWork > entries.length;

  /// The last moment covered, after which the digest goes quiet unless the app
  /// is opened again.
  DateTime? get coversUntil => entries.isEmpty ? null : entries.last.fireAt;

  @override
  String toString() =>
      'DigestPlan(${entries.length} of $slots slots, $daysWithWork days with work)';
}

/// Works out every digest notification that should be pending, from the tasks
/// as they stand [now].
///
/// ## Why a rolling window of dated notifications, and not one OS repeat
///
/// `matchDateTimeComponents: DateTimeComponents.time` buys an OS-level daily
/// repeat for a single slot, and that is the right tool wherever the text
/// never changes — per-task reminders (issue #16) are exactly that, and this
/// planner deliberately leaves the budget for them.
///
/// It cannot carry the digest, because the digest states a count and the count
/// is different every day. The OS repeats the *text* it was given; it cannot
/// recount. A single repeat would keep announcing the number that was true the
/// day it was scheduled.
///
/// Expanding the window instead is not a guess about the future. Between two
/// foregrounds nothing completes — a completion is recorded in the app — so no
/// task leaves the due list, and the only thing that changes is that more
/// tasks fall due, on dates already known. Each day's counts are therefore
/// exact for as long as the window has to stand on its own, and the moment the
/// app is opened the window is thrown away and rebuilt.
///
/// Days with nothing due are skipped rather than scheduled: a digest reading
/// "0 tasks due" is noise, and skipping stretches the same budget further.
DigestPlan planDigests({
  required DigestSettings settings,
  required Iterable<Task> tasks,
  required DateTime now,
  required int slots,
  int horizonDays = digestHorizonDays,
}) {
  if (!settings.isEnabled || slots <= 0) return DigestPlan.empty;

  // Archived tasks are not due for anything (PLAN.md — the due list filters
  // them out, and the digest counts what the due list shows).
  final live = [
    for (final task in tasks)
      if (!task.isArchived && task.dueDate != null) task,
  ];

  final todayAtDigestTime = settings.time.onDayOf(now);
  final entries = <PlannedDigest>[];
  var daysWithWork = 0;

  for (var offset = 0; offset < horizonDays; offset++) {
    // Calendar arithmetic, never `Duration(days: n)`: a day either side of a
    // daylight saving transition is 23 or 25 hours long, and the digest is
    // owed to the user at 08:00 on both of them.
    final fireAt = addInterval(todayAtDigestTime, offset, IntervalUnit.day);

    // Today's digest time may already have passed; the first entry is then
    // tomorrow's.
    if (!fireAt.isAfter(now)) continue;

    final counts = countFor(live, fireAt);
    if (counts.isEmpty) continue;

    daysWithWork++;
    if (entries.length >= slots) continue;
    entries.add(
      PlannedDigest(
        id: digestNotificationIdBase + entries.length,
        fireAt: fireAt,
        counts: counts,
      ),
    );
  }

  return DigestPlan(entries: entries, slots: slots, daysWithWork: daysWithWork);
}

/// How much is due and how much is overdue, as things would stand at [when].
///
/// Classified with [dueStatusFor], so this counts whole calendar days exactly
/// as the due list's Overdue / Today / Soon grouping does — the digest and the
/// screen it opens can never disagree.
DigestCounts countFor(Iterable<Task> tasks, DateTime when) {
  var dueToday = 0;
  var overdue = 0;
  for (final task in tasks) {
    final due = task.dueDate;
    if (due == null) continue;
    switch (dueStatusFor(due, when)) {
      case DueStatus.overdue:
        overdue++;
      case DueStatus.dueToday:
        dueToday++;
      case DueStatus.upcoming:
        break;
    }
  }
  return DigestCounts(dueToday: dueToday, overdue: overdue);
}
