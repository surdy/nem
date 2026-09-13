import 'package:flutter/material.dart';

import 'due_list_screen.dart';
import 'target_list_screen.dart';

/// The app's two top-level destinations: what is due, and what work is done on.
///
/// An [IndexedStack] rather than a swapped child, so the due list keeps its
/// scroll position and its live query while you look at the targets.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [DueListScreen(), TargetListScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: 'Due',
          ),
          NavigationDestination(
            icon: Icon(Icons.place_outlined),
            selectedIcon: Icon(Icons.place),
            label: 'Targets',
          ),
        ],
      ),
    );
  }
}
