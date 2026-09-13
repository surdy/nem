import 'dart:async';

import 'sync_channel.dart';

/// How long a nudge waits for the ones behind it.
///
/// The other phone finishing a session of work pushes a completion, a task and
/// possibly a target within a few hundred milliseconds, and each is its own
/// realtime message. Without this, that is three full syncs over every synced
/// table; with it, it is one. Short enough that "appears on the other phone"
/// still reads as immediate.
const _coalesceWindow = Duration(milliseconds: 250);

/// Realtime as a *trigger*, next to the ones that already exist.
///
/// `SyncRunner` lists nem's triggers: app launch, foreground, a settings change,
/// a sign-in, the Sync now button, and the backoff timer. This adds one more —
/// "the backend says something changed" — and deliberately adds nothing else.
/// The work it triggers is the same push-then-pull every other trigger runs, so
/// there is exactly one path into SQLite, one merge rule and one cursor, and
/// realtime cannot disagree with a pull about which version of a row stands.
/// `sync_channel.dart` argues why it must be this way round.
///
/// What lives here is only the two decisions a doorbell needs:
///
/// * **coalescing**, so a burst of messages is one sync ([_coalesceWindow]);
/// * **not overlapping itself**, so a nudge that lands mid-pull is run once
///   afterwards rather than starting a second pull over the same tables.
///
/// A nudge that lands while some *other* trigger's sync is in flight is
/// dropped by `SyncRunner`'s re-entrancy guard, and that is safe rather than
/// merely tolerable: the running sync either already sees the row, or it does
/// not and leaves the cursor short of it — and a cursor that did not advance is
/// precisely the instruction to fetch that row again next time. Realtime being
/// late is a slower update; it is never a lost one.
class RealtimeSync {
  RealtimeSync({
    required this.channel,
    required this.pull,
    this.coalesceWindow = _coalesceWindow,
  });

  /// Null when nem has no backend configured, which is the ordinary state and
  /// the one where every method here does nothing at all (ADR 0001).
  final SyncChannel? channel;

  /// The sync to run when the bell rings. The app passes the same entry point
  /// every other trigger uses, rather than anything of realtime's own.
  final Future<void> Function() pull;

  final Duration coalesceWindow;

  Timer? _pending;
  bool _isOpen = false;
  bool _isPulling = false;
  bool _pullAgain = false;

  /// Whether the subscription is currently listening.
  bool get isOpen => _isOpen;

  /// Opens the subscription, if there is one to open.
  ///
  /// Idempotent, because it is called from two places that can both be right at
  /// once: the app's first build, and every foreground after a background
  /// closed it.
  Future<void> start() async {
    final channel = this.channel;
    if (channel == null || _isOpen) return;
    _isOpen = true;
    try {
      await channel.open(_ring);
    } on Object {
      // A subscription that will not open must not take sync down with it. The
      // device falls back to exactly what it did before realtime existed —
      // foreground, the Sync now button and the retry timer — which is a
      // slower nem rather than a broken one (ADR 0001).
      _isOpen = false;
    }
  }

  /// Closes the subscription and forgets any nudge that had not fired yet.
  Future<void> stop() async {
    _pending?.cancel();
    _pending = null;
    _pullAgain = false;
    if (!_isOpen) return;
    _isOpen = false;
    try {
      await channel?.close();
    } on Object {
      // Symmetrical with [start], and for a sharper reason: this is called from
      // `AppLifecycleListener.onPause` without being awaited, so a socket that
      // objects to being let go of would otherwise throw into a zone on the way
      // into the background. The channel is forgotten either way, and the one
      // that replaces it on the next foreground is a new one.
    }
  }

  void _ring() {
    if (!_isOpen) return;
    _pending?.cancel();
    _pending = Timer(coalesceWindow, _pullNow);
  }

  Future<void> _pullNow() async {
    _pending = null;
    if (_isPulling) {
      // Ringing again during a pull means a row changed after that pull had
      // already read its table, so the pull cannot be assumed to have seen it.
      _pullAgain = true;
      return;
    }
    _isPulling = true;
    try {
      do {
        _pullAgain = false;
        await pull();
      } while (_pullAgain && _isOpen);
    } on Object {
      // Swallowed because this runs inside a timer callback, where a throw
      // reaches nothing but the zone's error handler. Nothing is hidden by it:
      // a sync that fails publishes the failure through `SyncStatus` and arms
      // its own retry, and that is the report the settings screen shows.
    } finally {
      _isPulling = false;
    }
  }
}
