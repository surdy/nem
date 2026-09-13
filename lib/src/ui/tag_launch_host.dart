import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/clock.dart';
import '../app/providers.dart';
import '../domain/scan.dart';
import 'scan_outcome.dart';

/// Listens for a tag tapped outside the scan screen, and resolves it there and
/// then (#9).
///
/// Wrapped around the app's home rather than made a route of its own, because
/// tapping a tag is not a destination: it resolves to a completion with an
/// undo, a sheet, a target screen or an offer to bind, and only one of those
/// four is a screen. Sitting under the navigator and over the home shell gives
/// it the one thing it needs — a context that can push, present a sheet and
/// reach the app's messenger — without adding a route table to a
/// `MaterialApp(home:)` that has never had one.
///
/// Both halves of Android's launch path come through here. A tap that started
/// nem from closed arrives as the URI the platform was holding; a tap while nem
/// is running arrives on the stream. Neither re-enters the scan flow from the
/// top: the same [ScanResolver] and the same [presentScanOutcome] the scan
/// screen uses do the work, so a tapped tag and a raised camera cannot drift
/// apart.
///
/// Android only in practice, and ADR 0009 chose that: on iOS the gateway never
/// emits and nem continues to need opening first.
class TagLaunchHost extends ConsumerStatefulWidget {
  const TagLaunchHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TagLaunchHost> createState() => _TagLaunchHostState();
}

class _TagLaunchHostState extends ConsumerState<TagLaunchHost> {
  StreamSubscription<String>? _taps;

  /// Set while an outcome is being carried out, so a tag read twice by the
  /// hardware cannot stack two sheets. The thirty-second window is the other
  /// half of this and the durable one; this is only about overlap.
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    final launches = ref.read(tagLaunchGatewayProvider);
    _taps = launches.uris.listen(_onUri);
    // After the first frame: a cold launch runs this before the navigator this
    // outcome has to be presented into exists.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final uri = await launches.takeLaunchUri();
      if (uri != null) await _onUri(uri);
    });
  }

  @override
  void dispose() {
    unawaited(_taps?.cancel());
    super.dispose();
  }

  Future<void> _onUri(String uri) async {
    if (!mounted || _handling) return;
    _handling = true;
    try {
      // Read through the NFC hardware, always: this path is Android's NDEF
      // dispatch and nothing else can reach it. The reader is what makes the
      // same `nem://t/<uuid>` a tag here and a label in front of the camera
      // (ADR 0009) — and what makes the completion record the right source.
      final outcome = await ref
          .read(scanResolverProvider)
          .resolve(uri, reader: ScanReader.nfc, now: ref.read(clockProvider)());
      if (!mounted) return;
      // No `dismiss`: there is no scan screen to take down. A tap that launched
      // nem lands on the due list, which is where the completion shows up.
      await presentScanOutcome(context, ref, outcome);
    } finally {
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
