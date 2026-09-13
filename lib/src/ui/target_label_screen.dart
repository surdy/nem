import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';

import '../app/providers.dart';
import '../domain/binding.dart';
import '../domain/target.dart';

/// The side of the exported PNG, in pixels.
///
/// Generous on purpose: a label is printed and then stuck to a boiler, and
/// reprinting one because it scans badly costs more than the bytes do.
const _exportPixels = 1024;

/// A target's label: the QR code you print and stick on the thing (CONTEXT.md —
/// "Label").
///
/// The code encodes `nem://t/<uuid>` (ADR 0009) — the target's own id, so the
/// printed label and the binding are the same uuid and reprinting is free.
/// Opening this screen provisions the label: the binding is written the first
/// time, and is the same row on every visit after that.
class TargetLabelScreen extends ConsumerStatefulWidget {
  const TargetLabelScreen({super.key, required this.target});

  final Target target;

  @override
  ConsumerState<TargetLabelScreen> createState() => _TargetLabelScreenState();
}

class _TargetLabelScreenState extends ConsumerState<TargetLabelScreen> {
  late final Future<Binding> _label;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    // Provisioning is generating the code *and* binding it (CONTEXT.md —
    // "Provisioning"). A QR printed without a binding row would scan as an
    // unknown code, which is exactly the confusion this screen exists to avoid.
    _label = ref
        .read(bindingRepositoryProvider)
        .generateLabel(widget.target.id);
  }

  /// Renders the label as a PNG and hands it to the system share sheet, which
  /// is where printing, AirDrop and "save to Files" all live.
  ///
  /// PNG rather than PDF: an image is what both print paths on both platforms
  /// accept, and a PDF would mean a second rendering stack for a single square.
  Future<void> _export(String uri) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final qrImage = QrImage(
        QrCode.fromData(
          data: uri,
          // High correction, because this gets printed and then lives on a
          // boiler: a scuffed or greasy corner should still scan.
          errorCorrectLevel: QrErrorCorrectLevel.H,
        ),
      );
      final bytes = await qrImage.toImageAsBytes(
        size: _exportPixels,
        format: ui.ImageByteFormat.png,
        decoration: const PrettyQrDecoration(
          // A quiet zone is not decoration: without the margin, readers fail
          // on a code printed flush against anything.
          quietZone: PrettyQrQuietZone.standard,
          background: Colors.white,
        ),
      );
      if (bytes == null) throw StateError('The label could not be rendered');

      // share_plus writes the bytes to its own cache file, so nothing here
      // owns a path. `fileNameOverrides` is what actually names the file —
      // `XFile.fromData`'s own `name` is ignored on most platforms.
      final fileName = '${_fileSafe(widget.target.name)}-label.png';
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes.buffer.asUint8List(), mimeType: 'image/png'),
          ],
          fileNameOverrides: [fileName],
          text: 'nem label for ${widget.target.name}',
        ),
      );
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not export the label.\n$error')),
        );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Label')),
      body: FutureBuilder<Binding>(
        future: _label,
        builder: (context, snapshot) {
          final binding = snapshot.data;
          if (snapshot.hasError) {
            return _Message(
              text: 'Could not generate the label.\n${snapshot.error}',
            );
          }
          if (binding == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final uri = labelUriFor(binding.targetId);

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(widget.target.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Print this, stick it on the thing, and scan it to record the '
                'work done there.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              Center(
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox.square(
                      dimension: 240,
                      child: PrettyQrView.data(
                        key: const ValueKey('label-qr'),
                        data: uri,
                        errorCorrectLevel: QrErrorCorrectLevel.H,
                        decoration: const PrettyQrDecoration(
                          quietZone: PrettyQrQuietZone.standard,
                          background: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: SelectableText(uri, style: theme.textTheme.bodySmall),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('export-label'),
                onPressed: _exporting ? null : () => _export(uri),
                icon: const Icon(Icons.ios_share),
                label: Text(_exporting ? 'Exporting…' : 'Export for printing'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );
}

/// A target name reduced to something that can be a file name.
String _fileSafe(String name) {
  final cleaned = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  return cleaned.isEmpty ? 'target' : cleaned;
}
