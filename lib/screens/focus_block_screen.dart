import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/app_killer.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/screens/dashboard.dart';

/// Persistent focus-mode warning, mirroring TimesUpScreen.
///
/// The daemon minimizes (never kills) a blocked app and launches this screen.
/// Nothing is closed automatically: the user can take 1 minute to save work,
/// close the app explicitly, or go back to the dashboard (the screen re-appears
/// at most once a minute while the app stays open in a work segment).
class FocusBlockScreen extends StatelessWidget {
  final String app;
  final String appName;
  final int? pid;

  const FocusBlockScreen({
    super.key,
    required this.app,
    required this.appName,
    this.pid,
  });

  Future<void> _closeApp(BuildContext context, DatabaseService db) async {
    // NOTE: no WM_DELETE here on purpose — the focused window right now is
    // this popup itself, so asking the compositor to close "the active
    // window" would suicide this screen before the kill stages run.
    final killed =
        await AppKiller.close(app: app, pid: pid, politeClose: false);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(killed
              ? '$appName was closed.'
              : 'Could not close $appName — close it manually.'),
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = Provider.of<DatabaseService>(context);
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);

    final card = AppSectionCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xl,
        AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: palette.breakTime.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.center_focus_strong_rounded,
                size: 40,
                color: palette.breakTime,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Stay Focused 🎯',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '$appName is on your focus block list.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppInfoBanner(
            icon: Icons.picture_in_picture_rounded,
            color: palette.breakTime,
            title: 'Nothing was closed',
            message: 'Its window was only minimized so you can decide what '
                'to do next — the app is still running in the background.',
          ),
          const SizedBox(height: AppSpacing.xl),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 440;
              final grace = OutlinedButton.icon(
                onPressed: () {
                  db.setFocusGraceMinutes(app, 1);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('1 minute to save your work in $appName.'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const DashboardScreen()),
                  );
                },
                icon: const Icon(Icons.more_time_rounded),
                label: const Text('+1 Minute'),
              );
              final close = FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: palette.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _closeApp(context, db),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Close App'),
              );
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: grace),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: close),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  grace,
                  const SizedBox(height: AppSpacing.md),
                  close,
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const DashboardScreen()),
                );
              },
              icon: const Icon(Icons.dashboard_rounded),
              label: const Text('Back to Dashboard'),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, viewport) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (viewport.maxHeight - AppSpacing.xl * 2)
                      .clamp(0.0, double.infinity),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: card,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
