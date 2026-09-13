import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app.dart';
import 'src/app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();

  // Due dates and last-completed timestamps are recomputed from the completion
  // log on launch (PLAN.md, ADR 0004), so a date change or a timezone shift
  // since the last run cannot leave them stale. This is an explicit launch-time
  // call rather than drift's `beforeOpen`, which fires on every database open.
  await container.read(taskRepositoryProvider).recomputeDerivedState();

  runApp(
    UncontrolledProviderScope(container: container, child: const NemApp()),
  );
}
