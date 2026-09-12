import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app.dart';
import 'src/app/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();

  // Derived state is recomputed on launch (PLAN.md, ADR 0004). This is an
  // explicit launch-time call rather than drift's `beforeOpen`, which fires on
  // every database open.
  await container.read(taskRepositoryProvider).recomputeDueDates();

  runApp(
    UncontrolledProviderScope(container: container, child: const NemApp()),
  );
}
