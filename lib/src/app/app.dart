import 'package:flutter/material.dart';

import '../ui/home_shell.dart';

class NemApp extends StatelessWidget {
  const NemApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nem',
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
