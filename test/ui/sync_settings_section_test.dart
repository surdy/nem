import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/sync_providers.dart';
import 'package:nem/src/sync/sync_settings.dart';
import 'package:nem/src/sync/sync_transport.dart';
import 'package:nem/src/ui/sync_settings_section.dart';

import '../sync/fake_sync_transport.dart';
import '../sync/task_rows.dart';

void main() {
  late NemDatabase db;
  late SyncSettingsRepository settings;
  late FakeSyncTransport transport;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    settings = SyncSettingsRepository(db);
    transport = FakeSyncTransport();
  });

  tearDown(() => db.close());

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  /// [account] stands in for a signed-in session, which is the one thing on
  /// this section that cannot be reached without a Supabase project.
  Future<void> pump(
    WidgetTester tester, {
    String? account,
    bool withTransport = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (withTransport)
            syncTransportProvider.overrideWithValue(transport)
          else
            syncTransportProvider.overrideWithValue(null),
          syncAccountProvider.overrideWith((ref) => Stream.value(account)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncSettingsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with no backend it offers the fields and says sync is '
      'optional', (tester) async {
    await pump(tester, withTransport: false);

    expect(find.text('SYNC'), findsOneWidget);
    expect(find.byKey(const Key('sync-url')), findsOneWidget);
    expect(find.byKey(const Key('sync-anon-key')), findsOneWidget);
    // ADR 0001: no account is a supported state, not a missing step.
    expect(
      find.textContaining('works fully without an account'),
      findsOneWidget,
    );
    // And nothing about sign-in or syncing is offered until there is somewhere
    // to sign in to.
    expect(find.byKey(const Key('sync-email')), findsNothing);
    expect(find.text('Sync now'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the stored backend is shown', (tester) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );

    await pump(tester);

    expect(find.text('https://nem.supabase.co'), findsOneWidget);
    expect(find.text('a-key'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('saving a URL and key stores them', (tester) async {
    await pump(tester, withTransport: false);

    await tester.enterText(
      find.byKey(const Key('sync-url')),
      'https://self-hosted.example:8000/',
    );
    await tester.enterText(find.byKey(const Key('sync-anon-key')), 'a-key');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    // ADR 0002: swapping to a self-hosted instance is this, and nothing else.
    expect(
      await settings.read(),
      const SyncSettings(
        url: 'https://self-hosted.example:8000/',
        anonKey: 'a-key',
      ),
    );

    await unmount(tester);
  });

  testWidgets('a URL nem cannot use is refused with a reason', (tester) async {
    await pump(tester, withTransport: false);

    await tester.enterText(
      find.byKey(const Key('sync-url')),
      'nem.supabase.co',
    );
    await tester.enterText(find.byKey(const Key('sync-anon-key')), 'a-key');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    expect(find.textContaining('needs http:// or https://'), findsOneWidget);
    expect((await settings.read()).isConfigured, isFalse);

    await unmount(tester);
  });

  testWidgets('a URL with no key is refused', (tester) async {
    await pump(tester, withTransport: false);

    await tester.enterText(
      find.byKey(const Key('sync-url')),
      'https://nem.supabase.co',
    );
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    expect(find.textContaining('anon key is needed'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('clearing both fields takes the backend away again', (
    tester,
  ) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );
    await pump(tester);

    await tester.enterText(find.byKey(const Key('sync-url')), '');
    await tester.enterText(find.byKey(const Key('sync-anon-key')), '');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    expect((await settings.read()).isConfigured, isFalse);

    await unmount(tester);
  });

  testWidgets('a configured backend offers a magic link, not a password', (
    tester,
  ) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );

    await pump(tester);

    expect(find.byKey(const Key('sync-email')), findsOneWidget);
    expect(find.text('Send magic link'), findsOneWidget);
    expect(find.text('Not signed in'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a signed-in account is named, with a way out', (tester) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );

    await pump(tester, account: 'someone@example.com');

    expect(find.text('someone@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byKey(const Key('sync-email')), findsNothing);

    await unmount(tester);
  });

  testWidgets('what is waiting to be sent is shown, and Sync now sends it', (
    tester,
  ) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );
    await TaskRepository(db).createFloatingTask(
      title: 'Water the plants',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9),
    );

    await pump(tester, account: 'someone@example.com');
    expect(find.text('1 change waiting to be sent'), findsOneWidget);

    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(transport.tables['tasks'], hasLength(1));
    expect(find.text('Everything is sent'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a failed sync says what went wrong and keeps the work', (
    tester,
  ) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );
    await TaskRepository(db).createFloatingTask(
      title: 'Water the plants',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9),
    );
    transport.failure = const SyncTransportFailure('no route to host');

    await pump(tester, account: 'someone@example.com');
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(find.text('no route to host'), findsOneWidget);
    expect(find.text('1 change waiting to be sent'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an expired session asks for a new sign-in rather than a '
      'retry', (tester) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );
    await TaskRepository(db).createFloatingTask(
      title: 'Water the plants',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
      now: DateTime(2026, 6, 1, 9),
    );
    transport.failure = const SyncTransportFailure(
      'JWT expired',
      isAuthFailure: true,
    );

    await pump(tester, account: 'someone@example.com');
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sign in again'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('Sync now brings down what the other device wrote', (
    tester,
  ) async {
    await settings.write(
      const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'a-key'),
    );
    transport.seed(
      'tasks',
      remoteTaskJson(
        id: 'from-the-tablet',
        title: 'Bleed the radiators',
        updatedAt: DateTime(2026, 6, 2, 9),
      ),
    );

    await pump(tester, account: 'someone@example.com');
    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(
      (await TaskRepository(db).allTasks()).single.title,
      'Bleed the radiators',
    );

    await unmount(tester);
  });
}
