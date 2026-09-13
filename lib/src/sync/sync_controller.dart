import 'dart:async';

import 'sync_engine.dart';

/// The shortest and longest a failed sync waits before trying again.
const _firstRetry = Duration(seconds: 15);
const _longestRetry = Duration(minutes: 10);

/// How long to wait before retrying a sync that failed [attempts] times.
///
/// Doubling, capped. nem has no connectivity plugin and does not want one: the
/// question "is there a network" is only ever answered by trying, and a phone
/// that reports a connected wifi with a captive portal in front of it would lie
/// about it anyway. So "drains when connectivity returns" is a retry that keeps
/// asking, backing off to once every ten minutes so a week in a cellar costs
/// about a thousand failed requests rather than half a million.
///
/// Pure, so the curve is a test rather than a stopwatch.
Duration nextRetryDelay(int attempts) {
  if (attempts <= 0) return _firstRetry;
  final doubled = _firstRetry * (1 << attempts.clamp(0, 16));
  return doubled > _longestRetry ? _longestRetry : doubled;
}

/// What the settings screen says about sync, and what the retry timer is for.
class SyncStatus {
  const SyncStatus({
    this.isConfigured = false,
    this.account,
    this.isSyncing = false,
    this.pending = 0,
    this.lastSyncedAt,
    this.lastError,
    this.isAuthFailure = false,
  });

  /// Whether a base URL and anon key are set.
  final bool isConfigured;

  /// The signed-in email, or null.
  final String? account;

  final bool isSyncing;

  /// Rows waiting in the outbox.
  final int pending;

  final DateTime? lastSyncedAt;

  /// The last failure's message, cleared by the next success.
  final String? lastError;

  /// Whether that failure was "not you" rather than "not now".
  final bool isAuthFailure;

  bool get isSignedIn => account != null;

  /// Whether sync can actually run: configured, and signed in.
  bool get isReady => isConfigured && isSignedIn;

  SyncStatus copyWith({
    bool? isConfigured,
    String? account,
    bool clearAccount = false,
    bool? isSyncing,
    int? pending,
    DateTime? lastSyncedAt,
    String? lastError,
    bool clearError = false,
    bool? isAuthFailure,
  }) => SyncStatus(
    isConfigured: isConfigured ?? this.isConfigured,
    account: clearAccount ? null : (account ?? this.account),
    isSyncing: isSyncing ?? this.isSyncing,
    pending: pending ?? this.pending,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    lastError: clearError ? null : (lastError ?? this.lastError),
    isAuthFailure: clearError ? false : (isAuthFailure ?? this.isAuthFailure),
  );
}

/// Runs syncs, and decides when to run the next one.
///
/// Deliberately free of any "is there a network" question — see
/// [nextRetryDelay]. The triggers are: app launch, every foreground
/// (`app.dart`), a settings change, a sign-in, the Sync now button, and a
/// backoff timer that only exists while something is waiting to be pushed.
///
/// Everything it can do with no backend configured is nothing, quietly. A
/// device that has never signed in creates no client, arms no timer and makes
/// no request (ADR 0001).
class SyncRunner {
  SyncRunner({required this.engine, this.onStatus, this.clock = DateTime.now});

  /// Null when nem has no backend configured, which is the ordinary state.
  final SyncEngine? engine;

  /// Called whenever the status changes, so a provider can publish it.
  final void Function(SyncStatus)? onStatus;

  /// The wall clock, so a test can pin what `lastSyncedAt` reads.
  final DateTime Function() clock;

  Timer? _retry;
  int _failures = 0;
  bool _running = false;
  SyncStatus _status = const SyncStatus();

  SyncStatus get status => _status;

  /// Pushes and pulls once, and arms a retry if anything is still waiting.
  ///
  /// Never throws and never runs twice at once: a foreground that lands while a
  /// launch sync is still in flight returns the sync already running rather
  /// than starting a second drain over the same outbox.
  Future<SyncReport?> syncNow({String? account}) async {
    final engine = this.engine;
    if (engine == null) {
      _publish(
        const SyncStatus().copyWith(isConfigured: false, clearAccount: true),
      );
      return null;
    }
    if (_running) return null;
    _running = true;
    _cancelRetry();
    _publish(
      _status.copyWith(
        isConfigured: true,
        account: account,
        clearAccount: account == null,
        isSyncing: true,
      ),
    );

    try {
      await engine.seed(now: clock());
      final report = await engine.sync();
      if (report.isComplete) {
        _failures = 0;
        _publish(
          _status.copyWith(
            isSyncing: false,
            pending: report.pending,
            lastSyncedAt: clock(),
            clearError: true,
          ),
        );
      } else {
        _failures++;
        _publish(
          _status.copyWith(
            isSyncing: false,
            pending: report.pending,
            lastError: report.failure!.message,
            isAuthFailure: report.failure!.isAuthFailure,
          ),
        );
        // An expired token is not a network that is about to come back — the
        // user has to sign in again — so retrying on a timer would be a loop
        // that never succeeds and a battery that never recovers.
        if (!report.failure!.isAuthFailure) _armRetry();
      }
      return report;
    } on Object catch (error) {
      // The engine only throws for things that are wrong rather than absent — a
      // malformed row, a column the backend does not have. Retrying will not
      // help, so the failure is shown and left.
      _failures++;
      _publish(_status.copyWith(isSyncing: false, lastError: '$error'));
      return null;
    } finally {
      _running = false;
    }
  }

  void dispose() => _cancelRetry();

  void _armRetry() {
    _cancelRetry();
    if (_status.pending == 0) return;
    _retry = Timer(
      nextRetryDelay(_failures),
      () => syncNow(account: _status.account),
    );
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  void _publish(SyncStatus status) {
    _status = status;
    onStatus?.call(status);
  }
}
