import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/screens/dashboard.dart';
import 'package:screenguard/screens/focus_screen.dart';
import 'package:screenguard/screens/reports_screen.dart';
import 'package:screenguard/screens/settings_screen.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/feedback_service.dart';
import 'package:screenguard/services/update_checker.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/widgets/daemon_prompt_dialog.dart';
import 'package:screenguard/widgets/daemon_status_banner.dart';
import 'package:screenguard/widgets/feedback_dialog.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  late final List<Widget> _pages;

  static const _destinations = <_AppDestination>[
    _AppDestination(
      label: 'Today',
      icon: Icons.today_outlined,
      selectedIcon: Icons.today_rounded,
    ),
    _AppDestination(
      label: 'Focus',
      icon: Icons.center_focus_strong_outlined,
      selectedIcon: Icons.center_focus_strong_rounded,
    ),
    _AppDestination(
      label: 'Reports',
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights_rounded,
    ),
    _AppDestination(
      label: 'Settings',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    final db = Provider.of<DatabaseService>(context, listen: false);
    _pages = [
      const DashboardScreen(),
      const FocusScreen(),
      const ReportsScreen(),
      SettingsScreen(db: db, embedded: true),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final daemonService = Provider.of<DaemonService>(context, listen: false);

      // The daemon setup prompt comes first — two dialogs must never
      // stack on top of each other.
      await DaemonPromptDialog.showIfNeeded(context, daemonService, db);
      if (!mounted) return;

      // Post-update banner: if the binary changed since the last run (any
      // install medium — rpm/deb/tarball/manual), announce it once.
      final updatedTo = UpdateChecker.updateNoticeOnStartup(db);
      if (updatedTo != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ScreenGuard updated to $updatedTo ✓'),
            duration: const Duration(seconds: 6),
          ),
        );
      }

      // Feedback request from the maintainer, if one is waiting.
      if (!daemonService.isRunning) {
        // No daemon to look it up for us — fetch it here (once a day).
        await FeedbackService(db: db).checkIfDue();
        if (!mounted) return;
      }
      await FeedbackDialog.showIfNeeded(context, db);
    });
  }

  void _goToTab(int index) {
    if (index < 0 || index >= _pages.length || index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final body = Column(
      children: [
        const DaemonStatusBanner(),
        Expanded(
          child: IndexedStack(
            index: _currentIndex,
            children: _pages,
          ),
        ),
      ],
    );

    return MainShellScope(
      goToTab: _goToTab,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: layout.useRail ? _buildRailShell(layout) : body,
        ),
        bottomNavigationBar: layout.useRail
            ? null
            : NavigationBar(
                selectedIndex: _currentIndex,
                onDestinationSelected: _goToTab,
                destinations: [
                  for (final destination in _destinations)
                    NavigationDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: destination.label,
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildRailShell(AppLayout layout) {
    final extended = layout.isExpanded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NavigationRail(
          selectedIndex: _currentIndex,
          onDestinationSelected: _goToTab,
          extended: extended,
          minExtendedWidth: 210,
          minWidth: 84,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          groupAlignment: -0.9,
          leading: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xl),
            child: _RailBrand(extended: extended),
          ),
          destinations: [
            for (final destination in _destinations)
              NavigationRailDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: Text(destination.label),
              ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
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
        ),
      ],
    );
  }
}

class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mark = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(Icons.shield_rounded, color: scheme.onPrimaryContainer, size: 22),
    );

    if (!extended) return mark;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: AppSpacing.md),
        Text(
          'ScreenGuard',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
        ),
      ],
    );
  }
}

class _AppDestination {
  const _AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
