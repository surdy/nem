import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/providers.dart';
import 'outbox_store.dart';
import 'realtime_sync.dart';
import 'supabase_connection.dart';
import 'supabase_sync_channel.dart';
import 'supabase_sync_transport.dart';
import 'sync_channel.dart';
import 'sync_controller.dart';
import 'sync_engine.dart';
import 'sync_settings.dart';
import 'sync_transport.dart';

/// Sync's providers, kept next to the code they wire rather than in
/// `app/providers.dart`, the way `clock.dart` keeps its own.
///
/// Every one of them resolves to "nothing to do" on a device with no backend
/// configured, which is the default and the state nem is designed to be whole
/// in (ADR 0001). No client is constructed, no request is made and no timer is
/// armed until a URL and an anon key are typed into the settings screen — which
/// is also why the existing widget tests need no overrides here.

final syncSettingsRepositoryProvider = Provider<SyncSettingsRepository>(
  (ref) => SyncSettingsRepository(ref.watch(databaseProvider)),
);

/// The stored base URL and anon key, live (ADR 0002).
final syncSettingsProvider = StreamProvider<SyncSettings>(
  (ref) => ref.watch(syncSettingsRepositoryProvider).watch(),
);

/// Owns the one Supabase instance; see [SupabaseConnection].
final supabaseConnectionProvider = Provider<SupabaseConnection>((ref) {
  final connection = SupabaseConnection();
  ref.onDispose(connection.close);
  return connection;
});

/// The live client, or null when there is no backend configured.
///
/// Rebuilt when the settings change, which is what makes the self-hosted swap a
/// field edit rather than a new build.
final supabaseClientProvider = FutureProvider<SupabaseClient?>((ref) async {
  final settings = await ref.watch(syncSettingsProvider.future);
  return ref.watch(supabaseConnectionProvider).open(settings);
});

/// The three requests sync makes, or null when there is nowhere to make them.
///
/// The seam tests replace (`FakeSyncTransport`), exactly as
/// [digestNotifierProvider] is replaced for notifications and
/// [tagGatewayProvider] for NFC.
final syncTransportProvider = Provider<SyncTransport?>((ref) {
  final client = ref.watch(supabaseClientProvider).value;
  return client == null ? null : SupabaseSyncTransport(client);
});

/// The realtime subscription, or null when there is nowhere to subscribe to.
///
/// The second seam tests replace, alongside [syncTransportProvider] — see
/// [SyncChannel], which carries why realtime is a doorbell rather than a second
/// way into the database.
final syncChannelProvider = Provider<SyncChannel?>((ref) {
  final client = ref.watch(supabaseClientProvider).value;
  if (client == null) return null;
  return SupabaseSyncChannel(
    client,
    // Whatever sync moves, realtime listens to. Registering a table in
    // `defaultSyncedTables` stays the whole job of adding it.
    tables: [
      for (final table in defaultSyncedTables(ref.watch(databaseProvider)))
        table.name,
    ],
  );
});

/// Turns "the backend changed" into the same sync every other trigger runs.
///
/// Held open by `app.dart`, which starts it on the first build and on every
/// foreground, and stops it when nem goes into the background. Rebuilt whenever
/// the backend changes underneath it, which disposes — and so closes — the
/// subscription that was pointed at the old one.
final realtimeSyncProvider = Provider<RealtimeSync>((ref) {
  final realtime = RealtimeSync(
    channel: ref.watch(syncChannelProvider),
    // The one entry point, exactly as `app.dart` and `main.dart` use: realtime
    // decides *when*, and never *what*.
    pull: () => ref.read(syncStatusProvider.notifier).sync(),
  );
  ref.onDispose(realtime.stop);
  return realtime;
});

final outboxStoreProvider = Provider<OutboxStore>(
  (ref) => OutboxStore(ref.watch(databaseProvider)),
);

/// How many local changes are waiting to be pushed.
final outboxPendingProvider = StreamProvider<int>(
  (ref) => ref.watch(outboxStoreProvider).watchCount(),
);

