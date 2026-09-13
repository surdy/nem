import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/sync/realtime_sync.dart';
import 'package:nem/src/sync/sync_controller.dart';
import 'package:nem/src/sync/sync_engine.dart';
import 'package:nem/src/sync/sync_settings.dart';

import 'fake_sync_channel.dart';
import 'fake_sync_transport.dart';
import 'task_rows.dart';

/// Realtime as a trigger (#13).
///
/// Nothing here opens a socket — there is no Supabase project on this machine —
/// so the subscription is [FakeSyncChannel] and dropping it is a method call.
/// What is being tested is the only part nem wrote: that a bell rings a pull,
/// that a burst of bells rings one, and that a socket which missed everything
/// costs nothing because the cursor never needed it.
void main() {
  const backend = 'https://nem.supabase.co';
  const account = 'someone@example.com';

  /// Short, so the coalescing window is a handful of milliseconds rather than a
  /// quarter of a second of waiting per assertion.
  const window = Duration(milliseconds: 5);

  late NemDatabase db;
  late TaskRepository tasks;
  late SyncSettingsRepository settings;
  late FakeSyncTransport transport;
  late FakeSyncChannel channel;
  late SyncRunner runner;
  late RealtimeSync realtime;

  /// Completed pulls, counted after the sync returns so that waiting on it is
  /// waiting for the work rather than for the intention.
  var pulls = 0;

  /// Held open by a test that wants a pull to still be in flight while it does
  /// something else.
  Future<void> Function()? afterSync;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    settings = SyncSettingsRepository(db);
    transport = FakeSyncTransport();
    channel = FakeSyncChannel();
    pulls = 0;
    afterSync = null;
    await settings.write(
      const SyncSettings(url: backend, anonKey: 'public-anon-key'),
    );
    runner = SyncRunner(
      engine: SyncEngine(
        db: db,
        transport: transport,
        settings: settings,
        tasks: tasks,
      ),
      clock: () => DateTime(2026, 6, 15, 9),
    );
    realtime = RealtimeSync(
      channel: channel,
      coalesceWindow: window,
      pull: () async {
        await runner.syncNow(account: account);
        await afterSync?.call();
        pulls++;
      },
    );
  });

  tearDown(() async {
    await realtime.stop();
    runner.dispose();
    await db.close();
  });

  /// Waits for [expected] pulls to have finished, or says how far it got.
  ///
  /// A deadline rather than a fixed sleep: the assertion is "this happens",
  /// and a slow machine should make the test slower rather than red.
  Future<void> waitForPulls(int expected) async {
    final elapsed = Stopwatch()..start();
    while (pulls < expected) {
      if (elapsed.elapsed > const Duration(seconds: 10)) {
        fail('waited for $expected pulls and saw $pulls');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Long enough that a pull would have happened by now — for the assertions
  /// that one did not. Erring long only makes those stronger.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  Future<List<String>> localTaskIds() async {
    final rows = await db.select(db.tasks).get();
    return [for (final row in rows) row.id]..sort();
  }

  void seedRemoteTask(String id, DateTime updatedAt) =>
      transport.seed('tasks', remoteTaskJson(id: id, updatedAt: updatedAt));

  test('with no backend configured there is nothing to subscribe to', () async {
    final subject = RealtimeSync(
      channel: null,
      coalesceWindow: window,
      pull: () async => pulls++,
    );

    await subject.start();
    await settle();

    // The ordinary state of a device that has never signed in (ADR 0001): no
    // socket, no timer, no request.
    expect(subject.isOpen, isFalse);
    expect(pulls, 0);
    await subject.stop();
  });

  test('joining the channel is itself a pull, because nothing was listening '
      'a moment ago', () async {
    seedRemoteTask('theirs', DateTime(2026, 6, 2, 9));

    await realtime.start();
    await waitForPulls(1);

    expect(realtime.isOpen, isTrue);
    expect(channel.opens, 1);
    expect(await localTaskIds(), ['theirs']);
  });

  test('a change on the socket is fetched through the cursored pull, not '
      'applied from the payload', () async {
    await realtime.start();
    await waitForPulls(1);
    final fetchesBefore = transport.fetchesFor('tasks');

    seedRemoteTask('theirs', DateTime(2026, 6, 2, 9));
    channel.deliverChange();
    await waitForPulls(2);

    // The row is here, and it came down a `fetchChanges` — which is the only
    // path there is. The bell carries no row at all: `SyncChannel.open` takes a
    // callback with no argument, so there is nothing for a payload to be
    // applied *from*.
    expect(await localTaskIds(), ['theirs']);
    expect(transport.fetchesFor('tasks'), greaterThan(fetchesBefore));
  });

  test('a burst of changes is one pull', () async {
    await realtime.start();
    await waitForPulls(1);

    // The other phone finishing a session: a completion, the task it
    // rescheduled, and the target it hangs off, all within a few milliseconds.
    for (var i = 0; i < 5; i++) {
      channel.deliverChange();
    }
    await waitForPulls(2);
    await settle();

    expect(pulls, 2, reason: 'five bells, one sync');
  });

  test('the same change arriving twice does not write the row twice', () async {
    await realtime.start();
    await waitForPulls(1);
    seedRemoteTask('theirs', DateTime(2026, 6, 2, 9));

    channel.deliverChange();
    await waitForPulls(2);
    channel.deliverChange();
    await waitForPulls(3);

    expect(await localTaskIds(), ['theirs']);
    // And the second pull had nothing to do: the cursor moved over the row the
    // first one applied, so the backend was not even asked for it again.
    final report = await runner.syncNow(account: account);
    expect(report!.pulled, 0);
    expect(report.rejected, 0);
  });

  test('rows written while the socket was down arrive on the rejoin, once '
      'and only once', () async {
    seedRemoteTask('first', DateTime(2026, 6, 2, 9));
    await realtime.start();
    await waitForPulls(1);
    expect(await localTaskIds(), ['first']);

    // The lift, the tunnel, the router with a flat battery. The channel is
    // still open as far as the app is concerned; it is the socket that has
    // gone, and it says nothing about going.
    channel.drop();
    seedRemoteTask('second', DateTime(2026, 6, 3, 9));
    seedRemoteTask('third', DateTime(2026, 6, 4, 9));
    channel.deliverChange();
    await settle();

    expect(pulls, 1, reason: 'nothing arrives on a socket that is down');
    expect(await localTaskIds(), ['first']);

    // Connectivity comes back. The rejoin is the only notice there is — there
    // is no backfill of what was missed — and it is enough, because the cursor
    // never moved past what was applied.
    channel.reconnect();
    await waitForPulls(2);

    expect(await localTaskIds(), ['first', 'second', 'third']);

    // Nothing lost, and nothing duplicated: the row applied before the drop was
    // not applied again, and the two applied after it left the cursor with
    // nothing behind it.
    final report = await runner.syncNow(account: account);
    expect(report!.pulled, 0);
    expect(report.rejected, 0);
    expect(await localTaskIds(), ['first', 'second', 'third']);
  });

  test('a change that lands while a pull is running is pulled again '
      'afterwards', () async {
    final gate = Completer<void>();
    // The first pull finishes its fetches and then hangs, so the test can be
    // sure the change below lands *after* the tables were read.
    afterSync = () async {
      if (!gate.isCompleted) await gate.future;
    };

    await realtime.start();
    await settle();
    expect(pulls, 0, reason: 'the first pull is still in flight');

    seedRemoteTask('theirs', DateTime(2026, 6, 2, 9));
    channel.deliverChange();
    await settle();
    gate.complete();

    await waitForPulls(2);
    expect(
      await localTaskIds(),
      ['theirs'],
      reason: 'the bell that rang mid-pull was not swallowed by it',
    );
  });

  test('a stopped subscription is closed and rings nothing', () async {
    await realtime.start();
    await waitForPulls(1);

    await realtime.stop();

    expect(realtime.isOpen, isFalse);
    expect(channel.isOpen, isFalse);
    expect(channel.closes, 1);

    seedRemoteTask('theirs', DateTime(2026, 6, 2, 9));
    channel.deliverChange();
    channel.reconnect();
    await settle();

    expect(pulls, 1);
    expect(await localTaskIds(), isEmpty);
  });

  test('stopping cancels a pull that had been rung for but not run', () async {
    await realtime.start();
    await waitForPulls(1);

    channel.deliverChange();
    await realtime.stop();
    await settle();

    expect(pulls, 1, reason: 'no sync fires into a backgrounded app');
  });

  test('starting twice opens one subscription', () async {
    await realtime.start();
    await realtime.start();
    await waitForPulls(1);

    // Both `app.dart`'s first build and its foreground call this, and they can
    // both be right at once.
    expect(channel.opens, 1);
  });

  test(
    'a subscription that will not close leaves the app backgrounding',
    () async {
      final subject = RealtimeSync(
        channel: _UnclosableSyncChannel(),
        coalesceWindow: window,
        pull: () async => pulls++,
      );
      await subject.start();

      // `app.dart` lets go of this on the way into the background without
      // awaiting it, so a throw here would reach nothing but the zone.
      await subject.stop();

      expect(subject.isOpen, isFalse);
    },
  );

  test('a subscription that will not open leaves sync working', () async {
    final subject = RealtimeSync(
      channel: _BrokenSyncChannel(),
      coalesceWindow: window,
      pull: () async => pulls++,
    );
    addTearDown(subject.stop);

    await subject.start();

    // A device with no realtime is the device nem was before #13: foreground,
    // Sync now and the retry timer still work, and nothing was thrown at the
    // caller, which is a widget's `build`.
    expect(subject.isOpen, isFalse);
  });
}

/// A backend where realtime is switched off, a proxy eats websockets, or the
/// client throws for a reason nem cannot do anything about.
class _BrokenSyncChannel extends FakeSyncChannel {
  @override
  Future<void> open(void Function() onChanged) async {
    throw StateError('no socket');
  }
}

/// A channel that objects to being let go of — a socket already gone by the
/// time the app asks to leave it.
class _UnclosableSyncChannel extends FakeSyncChannel {
  @override
  Future<void> close() async {
    throw StateError('already gone');
  }
}
