import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/clock.dart';
import '../app/providers.dart';
import '../domain/barcode.dart';
import '../domain/scan.dart';
import '../nfc/tag_gateway.dart';
import '../nfc/tag_launch.dart';
import 'scan_outcome.dart';

/// Builds the live view scans arrive from, calling back with each raw value.
///
/// Injected so the flow above it can be exercised without a camera: the real
/// builder is a [MobileScanner] preview, and a test supplies something that
/// emits a string on demand. Everything below this typedef — resolution,
/// completion, undo — is the same code either way.
typedef ScanPreviewBuilder =
    Widget Function(BuildContext context, ValueChanged<String> onScanned);

/// The symbologies the camera is asked for.
///
/// QR is nem's own label (ADR 0009). The rest are #10's list of product codes —
/// EAN-8, EAN-13, UPC-A, UPC-E and Code 128 — and `ean13` is load-bearing twice
/// over. It is a symbology in its own right, and it is also the only way UPC-A
/// is seen at all on iOS: Apple's Vision framework has no UPC-A, so asking for
/// `upcA` alone finds nothing there and says nothing about it. The twelve
/// digits arrive as an EAN-13 with a leading zero instead, which
/// [normalisedBarcode] takes back off so that both phones bind the same string.
///
/// Restricting the list rather than leaving it open is deliberate: every extra
/// symbology is work done on every frame, and a code nem cannot bind is not
/// worth slowing down the one it can.
const scanFormats = <BarcodeFormat>[
  BarcodeFormat.qrCode,
  BarcodeFormat.ean8,
  BarcodeFormat.ean13,
  BarcodeFormat.upcA,
  BarcodeFormat.upcE,
  BarcodeFormat.code128,
];

