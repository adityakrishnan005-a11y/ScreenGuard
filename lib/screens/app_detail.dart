import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/day_chart.dart';
import 'package:screenguard/widgets/app_limit_dialog.dart';
import 'package:screenguard/utils/format.dart';

class AppDetailScreen extends StatefulWidget {
  final String app;
  final String name;

  const AppDetailScreen({
    super.key,
    required this.app,
    required this.name,
  });

  @override
  State<AppDetailScreen> createState() => _AppDetailScreenState();
}

class _AppDetailScreenState extends State<AppDetailScreen> {
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    setState(() {
      _history = db.appHistory(widget.app, days: 7);
    });
  }

  @override
  Widget build(BuildContext context) {
    final db = Provider.of<DatabaseService>(context);
    final limitData = db.getAppLimit(widget.app);
    final limitMs = (limitData?['limit_ms'] as int?) ?? 0;
    final extMs = (limitData?['temp_extension_ms'] as int?) ?? 0;
    final hasLimit = limitMs > 0 && (limitData?['enabled'] as int? ?? 1) == 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // App Timer Header Card
                Card(
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (hasLimit ? Colors.amber : Colors.teal)
                                .withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            hasLimit ? Icons.timer : Icons.timer_outlined,
                            color: hasLimit ? Colors.amber[800] : Colors.teal,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Daily App Limit',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hasLimit
                                    ? 'Limit set to ${formatDuration(limitMs + extMs)} / day'
                                    : 'No time limit set for this app',
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () async {
                            await showDialog(
                              context: context,
                              builder: (_) => AppLimitDialog(
                                app: widget.app,
                                appName: widget.name,
                                currentLimitMs: limitMs,
                              ),
                            );
                            _load();
                          },
                          icon: Icon(hasLimit ? Icons.edit : Icons.add_alarm),
                          label: Text(hasLimit ? 'Edit Limit' : 'Set Limit'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Last 7 Days Usage',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Card(
                    elevation: 0.5,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: DayChart(data: _history),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
