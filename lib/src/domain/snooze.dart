import 'due_status.dart';
import 'interval_unit.dart';
import 'schedule.dart';

/// Pushing a task out without pretending you did it.
///
/// ## Where a snooze lives, and why it cannot live in `due_date`
///
/// `due_date` is a cache (ADR 0004). `TaskRepository.recomputeDerivedState`
/// rewrites it from the schedule and the completion log on every launch and
/// after every sync pull, so anything written *into* that column and not
/// re-derivable from its inputs is erased the next time the app starts — which
/// would look exactly like a flaky bug and not like the design error it is.
///
/// So a snooze is not a due date that was moved. It is a separate, authoritative
/// fact — "do not show me this before `<date>`, and I said so at `<instant>`"
/// —
/// stored in `tasks.snoozed_until` / `tasks.snoozed_at`, which nothing derives
/// and therefore nothing recomputes. The due date stays fully derived; the
/// snooze simply becomes one more *input* to the derivation, alongside the
/// schedule and the completion log. Recomputation is then still a pure function
/// of stored facts, and still converges on a second run.
///
/// That is also what keeps ADR 0007's promise that snoozing a fixed schedule
/// leaves its rule alone: the `rrule` is never touched, the occurrences it
/// generates never move, and the snooze sits on top of the occurrence the rule
/// already produced.
///
/// ## When a snooze stops applying
///
/// A snooze is spent by the work being done. [effectiveDueDate] drops it once
/// the last completion is at or after [snoozedAt] — the completion is the newer
/// statement, and the schedule takes over again from there. Nothing is deleted
/// to make that happen, which is what lets undo work: tombstoning the
/// completion (ADR 0004) puts the last completion back before the snooze, and
/// the snooze returns on the next recomputation without ever having been stored
/// twice.
///
/// The comparison is against `completed_at` — when the work happened — rather
/// than when the row was written. A completion back-dated to *before* the
/// snooze therefore leaves the snooze standing, correctly: the snooze is still
/// the most recent thing you said about when you want to see this task.
///
/// ## When a snooze expires
///
/// Nothing fires. The snooze date arrives, the derived due date is simply that
/// date, and the task is due today and then overdue like any other — with its
/// lateness counted from the snooze rather than from the due date it had
/// before, because the snooze is the date it is now late against.
class SnoozeOption {
  const SnoozeOption(this.n, this.unit);

  final int n;
  final IntervalUnit unit;

  /// "3 days", "1 week" — never "tomorrow", which would be a lie whenever the
  /// task being snoozed was not due today.
  String get label => unit.labelFor(n);
}

/// The amounts a task can be pushed out by, in the order they are offered.
const snoozeOptions = <SnoozeOption>[
  SnoozeOption(1, IntervalUnit.day),
  SnoozeOption(3, IntervalUnit.day),
  SnoozeOption(1, IntervalUnit.week),
];

/// The moment a snooze of [n] [unit]s made at [now] pushes a task out to.
///
/// Measured from the later of [now] and [dueDate], so a snooze can only ever
/// move a due date forward: pushing an overdue task out by three days has to
/// mean three days from today, or it would come straight back overdue, and
/// pushing out a task due next month has to mean three days past *that*, or it
/// would be pulled backwards.
///
/// [addInterval] rather than `Duration(days: n)`, because "3 days" is three
/// calendar days: across a spring-forward those are 71 hours, and a fixed
/// duration would land the task an hour early — or, for a task due near
/// midnight, a whole calendar day early.
DateTime snoozedUntilFrom({
  required DateTime now,
  DateTime? dueDate,
  required int n,
  required IntervalUnit unit,
}) {
  final base = (dueDate != null && dueDate.isAfter(now)) ? dueDate : now;
  return addInterval(_wallClock(base), n, unit);
}

/// Whether a stored snooze is still the thing that decides the due date.
///
/// False once the work has been done since — see the class comment on
/// [SnoozeOption].
bool snoozeApplies({
  DateTime? snoozedUntil,
  DateTime? snoozedAt,
  DateTime? lastCompletedAt,
}) {
  if (snoozedUntil == null || snoozedAt == null) return false;
  if (lastCompletedAt == null) return true;
  return snoozedAt.isAfter(lastCompletedAt);
}

/// The due date a task actually has: its schedule's answer, pushed out by a
/// snooze that still applies.
///
/// [scheduled] is what the schedule and the completion log derive on their own
/// — `floatingDueDate` or `fixedDueDate`. The snooze never replaces it, only
/// pushes it later, so a schedule that has already moved past the snooze
/// (because the task was completed, or because a fixed rule's next occurrence
/// is further out) wins and the snooze is quietly inert.
DateTime? effectiveDueDate({
  required DateTime? scheduled,
  DateTime? snoozedUntil,
  DateTime? snoozedAt,
  DateTime? lastCompletedAt,
}) {
  if (!snoozeApplies(
    snoozedUntil: snoozedUntil,
    snoozedAt: snoozedAt,
    lastCompletedAt: lastCompletedAt,
  )) {
    return scheduled;
  }
  if (scheduled == null) return snoozedUntil;
  return scheduled.isAfter(snoozedUntil!) ? scheduled : snoozedUntil;
}

/// Whether the snooze is still holding the task off the list at [now] — which
/// is what makes it worth saying "Snoozed" rather than just showing it as
/// upcoming.
///
/// Goes false the moment the snooze comes due, by calendar day rather than by
/// elapsed hours ([dueStatusFor]): a task snoozed to today is due today, not
/// still snoozed.
bool snoozeHoldsAt({
  required DateTime now,
  DateTime? snoozedUntil,
  DateTime? snoozedAt,
  DateTime? lastCompletedAt,
  required DateTime? scheduled,
}) {
  if (!snoozeApplies(
    snoozedUntil: snoozedUntil,
    snoozedAt: snoozedAt,
    lastCompletedAt: lastCompletedAt,
  )) {
    return false;
  }
  // A snooze the schedule has already overtaken is not holding anything off.
  if (scheduled != null && scheduled.isAfter(snoozedUntil!)) return false;
  return dueStatusFor(snoozedUntil!, now) == DueStatus.upcoming;
}

/// The same wall-clock reading the rest of the app takes off a due date.
///
/// A fixed schedule's due date is a `TZDateTime` in the schedule's own zone
/// (ADR 0010) and is displayed by its digits, so the snooze counts calendar
/// days off those same digits rather than off an instant re-read somewhere
/// else.
DateTime _wallClock(DateTime value) => value.isUtc ? value.toLocal() : value;