final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final transport = ref.watch(syncTransportProvider);
  if (transport == null) return null;
  return SyncEngine(
    db: ref.watch(databaseProvider),
    transport: transport,
    settings: ref.watch(syncSettingsRepositoryProvider),
    tasks: ref.watch(taskRepositoryProvider),
  );
});

/// The signed-in account's email, or null.
///
/// Starts with whatever session was recovered from disk, then follows
/// `onAuthStateChange` — which is how the screen notices that a magic link
/// opened in the mail app has come back and completed the sign-in.
final syncAccountProvider = StreamProvider<String?>((ref) async* {
  final client = ref.watch(supabaseClientProvider).value;
  if (client == null) {
    yield null;
    return;
  }
  yield client.auth.currentSession?.user.email;
  yield* client.auth.onAuthStateChange.map(
    (event) => event.session?.user.email,
  );
});

/// What the settings screen shows, and the one entry point every trigger goes
/// through — launch, foreground, a settings change, a sign-in, the Sync now
/// button, and [SyncRunner]'s own backoff.
///
/// A Notifier rather than a free function because the callers hold different
/// kinds of `ref`: `main.dart` has a `ProviderContainer` and `app.dart` has a
/// `WidgetRef`, and `ref.read(syncStatusProvider.notifier).sync()` is the one
/// call both of them can make.
class SyncStatusStore extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => const SyncStatus();

  void publish(SyncStatus status) => state = status;

  /// Runs a sync, if there is anywhere to sync to.
  ///
  /// Returns having done nothing at all on a device with no backend or no
  /// session, which is the ordinary case and not a failure worth reporting.
  Future<void> sync() async {
    final isConfigured = ref.read(syncTransportProvider) != null;
    if (!isConfigured) {
      state = const SyncStatus();
      return;
    }
    final account = await _account();
    if (account == null) {
      // Configured but not signed in: a URL has been typed in and the magic
      // link has not come back yet.
      state = state.copyWith(isConfigured: true, clearAccount: true);
      return;
    }
    await ref.read(syncRunnerProvider).syncNow(account: account);
  }

  /// The signed-in email, waited for with the provider held open.
  ///
  /// The subscription is the whole point and not a formality. Riverpod 3 pauses
  /// a provider that nothing is listening to, and a paused [StreamProvider]
  /// never subscribes to its stream — so a bare
  /// `ref.read(syncAccountProvider.future)` returns a future that is never
  /// completed by anything, and the sync that awaited it stops there for good.
  /// `ref.read` creates no listener, and neither does reaching this notifier
  /// through `ref.read(syncStatusProvider.notifier)`, which is how every caller
  /// gets here.
  ///
  /// It only ever resolved at all because the settings screen watches the same
  /// provider: with **Settings → Sync** on screen the account is live and the
  /// Sync now button works, and with the due list on screen — launch,
  /// foreground, a realtime nudge (#13) — the identical call waited forever and
  /// said nothing, because a sync that never returns publishes no failure.
  ///
  /// A listener held across the await is what makes the stream run. Closed in a
  /// `finally` so this leaves nothing subscribed: the account is wanted for the
  /// length of one sync, not for the length of the process.
  Future<String?> _account() {
    final subscription = ref.listen(syncAccountProvider, (_, _) {});
    return ref
        .read(syncAccountProvider.future)
        .whenComplete(subscription.close);
  }
}

final syncStatusProvider = NotifierProvider<SyncStatusStore, SyncStatus>(
  SyncStatusStore.new,
);

/// Runs syncs and schedules retries. Rebuilt whenever the backend changes.
final syncRunnerProvider = Provider<SyncRunner>((ref) {
  final runner = SyncRunner(
    engine: ref.watch(syncEngineProvider),
    onStatus: (status) => ref.read(syncStatusProvider.notifier).publish(status),
  );
  ref.onDispose(runner.dispose);
  return runner;
});
