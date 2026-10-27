import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/app_killer.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/app_limit_dialog.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/screens/dashboard.dart';
import 'package:screenguard/utils/format.dart';

class TimesUpScreen extends StatelessWidget {
  final String app;
  final String appName;
  final int? pid;

  const TimesUpScreen({
    super.key,
    required this.app,
    required this.appName,
    this.pid,
  });

  Future<void> _closeApp(BuildContext context) async {
    // NOTE: no WM_DELETE here — the focused window is this popup, so that
    // would close ScreenGuard itself instead of the offending app.
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
    final limitData = db.getAppLimit(app);
    final limitMs = (limitData?['limit_ms'] as int?) ?? 0;
    final extMs = (limitData?['temp_extension_ms'] as int?) ?? 0;
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
                color: palette.warning.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.hourglass_bottom_rounded,
                size: 40,
                color: palette.warning,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Time\'s Up!',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'You\'ve reached your daily limit for $appName.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (limitMs > 0) ...[
            const SizedBox(height: AppSpacing.lg),
            AppInfoBanner(
              icon: Icons.timer_outlined,
              color: palette.warning,
              title: 'Daily limit for today',
              message: 'You\'ve used ${formatDuration(limitMs + extMs)}. '
                  'Take a break, or grant yourself a little more time.',
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 440;
              final plusOne = OutlinedButton.icon(
                onPressed: () {
                  db.addTempExtension(app, 60 * 1000);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Added 1 minute to $appName!'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const DashboardScreen()),
                  );
                },
                icon: const Icon(Icons.timer_outlined),
                label: const Text('+1 Min'),
              );
              final plusFifteen = OutlinedButton.icon(
                onPressed: () {
                  db.addTempExtension(app, 15 * 60 * 1000);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Added 15 minutes to $appName today!'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const DashboardScreen()),
                  );
                },
                icon: const Icon(Icons.more_time_rounded),
                label: const Text('+15 Min'),
              );
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: plusOne),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: plusFifteen),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  plusOne,
                  const SizedBox(height: AppSpacing.md),
                  plusFifteen,
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AppLimitDialog(
                  app: app,
                  appName: appName,
                  currentLimitMs: limitMs,
                ),
              );
            },
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Edit Limit'),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: palette.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => _closeApp(context),
            icon: const Icon(Icons.close_rounded),
            label: const Text('Close App'),
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
