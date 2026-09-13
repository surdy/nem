import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/sync/sync_cursor.dart';
import 'package:nem/src/sync/sync_settings.dart';

void main() {
  group('the settings themselves', () {
    test('a fresh install has no backend, and that is not an error', () {
      const settings = SyncSettings();
      expect(settings.isConfigured, isFalse);
      expect(settings.normalisedUrl, isNull);
    });

    test('both halves are needed', () {
      expect(
        const SyncSettings(url: 'https://nem.supabase.co').isConfigured,
        isFalse,
      );
      expect(const SyncSettings(anonKey: 'key').isConfigured, isFalse);
      expect(
        const SyncSettings(
          url: 'https://nem.supabase.co',
          anonKey: 'key',
        ).isConfigured,
        isTrue,
      );
    });

    test('a self-hosted instance on a plain host and port is usable', () {
      // The whole point of ADR 0002: this is a field edit, not a new build.
      const settings = SyncSettings(
        url: 'http://192.168.1.40:8000/',
        anonKey: 'key',
      );
      expect(settings.isConfigured, isTrue);
      expect(settings.normalisedUrl, 'http://192.168.1.40:8000');
    });

    test('a trailing slash is trimmed, so the same backend typed two ways is '
        'the same backend', () {
      expect(
        const SyncSettings(url: 'https://nem.supabase.co/').normalisedUrl,
        const SyncSettings(url: 'https://nem.supabase.co').normalisedUrl,
      );
    });

    test('a URL nem cannot use is rejected here rather than at the first '
        'timeout', () {
      for (final url in [
        'nem.supabase.co',
        'not a url',
        'ftp://nem.supabase.co',
        'https://',
      ]) {
        expect(
          SyncSettings(url: url, anonKey: 'key').isConfigured,
          isFalse,
          reason: url,
        );
      }
    });
  });

  group('storage', () {
    late NemDatabase db;
    late SyncSettingsRepository repository;

    setUp(() {
      db = NemDatabase(NativeDatabase.memory());
      repository = SyncSettingsRepository(db);
    });

    tearDown(() => db.close());

    test('round-trips, and starts empty', () async {
      expect(await repository.read(), const SyncSettings());

      const settings = SyncSettings(
        url: '  https://nem.supabase.co  ',
        anonKey: ' key ',
      );
      await repository.write(settings);

      expect(
        await repository.read(),
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
    });

    test('a cursor is kept per table', () async {
      final cursor = SyncCursor(clock: DateTime.utc(2026, 6, 1), id: 'task-1');
      await repository.writeCursor('tasks', cursor);

      expect(await repository.cursor('tasks'), cursor);
      expect(await repository.cursor('completions'), isNull);
    });

    test('forgetting progress drops the cursors and the seed marker, and '
        'nothing else', () async {
      await repository.write(
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
      await repository.writeCursor(
        'tasks',
        SyncCursor(clock: DateTime.utc(2026, 6, 1), id: 'task-1'),
      );
      await repository.markSeeded('https://nem.supabase.co');

      await repository.forgetProgress(['tasks']);

      expect(await repository.cursor('tasks'), isNull);
      expect(await repository.seededFor(), isNull);
      // The backend itself survives: changing where nem replicates to is not a
      // reason to forget where it replicates to.
      expect((await repository.read()).url, 'https://nem.supabase.co');
    });

    test('the settings stream sees a write', () async {
      final settings = repository.watch();
      await repository.write(
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
      expect(
        await settings.firstWhere((value) => value.isConfigured),
        const SyncSettings(url: 'https://nem.supabase.co', anonKey: 'key'),
      );
    });
  });
}
