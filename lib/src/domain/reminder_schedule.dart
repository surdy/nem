import 'digest_schedule.dart';
import 'due_status.dart';
import 'interval_unit.dart';
import 'schedule.dart';
import 'task.dart';

/// How many of iOS's 64 pending slots per-task reminders may hold at once.
///
/// [iosPendingNotificationLimit] is the shared ceiling and lives with the
/// digest, which reserved it first. The two budgets are fixed and disjoint —
/// 40 here plus [digestNotificationBudget]'s 14 is 54 of 64 — so neither
/// feature can starve the other however the two schedulers happen to be
/// interleaved, and there is still headroom for whatever a later ticket wants
/// to schedule.
///
/// Deliberately the larger share: there is one digest a day, and one reminder
/// per task that has opted in.
const reminderNotificationBudget = 40;

/// Reminders own the id range
/// `[reminderNotificationIdBase, reminderNotificationIdBase + reminderNotificationBudget)`
/// — 2000..2039, disjoint from the digest's 1000..1013.
///
/// Reserved as a block so the scheduler can clear its own pending
/// notifications without touching the digest's, and vice versa.
const reminderNotificationIdBase = 2000;

/// How far ahead the planner looks for days a task is due or overdue on.
///
/// Larger than [reminderNotificationBudget] because the budget is shared out
/// across every task that has a reminder, so no one task gets anything like
/// the horizon's worth of slots.
const reminderHorizonDays = 30;

/// Whether [id] belongs to the reminders' reserved range.
bool isReminderNotificationId(int id) =>
    id >= reminderNotificationIdBase &&
    id < reminderNotificationIdBase + reminderNotificationBudget;

/// How many slots reminders may use, given everything currently pending.
///
/// The mirror image of [digestSlots]: notifications already scheduled by the
/// reminders do not count against them — they are about to be replaced —
/// while anything else pending does. That is what makes the order the two
/// schedulers run in irrelevant.
int reminderSlots({required Iterable<int> pendingIds}) {
  final foreign = pendingIds
      .where((id) => !isReminderNotificationId(id))
      .length;
  final free = iosPendingNotificationLimit - foreign;
  return free.clamp(0, reminderNotificationBudget);
}

/// One reminder notification, ready to hand to the platform
/// (CONTEXT.md — "Reminder").
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.taskId,
    required this.taskTitle,
    required this.dueDate,
    required this.fireAt,
  });

  /// Drawn from the reminders' reserved id range.
  final int id;

  /// The task this reminds about. Carried into the notification payload, which
  /// is what lets a tap open that task rather than the due list.
  final String taskId;

  final String taskTitle;

  /// The task's due date as it stood when this was planned.
  final DateTime dueDate;

  /// The local wall-clock moment this fires. Always a moment at which the task
  /// is due or overdue — that is the whole point of the planner.
  final DateTime fireAt;

  /// How the task stands at [fireAt]. Never [DueStatus.upcoming].
  DueStatus get status => dueStatusFor(dueDate, fireAt);

  /// The notification title: the task, because that is what the user is being
  /// reminded about and what tapping it opens.
  String get title => taskTitle;

  /// "Due today", or "3 days late" once it has been missed.
  ///
  /// Worded exactly as the due list words it — [overdueLabel] is the same
  /// function the lateness badge uses — so a reminder and the screen it opens
  /// can never disagree.
  String get body => overdueLabel(dueDate, fireAt) ?? 'Due today';

  @override
  String toString() => 'PlannedReminder($id, $taskTitle at $fireAt)';
}

/// The full set of reminder notifications that should be pending right now.
///
/// A plan is absolute, not a delta: applying it means clearing the reminders'
/// range and scheduling exactly these. That is what makes re-topping on
/// foreground idempotent, and it is also how a completion cancels a reminder —
/// the completed task is no longer due, so it contributes nothing to the next
/// plan and its pending notifications go away with the range.
class ReminderPlan {
  const ReminderPlan({
    required this.entries,
    required this.slots,
    required this.remindersWanted,
  });

  static const empty = ReminderPlan(entries: [], slots: 0, remindersWanted: 0);

  final List<PlannedReminder> entries;

  /// How many slots were available when this was planned.
  final int slots;

  /// How many reminders the horizon asked for. Larger than `entries.length`
  /// when the budget ran out first.
  final int remindersWanted;

  bool get isEmpty => entries.isEmpty;

  /// True when the horizon wanted more reminders than the budget allowed.
  /// Reminders then simply stop after the last scheduled one, until the next
  /// foreground re-tops them.
  bool get isTruncatedByBudget => remindersWanted > entries.length;

  /// The task ids that have at least one reminder pending.
  Set<String> get taskIds => {for (final entry in entries) entry.taskId};

  /// The last moment covered, after which reminders go quiet unless the app is
  /// opened again.
  DateTime? get coversUntil => entries.isEmpty ? null : entries.last.fireAt;

  @override
  String toString() =>
      'ReminderPlan(${entries.length} of $slots slots, '
      '$remindersWanted wanted)';
}