/// The scan screen: point at a label or hold a tag against the phone, and the
/// work due there gets done.
///
/// The screen is the edge of the scan flow and nothing more. It owns the
/// camera, the NFC session, the haptic and the toast; what a scanned string
/// *means* is [ScanResolver]'s answer, and this widget only carries out the
/// outcome it is handed, through the same [presentScanOutcome] a tap that
/// launched nem goes through (PLAN.md — Resolution). Both readers hand their
/// string to the same resolver and differ in one argument, the [ScanReader] —
/// which is the only thing that can say a `nem://t/<uuid>` came off a tag
/// rather than off a printed label, since the two are byte-identical
/// (ADR 0009).
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, this.previewBuilder});

  /// Overrides the camera preview. Tests only.
  @visibleForTesting
  final ScanPreviewBuilder? previewBuilder;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  MobileScannerController? _controller;

  /// Set while an outcome is being carried out, so the camera's stream of
  /// detections cannot stack two sheets or complete something twice while the
  /// first scan is still being dealt with.
  bool _handling = false;

  /// What the NFC hardware can do, or null while the question is still out.
  TagAvailability? _tagAvailability;

  /// Whether the OS will let a tap on a tag open nem at all (#9), or null
  /// while the question is still out.
  TagLaunchPreference? _launchPreference;

  /// Whether a read session is open.
  bool _tagSession = false;

  /// Read once and held, rather than read through `ref` on demand: `dispose`
  /// needs it to close the session, and reading a provider from a widget that
  /// is already on its way out is not allowed.
  late final TagGateway _tags;

  @override
  void initState() {
    super.initState();
    _tags = ref.read(tagGatewayProvider);
    unawaited(_prepareTags());
    if (widget.previewBuilder == null) {
      // Labels and product codes both: a barcode in front of the camera is a
      // code nem can resolve or offer to bind (#10).
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        formats: scanFormats,
      );
    }
    // Raising the camera is a fresh intention: the thirty-second repeat window
    // exists to swallow a fumbled second read, not to swallow a deliberate
    // second visit.
    unawaited(ref.read(scanResolverProvider).reset());
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    // A session left running would keep polling — and on iOS would leave the
    // system's sheet up over whatever the scan navigated to.
    if (_tagSession) unawaited(_tags.stop());
    super.dispose();
  }

  /// Works out whether tags can be read here, and starts reading them when that
  /// can be done without taking the screen over.
  ///
  /// A device with no NFC in it is not an error state and gets no message: the
  /// camera is the whole screen, the tag affordance simply is not there, and
  /// scanning a printed label works exactly as it always did.
  Future<void> _prepareTags() async {
    final availability = await _tags.availability();
    if (!mounted) return;
    setState(() => _tagAvailability = availability);
    if (availability == TagAvailability.enabled) {
      // Only worth asking where there are tags to tap. The answer is a system
      // setting the user may have given months ago, to a prompt nem never saw
      // (#9), and its symptom is that tapping a tag does nothing at all.
      final preference = await ref.read(tagLaunchGatewayProvider).preference();
      if (!mounted) return;
      setState(() => _launchPreference = preference);
    }
    if (availability == TagAvailability.enabled &&
        _tags.presentation == TagSessionPresentation.background) {
      await _startTagSession();
    }
  }

  /// Opens a read session.
  ///
  /// On Android this runs under the camera, so a tag and a label are both live
  /// at once and neither needs choosing. On iOS it raises the system's sheet
  /// over everything, which is why it waits there for a deliberate tap
  /// (ADR 0009 — iPhone scanning is two gestures).
  Future<void> _startTagSession() async {
    if (_tagSession) return;
    setState(() => _tagSession = true);
    await _tags.startReading(
      onRead: _onTagRead,
      prompt: 'Hold the phone against the tag.',
    );
  }

  Future<void> _onTagRead(TagRead read) async {
    // The sheet has to come down before anything of nem's can be seen behind
    // it, and it is the same sheet that would otherwise swallow the toast.
    if (_tags.presentation == TagSessionPresentation.systemSheet) {
      await _tags.stop(
        message: read is TagValueRead ? 'Tag read' : null,
        errorMessage: read is TagValueRead ? null : 'Nothing readable on it',
      );
      if (mounted) setState(() => _tagSession = false);
    }
    if (!mounted) return;

    switch (read) {
      case TagValueRead(:final value):
        await _onScanned(value, reader: ScanReader.nfc);
      case TagUnreadable(:final detail):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(detail ?? 'Nothing nem can read is on that tag.'),
            ),
          );
    }
  }

  Future<void> _onScanned(
    String raw, {
    ScanReader reader = ScanReader.camera,
  }) async {
    if (_handling) return;
    _handling = true;
    try {
      final outcome = await ref
          .read(scanResolverProvider)
          .resolve(raw, reader: reader, now: ref.read(clockProvider)());
      if (!mounted) return;
      final navigator = Navigator.of(context);
      await presentScanOutcome(
        context,
        ref,
        outcome,
        // Completing takes this screen down, so the due list is what you watch
        // update behind the toast.
        dismiss: () {
          if (navigator.canPop()) navigator.pop();
        },
      );
    } finally {
      _handling = false;
    }
  }

  /// Whether the screen shows a button that raises the system's NFC sheet.
  ///
  /// Only where the session takes the screen over, and only while none is open:
  /// where it can run underneath the camera it is already running, and asking
  /// for a tap to start something that has started would be a lie.
  bool get _offersTagButton =>
      _tagAvailability == TagAvailability.enabled &&
      _tags.presentation == TagSessionPresentation.systemSheet &&
      !_tagSession;

  /// The line along the bottom, which is the only place the state of the NFC
  /// hardware is ever mentioned.
  String get _hint => switch (_tagAvailability) {
    // Switched off is worth saying, because the fix is one toggle away and
    // otherwise a tag held against the phone just does nothing.
    TagAvailability.disabled =>
      'Point at a label to complete what is due there. NFC is switched off, '
          'so tags will not scan.',
    TagAvailability.enabled
        when _tags.presentation == TagSessionPresentation.background =>
      'Point at a label, or hold a tag against the phone, to complete what is '
          'due there.',
    // No hardware, or not answered yet: the camera is the whole screen and
    // nothing here needs to apologise for a radio this phone never had.
    _ => 'Point at a label to complete what is due there.',
  };

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          if (controller != null)
            IconButton(
              icon: const Icon(Icons.flashlight_on_outlined),
              tooltip: 'Torch',
              onPressed: controller.toggleTorch,
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          widget.previewBuilder?.call(context, _onScanned) ??
              MobileScanner(
                controller: controller,
                onDetect: (capture) {
                  for (final barcode in capture.barcodes) {
                    final raw = barcode.rawValue;
                    if (raw != null && raw.isNotEmpty) {
                      unawaited(_onScanned(raw));
                      return;
                    }
                  }
                },
              ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_offersTagButton) ...[
                      FilledButton.icon(
                        key: const ValueKey('scan-tag'),
                        onPressed: _startTagSession,
                        icon: const Icon(Icons.nfc),
                        label: const Text('Scan a tag'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    _ScanHint(text: _hint),
                    if (_launchPreference == TagLaunchPreference.disallowed)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: _TagLaunchDisallowed(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanHint extends StatelessWidget {
  const _ScanHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// Said out loud only when the OS has been told not to let tags open nem.
///
/// Android 16 asks once, ever, and remembers a "no" permanently (ADR 0009).
/// Nothing in nem can ask again, and nothing in nem can tell the difference
/// between that answer and a tag that was never tapped — so the one place it
/// can be raised is here, where somebody is already holding a phone against
/// something and wondering why scanning takes two hands.
class _TagLaunchDisallowed extends ConsumerWidget {
  const _TagLaunchDisallowed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('tag-launch-disallowed'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tapping a tag cannot open nem, because NFC launching is '
              'switched off for it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            TextButton(
              key: const ValueKey('allow-tag-launch'),
              onPressed: () =>
                  ref.read(tagLaunchGatewayProvider).showPreferenceScreen(),
              child: const Text('Change that setting'),
            ),
          ],
        ),
      ),
    );
  }
}
