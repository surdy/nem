import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/sync/sync_row.dart';

SyncRow row({
  String id = 'task-1',
  required DateTime clock,
  DateTime? deletedAt,
  String title = 'Replace the water filter',
}) => SyncRow(
  id: id,
  clock: clock,
  deletedAt: deletedAt,
  values: {
    'id': id,
    'title': title,
    'updated_at': clock.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
  },
);

void main() {
  final earlier = DateTime.utc(2026, 6, 15, 9);
  final later = DateTime.utc(2026, 6, 15, 17);

  group('last-write-wins', () {
    test('a row the device has never seen is taken', () {
      expect(
        remoteSupersedes(local: null, remote: row(clock: earlier)),
        isTrue,
      );
    });

    test('the later edit wins, whichever side it is on', () {
      expect(
        remoteSupersedes(
          local: row(clock: earlier, title: 'Old'),
          remote: row(clock: later, title: 'New'),
        ),
        isTrue,
      );
      expect(
        remoteSupersedes(
          local: row(clock: later, title: 'New'),
          remote: row(clock: earlier, title: 'Old'),
        ),
        isFalse,
      );
    });

    test('two devices editing the same task offline converge on the later '
        'edit rather than on whoever reconnects first', () {
      // Both phones start from the same row and both go offline.
      final onThePhone = row(clock: earlier, title: 'Replace the filter');
      final onTheTablet = row(clock: later, title: 'Replace the water filter');

      // The tablet reconnects first and its edit lands.
      expect(localSupersedes(local: onTheTablet, remote: null), isTrue);

      // Then the phone reconnects. Its edit is older, so its push is refused
      // and its next pull takes the tablet's — the outcome does not depend on
      // the order the two of them happened to find a signal in.
      expect(localSupersedes(local: onThePhone, remote: onTheTablet), isFalse);
      expect(remoteSupersedes(local: onThePhone, remote: onTheTablet), isTrue);
    });
  });

  group('a delete beats a stale update', () {
    test('a tombstone wins over a live row with an older clock', () {
      expect(
        remoteSupersedes(
          local: row(clock: earlier),
          remote: row(clock: later, deletedAt: later),
        ),
        isTrue,
      );
    });

    test('a tombstone wins over a live row with a *newer* clock too', () {
      // The case the plain last-write-wins rule gets wrong: you delete a task
      // on one phone, the other is in a basement and renames it an hour later.
      // Timestamps alone would resurrect it.
      final deletedAt = earlier;
      final renamedAt = later;

      expect(
        remoteSupersedes(
          local: row(clock: renamedAt, title: 'Renamed'),
          remote: row(clock: deletedAt, deletedAt: deletedAt),
        ),
        isTrue,
      );
      // And symmetrically: the rename must not be pushable over the delete.
      expect(
        localSupersedes(
          local: row(clock: renamedAt, title: 'Renamed'),
          remote: row(clock: deletedAt, deletedAt: deletedAt),
        ),
        isFalse,
      );
    });

    test('a local tombstone is not undone by a live remote row', () {
      expect(
        remoteSupersedes(
          local: row(clock: earlier, deletedAt: earlier),
          remote: row(clock: later),
        ),
        isFalse,
      );
    });

    test('two tombstones fall back to last-write-wins', () {
      expect(
        remoteSupersedes(
          local: row(clock: later, deletedAt: later),
          remote: row(clock: earlier, deletedAt: earlier),
        ),
        isFalse,
      );
    });
  });

  group('ties', () {
    test('an identical clock goes to the remote, so the two devices converge '
        'in one round', () {
      final local = row(clock: earlier, title: 'Mine');
      final remote = row(clock: earlier, title: 'Theirs');

      expect(remoteSupersedes(local: local, remote: remote), isTrue);
      // The mirror has to agree, or the device would take the remote row on the
      // pull and then push its own back over it on the next drain, forever.
      expect(localSupersedes(local: local, remote: remote), isFalse);
    });

    test('a clock that differs only in sub-second precision still decides', () {
      final a = DateTime.utc(2026, 6, 15, 9, 0, 0, 0, 1);
      final b = DateTime.utc(2026, 6, 15, 9, 0, 0, 0, 2);
      expect(
        remoteSupersedes(
          local: row(clock: a),
          remote: row(clock: b),
        ),
        isTrue,
      );
      expect(
        remoteSupersedes(
          local: row(clock: b),
          remote: row(clock: a),
        ),
        isFalse,
      );
    });
  });

  test('the push rule is exactly the negation of the pull rule', () {
    // Not a tautology worth skipping: `SupabaseSyncTransport` writes the push
    // rule out again as PostgREST filters, and this is the property those
    // filters are checked against.
    final clocks = [earlier, later];
    for (final localClock in clocks) {
      for (final remoteClock in clocks) {
        for (final localDeleted in [true, false]) {
          for (final remoteDeleted in [true, false]) {
            final local = row(
              clock: localClock,
              deletedAt: localDeleted ? localClock : null,
            );
            final remote = row(
              clock: remoteClock,
              deletedAt: remoteDeleted ? remoteClock : null,
            );
            expect(
              localSupersedes(local: local, remote: remote),
              !remoteSupersedes(local: local, remote: remote),
              reason: 'local $local vs remote $remote',
            );
          }
        }
      }
    }
  });

  test('a row is compared in UTC, whatever zone it was built in', () {
    final utc = DateTime.utc(2026, 6, 15, 12);
    final sameMomentLocal = utc.toLocal();
    expect(
      remoteSupersedes(
        local: row(clock: sameMomentLocal),
        remote: row(clock: utc),
      ),
      // Identical moments, so the tie-break applies and the remote stands.
      isTrue,
    );
    expect(
      remoteSupersedes(
        local: row(clock: utc),
        remote: row(clock: sameMomentLocal.subtract(const Duration(hours: 1))),
      ),
      isFalse,
    );
  });
}
