import 'package:flutter/material.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';

class DaemonPromptDialog extends StatelessWidget {
  final DaemonService daemonService;
  final DatabaseService db;

  const DaemonPromptDialog({
    super.key,
    required this.daemonService,
    required this.db,
  });

  static Future<void> showIfNeeded(
    BuildContext context,
    DaemonService daemonService,
    DatabaseService db,
  ) async {
    // Check if user has already made an initial choice or if daemon is running
    final choice = db.getSetting('daemon_initial_choice', defaultValue: '');
    if (choice.isNotEmpty || daemonService.isRunning) {
      return;
    }

    // Wait a brief moment for UI to settle
    await Future.delayed(const Duration(milliseconds: 350));
    if (!context.mounted || daemonService.isRunning) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DaemonPromptDialog(
        daemonService: daemonService,
        db: db,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.shield_outlined, color: Colors.teal, size: 28),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              'ScreenGuard Daemon Setup',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ScreenGuard background daemon is not running',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The background daemon monitors active applications, records screen time, and enforces daily limits. Choose how you would like ScreenGuard to run:',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),

            // Option 1: Run Permanently (Autostart on Boot)
            _OptionTile(
              icon: Icons.all_inclusive_rounded,
              iconColor: Colors.teal,
              title: 'Run Permanently (Recommended)',
              subtitle: 'Starts automatically whenever your PC turns on and stays active in background.',
              isPrimary: true,
              onTap: () async {
                db.setSetting('daemon_initial_choice', 'autostart');
                Navigator.of(context).pop();
                await daemonService.startDaemon(enableAutostart: true);
              },
            ),
            const SizedBox(height: 10),

            // Option 2: Start for Now
            _OptionTile(
              icon: Icons.play_arrow_rounded,
              iconColor: Colors.blue,
              title: 'Start for Now',
              subtitle: 'Runs in background until your PC shuts down. Won\'t auto-start next boot.',
              onTap: () async {
                db.setSetting('daemon_initial_choice', 'session_only');
                Navigator.of(context).pop();
                await daemonService.startDaemon(enableAutostart: false);
              },
            ),
            const SizedBox(height: 10),

            // Option 3: Leave to start manually
            _OptionTile(
              icon: Icons.pause_circle_outline_rounded,
              iconColor: Colors.orange,
              title: 'Leave to Start Manually',
              subtitle: 'Do not start right now. You can start it anytime from the top bar or Settings.',
              onTap: () {
                db.setSetting('daemon_initial_choice', 'manual');
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isPrimary;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.isPrimary = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isPrimary ? Colors.teal : Colors.grey.withValues(alpha: 0.2),
            width: isPrimary ? 1.5 : 1,
          ),
          color: isPrimary ? Colors.teal.withValues(alpha: 0.06) : Colors.transparent,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isPrimary ? Colors.teal.shade800 : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }
}
