import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../photos/image_source_gateway.dart';
import '../photos/photo.dart';
import '../photos/photo_providers.dart';
import '../sync/sync_providers.dart';

/// The reference photos on a task: what the work actually involves — which
/// filter, which valve, where the stopcock is (CONTEXT.md — "Reference photo").
///
/// On the task and nowhere else. There is no equivalent of this on a
/// completion, and that is the design rather than a gap: nem's photos say what
/// the work *is*, not that it was done.
///
/// Every image drawn here comes off the filesystem. Nothing on this screen
/// fetches anything, so a photo that has been seen once shows in a cellar, on a
/// plane and on a phone that has never had a backend configured at all
/// (ADR 0001).
class TaskPhotosSection extends ConsumerWidget {
  const TaskPhotosSection({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final photos = ref.watch(taskPhotosProvider(taskId)).value ?? const [];
    final failed = [
      for (final p in photos)
        if (p.errorMessage != null) p,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            'REFERENCE PHOTOS',
            style: theme.textTheme.labelLarge?.copyWith(
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(
          height: 136,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final photo in photos)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _PhotoTile(photo: photo),
                ),
              _AddPhotoTile(taskId: taskId),
            ],
          ),
        ),
        // Nothing is ever dropped in silence (issue #15). A transfer that
        // failed keeps its place in the queue and is retried on the sync
        // engine's own backoff; this is where it says so in the meantime, in
        // the failure's own words, with the same "try it now" the settings
        // screen offers.
        if (failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    failed.length == 1
                        ? '1 photo is still waiting: ${failed.single.errorMessage}'
                        : '${failed.length} photos are still waiting: '
                              '${failed.first.errorMessage}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('photo-retry'),
                  onPressed: () => ref.read(syncStatusProvider.notifier).sync(),
                  child: const Text('Try now'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One photo, or the reason there is nothing to show yet.
class _PhotoTile extends ConsumerWidget {
  const _PhotoTile({required this.photo});

  final TaskPhoto photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final label = photo.statusLabel;
    final file = photo.file;

    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: ValueKey('photo-${photo.photo.id}'),
            onTap: () => _open(context, ref),
            borderRadius: BorderRadius.circular(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 96,
                height: 96,
                child: file == null
                    ? ColoredBox(
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: Icon(
                          photo.transfer?.hasFailed ?? false
                              ? Icons.error_outline
                              : Icons.image_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Image.file(
                        file,
                        fit: BoxFit.cover,
                        // A file that is there but unreadable — truncated by a
                        // restore, or not an image at all — must not take the
                        // screen down with it.
                        errorBuilder: (context, _, _) => ColoredBox(
                          color: theme.colorScheme.surfaceContainerHigh,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: photo.transfer?.hasFailed ?? false
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The photo, larger, and the one thing you can do to it.
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Both read *before* the dialog, because removing a photo takes this tile
    // out of the tree: a `ref.read` afterwards is a read through a disposed
    // element, which throws.
    final repository = ref.read(photoRepositoryProvider);
    final sync = ref.read(syncStatusProvider.notifier);
    final file = photo.file;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: const EdgeInsets.all(16),
        content: file == null
            ? Text(photo.statusLabel ?? 'This photo is not on this device yet.')
            : Image.file(file, fit: BoxFit.contain),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
          TextButton(
            key: const Key('remove-photo'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove photo'),
          ),
        ],
      ),
    );
    if (remove != true) return;

    await repository.deletePhoto(photo.photo.id);
    // The object in the bucket goes with it, once the tombstone has been
    // pushed — `PhotoSync.drain` holds that order. Not awaited: removing a
    // photo must not wait on a network, and the queue is durable if there
    // isn't one.
    unawaited(sync.sync());
  }
}

/// The button that adds one.
class _AddPhotoTile extends ConsumerWidget {
  const _AddPhotoTile({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 96,
      child: InkWell(
        key: const Key('add-photo'),
        onTap: () => _add(context, ref),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 96,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add_a_photo_outlined),
                const SizedBox(height: 4),
                Text('Add', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    // Read before the sheet, for the reason `_PhotoTile._open` gives: what
    // follows crosses several awaits and this element may be gone by the end
    // of them.
    final repository = ref.read(photoRepositoryProvider);
    final source = ref.read(imageSourceProvider);
    final sync = ref.read(syncStatusProvider.notifier);
    final origin = await showModalBottomSheet<PhotoOrigin>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('photo-from-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(context).pop(PhotoOrigin.camera),
            ),
            ListTile(
              key: const Key('photo-from-library'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () => Navigator.of(context).pop(PhotoOrigin.library),
            ),
          ],
        ),
      ),
    );
    if (origin == null) return;

    final picked = await source.pick(origin);
    if (picked == null) return;

    // The row and the local file are written here and now; the upload is
    // queued, not awaited. Attaching a photo works with no network, and the
    // photo is on the task the moment it is taken.
    await repository.attachPhoto(
      taskId: taskId,
      bytes: picked.bytes,
      extension: picked.extension,
    );
    unawaited(sync.sync());
  }
}
