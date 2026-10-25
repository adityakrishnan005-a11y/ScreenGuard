import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/app_killer.dart';
import 'package:screenguard/services/db.dart';
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
    final killed = await AppKiller.close(app: app, pid: pid, politeClose: false);
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

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Card(
            elevation: 2,
            margin: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.center_focus_strong_rounded,
                      size: 40,
                      color: Colors.deepPurple,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Stay Focused 🎯',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$appName is on your focus block list.\n'
                    'Its window was minimized — nothing was closed.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () {
                            db.setFocusGraceMinutes(app, 1);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    '1 minute to save your work in $appName.'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                  builder: (_) => const DashboardScreen()),
                            );
                          },
                          icon: const Icon(Icons.more_time_rounded),
                          label: const Text('+1 Minute'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () => _closeApp(context, db),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Close App'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => const DashboardScreen()),
                        );
                      },
                      icon: const Icon(Icons.dashboard_rounded),
                      label: const Text('Back to Dashboard'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
