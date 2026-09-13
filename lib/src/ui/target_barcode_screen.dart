import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/providers.dart';
import '../data/binding_repository.dart';
import '../domain/binding.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import 'scan_screen.dart' show ScanPreviewBuilder, scanFormats;

/// Adopting a product code that is already on the thing (CONTEXT.md —
/// "Barcode"): point the camera at the filter box and the code printed on it
/// starts resolving to this target.
///
/// The counterpart to [TargetLabelScreen] and [TargetTagScreen], and the
/// cheapest of the three kinds of provisioning — nothing is generated, nothing
/// is printed and nothing is written. The code was already there.
///
/// Binding from here refuses a code that already resolves to another target
/// (#10). That refusal is the whole reason this screen provisions through
/// [BindingRepository.bindUnclaimed] rather than `bind`: a barcode silently
/// changing which target it means is a binding lost with nobody told, and the
/// deliberate way to move one is the "Point at another target" action on the
/// target that owns it.
class TargetBarcodeScreen extends ConsumerStatefulWidget {
  const TargetBarcodeScreen({
    super.key,
    required this.target,
    this.previewBuilder,
  });

  final Target target;

  /// Overrides the camera preview. Tests only — the same seam the scan screen
  /// has, and for the same reason.
  @visibleForTesting
  final ScanPreviewBuilder? previewBuilder;

  @override
  ConsumerState<TargetBarcodeScreen> createState() =>
      _TargetBarcodeScreenState();
}

class _TargetBarcodeScreenState extends ConsumerState<TargetBarcodeScreen> {
  MobileScannerController? _controller;

  /// Set while a detection is being dealt with, so the camera's stream of reads
  /// cannot bind the same code twice over.
  bool _handling = false;

  /// The code this screen bound, once it has bound one. The camera stops
  /// mattering after that — binding a second barcode is a second visit.
  String? _bound;

  /// Why the last code was not bound, or null.
  String? _refusal;

  @override
  void initState() {
    super.initState();
    if (widget.previewBuilder == null) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        formats: scanFormats,
      );
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Future<void> _onScanned(String raw) async {
    if (_handling || _bound != null) return;
    _handling = true;
    try {
      // The same parse the scan screen uses, so "what is this code and what
      // would a binding store for it" is answered in exactly one place —
      // including the UPC-A canonicalisation that makes an iPhone and an
      // Android phone agree about the same box.
      final code = ScannedCode.parse(raw, ScanReader.camera);

      if (code.isScanUri) {
        setState(() {
          _refusal =
              'That is a nem label, not a product code. This screen adopts '
              'codes that were already printed on the thing — a label is made '
              'from the Label screen.';
        });
        return;
      }
      if (code.value.isEmpty) return;

      try {
        await ref
            .read(bindingRepositoryProvider)
            .bindUnclaimed(
              targetId: widget.target.id,
              kind: BindingKind.barcode,
              value: code.value,
            );
      } on BindingConflict catch (conflict) {
        if (mounted) setState(() => _refusal = conflict.message);
        return;
      }

      await HapticFeedback.mediumImpact();
      if (mounted) {
        setState(() {
          _bound = code.value;
          _refusal = null;
        });
      }
    } finally {
      _handling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    final bound = _bound;
    final refusal = _refusal;

    return Scaffold(
      appBar: AppBar(title: const Text('Barcode')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (bound == null)
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
            alignment: bound == null
                ? Alignment.bottomCenter
                : Alignment.center,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (bound != null) ...[
                          Text(
                            key: const ValueKey('barcode-bound'),
                            '$bound now resolves to ${widget.target.name}. '
                            'Scan it to record the work due there.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const ValueKey('barcode-done'),
                            onPressed: Navigator.of(context).pop,
                            child: const Text('Done'),
                          ),
                        ] else ...[
                          if (refusal != null) ...[
                            Text(
                              key: const ValueKey('barcode-refused'),
                              refusal,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          Text(
                            'Point at the barcode already printed on '
                            '${widget.target.name} — a filter box, a bottle, '
                            'a serial plate. Nothing is printed or written.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
