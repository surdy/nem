import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/sync/sync_engine.dart';

/// The one thing realtime asks of the backend, checked against the one thing it
/// listens to (#13).
///
/// A table that sync moves but the publication does not name is the quietest
/// failure this feature has: the channel subscribes successfully, reports
/// `subscribed`, and then simply never fires for that table. Nothing on the
/// device can notice — the pull still works, so the only symptom is that one
/// kind of change is slow and the others are instant.
///
/// It is a failure #14 would already have caused had #13 landed first: two
/// tables were added to `defaultSyncedTables` while this file sat in
/// `supabase/migrations`, and nothing but this test connects the two.
///
/// This reads the SQL rather than a real Postgres. Whether the publication then
/// does what the comments in it say is not something this machine can answer —
/// there is no Docker, no Supabase CLI and no project here.
void main() {
  test('the realtime publication names every table sync moves', () {
    final db = NemDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final migrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('_realtime_publication.sql'))
        .toList();
    expect(
      migrations,
      hasLength(1),
      reason: 'exactly one migration publishes the synced tables',
    );
    final sql = migrations.single.readAsStringSync();

    for (final table in defaultSyncedTables(db)) {
      expect(
        sql,
        contains("'${table.name}'"),
        reason:
            '${table.name} is synced but never added to supabase_realtime, so '
            'a change to it would reach the other phone only on the next '
            'foreground',
      );
    }
  });

  test('the publication is applied after the tables it names exist', () {
    final files =
        Directory('supabase/migrations')
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .toList()
          ..sort();

    // `supabase/README.md` says to paste the migrations in filename order, and
    // `alter publication … add table` needs the table to be there already. So
    // the publication has to sort last, and has to be re-dated rather than
    // edited in place whenever a later migration adds a synced table.
    expect(files.last, endsWith('_realtime_publication.sql'));
  });
}
