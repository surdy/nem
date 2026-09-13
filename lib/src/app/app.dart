import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/home_shell.dart';
import 'providers.dart';

/// Lets a digest tap reach the navigator from outside the widget tree.
final nemNavigatorKey = GlobalKey<NavigatorState>();

/// Brings the due list forward — what tapping a digest does.
///
/// The due list is the app's home route, so a tap that cold-starts nem lands
/// there without any help. This is for the other case: a tap while nem is in
/// the background with, say, the settings screen or the task editor on top.
void showDueList() =>
    nemNavigatorKey.currentState?.popUntil((route) => route.isFirst);

class NemApp extends ConsumerStatefulWidget {
  const NemApp({super.key});

  @override
  ConsumerState<NemApp> createState() => _NemAppState();
}

class _NemAppState extends ConsumerState<NemApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Re-tops the rolling window on every foreground. Days fall off the front
    // of it as they fire, completions change what the remaining days should
    // say, and nothing in the OS can recompute either — so the window is
    // rebuilt from the tasks as they now stand.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(digestSchedulerProvider).refresh(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nem',
      navigatorKey: nemNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F6B4F),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3F6B4F),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
