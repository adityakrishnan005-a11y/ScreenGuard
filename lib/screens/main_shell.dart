import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/screens/dashboard.dart';
import 'package:screenguard/screens/focus_screen.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/daemon_prompt_dialog.dart';
import 'package:screenguard/widgets/daemon_status_banner.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    DashboardScreen(),
    FocusScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final daemonService = Provider.of<DaemonService>(context, listen: false);
      final db = Provider.of<DatabaseService>(context, listen: false);
      DaemonPromptDialog.showIfNeeded(context, daemonService, db);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const DaemonStatusBanner(),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: _pages,
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.timer_outlined),
            selectedIcon: Icon(Icons.timer),
            label: 'Focus Mode',
          ),
        ],
      ),
    );
  }
}
