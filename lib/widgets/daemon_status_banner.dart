import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/screens/settings_screen.dart';

class DaemonStatusBanner extends StatelessWidget {
  const DaemonStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final daemonService = Provider.of<DaemonService>(context);

    // Only visible when daemon is stopped
    if (daemonService.isRunning) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.red.shade900,
      elevation: 3,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.red.shade700, width: 1),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Daemon not working in background — Screen time tracking and limits are inactive.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (daemonService.isLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            else ...[
              // Quick Start
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.red.shade900,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => daemonService.startDaemon(enableAutostart: false),
                child: const Text(
                  'Start Now',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              // Always Autostart
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => daemonService.startDaemon(enableAutostart: true),
                child: const Text(
                  'Autostart Always',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Daemon Settings',
                icon: const Icon(Icons.settings_outlined, color: Colors.white70, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
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
        ),
      ),
    );
  }
}
