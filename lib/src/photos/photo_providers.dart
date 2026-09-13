import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../sync/sync_providers.dart';
import 'image_source_gateway.dart';
import 'photo.dart';
import 'photo_cache.dart';
import 'photo_repository.dart';
import 'photo_storage.dart';
import 'photo_sync.dart';
import 'photo_transfer_queue.dart';
import 'supabase_photo_storage.dart';

/// Photos' providers, kept next to the code they wire rather than in
/// `app/providers.dart`, the way sync keeps its own.
///
/// Everything to do with *bytes on a server* resolves to "nothing to do" on a
/// device with no backend configured, which is the default. Everything to do
/// with bytes on the phone works regardless: attaching a photo, seeing it and
/// deleting it need no account, no network and no Supabase project at all
/// (ADR 0001).

/// Where photo bytes live on this device.
final photoCacheProvider = Provider<PhotoCache>(
  (ref) => PhotoCache.applicationSupport(),
);

final photoRepositoryProvider = Provider<PhotoRepository>(
  (ref) => PhotoRepository(
    db: ref.watch(databaseProvider),
    cache: ref.watch(photoCacheProvider),
  ),
);

final photoTransferQueueProvider = Provider<PhotoTransferQueue>(
  (ref) => ref.watch(photoRepositoryProvider).transfers,
);

/// One task's photos, live, each with its file and its pending byte work.
final taskPhotosProvider = StreamProvider.family<List<TaskPhoto>, String>(
  (ref, taskId) =>
      ref.watch(photoRepositoryProvider).watchPhotosForTask(taskId),
);

/// How many photos are waiting on a network.
final pendingPhotoTransfersProvider = StreamProvider<int>(
  (ref) => ref.watch(photoTransferQueueProvider).watchCount(),
);

/// The three Storage requests photos make, or null when there is nowhere to
/// make them.
///
/// The seam a test replaces with `FakePhotoStorage`, and the exact counterpart
/// of `syncTransportProvider` — including the second thing that provider is
/// for. Watching `supabaseClientProvider` is what *opens* a Supabase client,
/// timers and all, so a widget test that has a URL in its settings and means to
/// stay offline has to override this as well as the transport. Overriding it is
/// therefore not a convenience; it is how a test says "no backend" to the
/// bytes, the way overriding the transport says it to the rows.
final photoStorageProvider = Provider<PhotoStorage?>((ref) {
  final client = ref.watch(supabaseClientProvider).value;
  return client == null ? null : SupabasePhotoStorage(client);
});

/// The bytes' drain, or null when there is nowhere to send them.
///
/// Mirrors `syncEngineProvider`: no storage means no [PhotoSync] and therefore
/// no attempt to move a byte anywhere.
final photoSyncProvider = Provider<PhotoSync?>((ref) {
  final storage = ref.watch(photoStorageProvider);
  if (storage == null) return null;
  return PhotoSync(
    db: ref.watch(databaseProvider),
    photos: ref.watch(photoRepositoryProvider),
    storage: storage,
  );
});

/// The camera and the photo library, behind the seam every test replaces.
final imageSourceProvider = Provider<ImageSourceGateway>(
  (ref) => ImagePickerGateway(),
);