/// Works out every reminder notification that should be pending, from the
/// tasks as they stand [now].
///
/// ## Why dated one-shots, and not one OS repeat per task
///
/// `matchDateTimeComponents: DateTimeComponents.time` buys an OS-level daily
/// repeat for a single slot, and `planDigests` explicitly set the budget aside
/// expecting reminders to be able to use it, on the grounds that a reminder's
/// text never changes. The text does not — but a reminder is not a daily
/// alarm, and the criterion this ticket turns on is that it fires *only when
/// the task is actually due or overdue*. That condition changes every day, and
/// a repeat cannot re-evaluate it any more than it could recount the digest.
///
/// The repeat is also weaker than it looks. `DateTimeComponents.time` keeps
/// only the hour and minute: the date it was scheduled with is discarded, so a
/// repeat registered today for a task due next Tuesday starts firing tonight.
/// There is no "from this date, daily" component to ask for.
///
/// So reminders are dated one-shots, one per day the task is due or overdue,
/// and the planner decides which days those are. Expanding the window is not a
/// guess about the future: between two foregrounds nothing completes — a
/// completion is recorded in the app — so no task leaves the due list, and the
/// only thing that changes is that tasks fall due on dates already known. The
/// moment the app is opened the window is thrown away and rebuilt.
///
/// ## How the budget is shared out
///
/// An overdue task wants a reminder on every day it stays overdue, so a single
/// neglected task could eat the whole budget and silence every other task's
/// first reminder. Slots are therefore handed out in rounds: every task gets
/// its next reminder before any task gets the one after. The first day each
/// task is due is the last thing to be dropped.
ReminderPlan planReminders({
  required Iterable<Task> tasks,
  required DateTime now,
  required int slots,
  int horizonDays = reminderHorizonDays,
}) {
  if (slots <= 0) return ReminderPlan.empty;

  // Archived tasks are not due for anything (PLAN.md — the due list filters
  // them out, and a reminder is about a task on the due list).
  final live = [
    for (final task in tasks)
      if (!task.isArchived && task.hasReminder && task.dueDate != null) task,
  ]..sort(_byTitleThenId);

  // Per task, the days in the horizon it would be due or overdue on, soonest
  // first. Held as a list of lists so the budget can be dealt round by round.
  final rounds = <List<PlannedReminder>>[];
  var wanted = 0;

  for (final task in live) {
    final days = _reminderDaysFor(task, now: now, horizonDays: horizonDays);
    if (days.isEmpty) continue;
    wanted += days.length;
    rounds.add(days);
  }

  final chosen = <PlannedReminder>[];
  for (var depth = 0; chosen.length < slots; depth++) {
    var reached = false;
    for (final days in rounds) {
      if (depth >= days.length) continue;
      reached = true;
      if (chosen.length >= slots) break;
      chosen.add(days[depth]);
    }
    if (!reached) break;
  }

  // Soonest first, so ids run in the order the notifications will fire and the
  // window reads the way it behaves. Ties break on the task, not on whatever
  // order the rounds happened to produce.
  chosen.sort((a, b) {
    final byTime = a.fireAt.compareTo(b.fireAt);
    return byTime != 0 ? byTime : a.taskId.compareTo(b.taskId);
  });

  return ReminderPlan(
    entries: [
      for (final (index, entry) in chosen.indexed)
        PlannedReminder(
          id: reminderNotificationIdBase + index,
          taskId: entry.taskId,
          taskTitle: entry.taskTitle,
          dueDate: entry.dueDate,
          fireAt: entry.fireAt,
        ),
    ],
    slots: slots,
    remindersWanted: wanted,
  );
}

/// Every moment in the horizon at which [task] would be reminded about.
///
/// Ids are placeholders here; the real ones are assigned once the budget has
/// been shared out and the winners ordered.
List<PlannedReminder> _reminderDaysFor(
  Task task, {
  required DateTime now,
  required int horizonDays,
}) {
  final due = task.dueDate!;
  final time = task.reminderTime!;
  final todayAtReminderTime = time.onDayOf(now);
  final days = <PlannedReminder>[];

  for (var offset = 0; offset < horizonDays; offset++) {
    // Calendar arithmetic, never `Duration(days: n)`: a day either side of a
    // daylight saving transition is 23 or 25 hours long, and "bins at 7pm" is
    // owed at 19:00 on both of them.
    final fireAt = addInterval(todayAtReminderTime, offset, IntervalUnit.day);

    // Today's reminder time may already have passed; the first is then
    // tomorrow's.
    if (!fireAt.isAfter(now)) continue;

    // The criterion with teeth: the schedule decides, not the clock. Compared
    // in whole calendar days by [dueStatusFor], exactly as the due list groups,
    // so a task due at 09:00 is still "due today" to a reminder at 19:00.
    if (dueStatusFor(due, fireAt) == DueStatus.upcoming) continue;

    days.add(
      PlannedReminder(
        id: reminderNotificationIdBase,
        taskId: task.id,
        taskTitle: task.title,
        dueDate: due,
        fireAt: fireAt,
      ),
    );
  }
  return days;
}

/// A stable order for dealing out the budget, so the same tasks and the same
/// clock always produce the same plan.
int _byTitleThenId(Task a, Task b) {
  final byTitle = a.title.compareTo(b.title);
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}
