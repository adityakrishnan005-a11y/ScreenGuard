import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/app_killer.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/app_limit_dialog.dart';
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
    final limitData = db.getAppLimit(app);
    final limitMs = (limitData?['limit_ms'] as int?) ?? 0;
    final extMs = (limitData?['temp_extension_ms'] as int?) ?? 0;

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
                      color: Colors.amber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.hourglass_bottom_rounded,
                      size: 40,
                      color: Colors.amber,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Time\'s Up!',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'You\'ve reached your daily limit for $appName.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  if (limitMs > 0)
                    Chip(
                      avatar: const Icon(Icons.timer_outlined, size: 16),
                      label: Text('Daily Limit: ${formatDuration(limitMs + extMs)}'),
                      backgroundColor: Theme.of(context).dividerColor.withValues(alpha: 0.08),
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
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
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
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
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
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => _closeApp(context),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Close App'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
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
            ),
          ),
        ),
      ),
    );
  }
}
