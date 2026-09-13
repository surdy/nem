import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/photos/image_source_gateway.dart';
import 'package:nem/src/photos/photo_cache.dart';
import 'package:nem/src/photos/photo_providers.dart';
import 'package:nem/src/photos/photo_repository.dart';
import 'package:nem/src/ui/task_photos.dart';

import '../photos/fake_image_source.dart';

/// The reference photo strip on a task (#15).
///
/// Nothing here has a camera, a network, a Supabase project or a bucket. The
/// picker is [FakeImageSource] and the cache is a temporary directory, which
/// between them cover everything the screen actually decides: that a photo is
/// attached to a *task* and to nothing else, that it is written before any
/// network is asked about it, and that a transfer which failed says so rather
/// than disappearing.
void main() {
  late NemDatabase db;
  late TaskRepository tasks;
  late Directory root;
  late PhotoRepository photos;
  late FakeImageSource picker;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    root = await Directory.systemTemp.createTemp('nem-task-photos');
    photos = PhotoRepository(db: db, cache: PhotoCache(Future.value(root)));
    picker = FakeImageSource();
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Alternates real time and pumps until the work a tap started has landed.
  ///
  /// Real work does not complete on the fake clock a widget test runs on
  /// (`runAsync` is the only place it can), and the work here is a chain —
  /// write the file, then the row, then the outbox and queue entries — so each
  /// link needs a pump in the fake zone before the next real wait can reach the
  /// one after it. `pump` rather than `pumpAndSettle`: settling asks for a
  /// quiet frame, and a tree over a drift stream that is still being written to
  /// does not have one to give.
  Future<void> letTheDiskCatchUp(WidgetTester tester) async {
    for (var round = 0; round < 30; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  /// Opens the add sheet and picks one of its two origins.
  ///
  /// The sheet's future resolves only once its close animation has run, which
  /// is fake time and so has to be pumped; what the handler does *after* that
  /// is a file write, which is real time and so has to be given real time. The
  /// two alternate below for exactly that reason.
  Future<void> addPhoto(WidgetTester tester, Key origin) async {
    await tester.tap(find.byKey(const Key('add-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(origin));
    await tester.pumpAndSettle();
    await letTheDiskCatchUp(tester);
  }

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<String> taskId() async {
    final task = await tasks.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  Future<void> pump(WidgetTester tester, String id) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          photoCacheProvider.overrideWithValue(PhotoCache(Future.value(root))),
          imageSourceProvider.overrideWithValue(picker),
          // No backend at all, which is the ordinary state (ADR 0001) and the
          // one the whole screen has to work in. Overridden rather than left
          // alone because the storage seam watches `supabaseClientProvider`.
          photoStorageProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: TaskPhotosSection(taskId: id)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a task with no photos offers to add one', (tester) async {
    await pump(tester, await taskId());

    expect(find.text('REFERENCE PHOTOS'), findsOneWidget);
    expect(find.byKey(const Key('add-photo')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('taking one asks the camera and puts it on the strip', (
    tester,
  ) async {
    final id = await taskId();
    await pump(tester, id);

    await addPhoto(tester, const Key('photo-from-camera'));

    // The sheet asked the camera rather than the library, and the strip grew a
    // tile — the row and the file are both on this device now, with nothing
    // uploaded and no network asked about it. Attaching a photo works in a
    // cellar (ADR 0001).
    expect(picker.picks, [PhotoOrigin.camera]);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const Key('add-photo')), findsOneWidget);

    // What exactly is written, and in what order, is `photo_repository_test`'s
    // subject: a repository test can await the write, where a widget test has
    // to hand real time to a real disk through `runAsync` and cannot then ask
    // the database anything until it has finished.
    await unmount(tester);
  });

  testWidgets('a dismissed picker attaches nothing', (tester) async {
    final id = await taskId();
    picker.bytes = null;
    await pump(tester, id);

    await addPhoto(tester, const Key('photo-from-library'));

    expect(picker.picks, [PhotoOrigin.library]);
    expect(await photos.photosForTask(id), isEmpty);
    await unmount(tester);
  });

  testWidgets('a photo the other device has not uploaded says so rather than '
      'showing a hole', (tester) async {
    final id = await taskId();
    // What a pull leaves behind: a row, no key, no bytes here.
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: 'photo-far',
            taskId: id,
            createdAt: DateTime(2026, 6, 2, 9),
            updatedAt: DateTime(2026, 6, 2, 9),
          ),
        );

    await pump(tester, id);

    expect(find.text('Waiting for the other device'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failed upload is surfaced with its own words and a way to '
      'try again', (tester) async {
    final id = await taskId();
    // Attaching writes a file, which is real work and so has to happen outside
    // the fake clock.
    final photo = (await tester.runAsync(
      () => photos.attachPhoto(
        taskId: id,
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        now: DateTime(2026, 6, 2, 9),
      ),
    ))!;
    await photos.transfers.recordFailure(photo.id, 'storage is unreachable');

    await pump(tester, id);

    // Never silently dropped (#15): the tile says it failed, the line under
    // the strip says why, and the queue entry is still there to be retried.
    expect(find.text('Upload failed — retrying'), findsOneWidget);
    expect(find.textContaining('storage is unreachable'), findsOneWidget);
    expect(find.byKey(const Key('photo-retry')), findsOneWidget);
    expect(await photos.transfers.count(), 1);

    await unmount(tester);
  });

  testWidgets('removing one tombstones it and drops the file', (tester) async {
    final id = await taskId();
    final photo = (await tester.runAsync(
      () => photos.attachPhoto(
        taskId: id,
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        now: DateTime(2026, 6, 2, 9),
      ),
    ))!;
    final fileName = photo.localPath!;

    await pump(tester, id);

    await tester.tap(find.byKey(ValueKey('photo-${photo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-photo')));
    await tester.pumpAndSettle();
    await letTheDiskCatchUp(tester);

    expect(await photos.photosForTask(id), isEmpty);
    expect((await photos.photo(photo.id))!.isDeleted, isTrue);
    expect(await photos.cache.contains(fileName), isFalse);
    // Nothing was ever uploaded, so the queued upload is cancelled rather than
    // left to put bytes in a bucket nothing will come back for.
    expect(await photos.transfers.count(), 0);

    await unmount(tester);
  });
}
