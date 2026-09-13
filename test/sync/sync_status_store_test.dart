import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/sync/sync_providers.dart';
import 'package:nem/src/sync/sync_settings.dart';

import 'fake_sync_transport.dart';
import 'task_rows.dart';

/// The one entry point every sync trigger goes through.
///
/// It is tested from a container with nothing watching anything, because that
/// is the shape every trigger but one actually has: launch (`main.dart`), the
/// foreground (`app.dart`) and a realtime nudge (#13) all reach it through
/// `ref.read(syncStatusProvider.notifier)` with the due list on screen. Only the
/// **Settings → Sync** button arrives with the account provider already
/// watched, and that difference used to be the difference between a sync that
/// ran and one that waited for ever.
void main() {
  const backend = 'https://nem.supabase.co';
  const account = 'someone@example.com';

  late NemDatabase db;
  late FakeSyncTransport transport;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    transport = FakeSyncTransport();
    await SyncSettingsRepository(
      db,
    ).write(const SyncSettings(url: backend, anonKey: 'public-anon-key'));
  });

  tearDown(() => db.close());

  ProviderContainer containerWith({String? signedInAs}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncTransportProvider.overrideWithValue(transport),
        syncAccountProvider.overrideWith((ref) => Stream.value(signedInAs)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a sync triggered with nobody watching the account still runs',
    () async {
      transport.seed(
        'tasks',
        remoteTaskJson(id: 'theirs', updatedAt: DateTime(2026, 6, 2, 9)),
      );
      final container = containerWith(signedInAs: account);

      // No `watch`, no `listen`, no widget: exactly what `main.dart` does.
      await container.read(syncStatusProvider.notifier).sync();

      // Riverpod 3 pauses a provider nothing is listening to, and a paused
      // `StreamProvider` never subscribes to its stream. So the account this
      // awaits has to be read with a listener held, or this future never
      // completes and the row below never arrives — silently, because a sync
      // that does not return reports no failure either.
      final rows = await db.select(db.tasks).get();
      expect(rows.map((row) => row.id), ['theirs']);
      expect(container.read(syncStatusProvider).account, account);
      expect(container.read(syncStatusProvider).lastError, isNull);
    },
  );

  test('a configured device that is not signed in syncs nothing and says '
      'so', () async {
    final container = containerWith();

    await container.read(syncStatusProvider.notifier).sync();

    final status = container.read(syncStatusProvider);
    expect(status.isConfigured, isTrue);
    expect(status.isSignedIn, isFalse);
    expect(transport.fetches, 0);
  });

  test('a device with no backend configured makes no request', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncTransportProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await container.read(syncStatusProvider.notifier).sync();

    expect(container.read(syncStatusProvider).isConfigured, isFalse);
    expect(transport.fetches, 0);
  });
}
