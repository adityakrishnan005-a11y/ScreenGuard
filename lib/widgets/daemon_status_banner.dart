import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/screens/settings_screen.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';

class DaemonStatusBanner extends StatelessWidget {
  const DaemonStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final daemonService = Provider.of<DaemonService>(context);

    // Only visible when daemon is stopped
    if (daemonService.isRunning) {
      return const SizedBox.shrink();
    }

    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    final message = Row(
      children: [
        Icon(Icons.warning_amber_rounded, color: palette.warning, size: 20),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            'Daemon not working in background — Screen time tracking and limits are inactive.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );

    final actions = Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (daemonService.isLoading)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
            ),
            onPressed: () => daemonService.startDaemon(enableAutostart: false),
            child: const Text('Start now'),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
            ),
            onPressed: () => daemonService.startDaemon(enableAutostart: true),
            child: const Text('Autostart always'),
          ),
          IconButton(
            tooltip: 'Daemon settings',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, size: 18),
            onPressed: () {
              final scope = MainShellScope.maybeOf(context);
              if (scope != null) {
                scope.goToTab(3);
                return;
              }
              final db = Provider.of<DatabaseService>(context, listen: false);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) => SettingsScreen(db: db, initialTabIndex: 2),
                ),
              );
            },
          ),
        ],
      ],
    );

    return Material(
      color: palette.warning.withValues(alpha: 0.12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: palette.warning.withValues(alpha: 0.25)),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 760) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  message,
                  const SizedBox(height: AppSpacing.sm),
                  actions,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: message),
                const SizedBox(width: AppSpacing.lg),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}
