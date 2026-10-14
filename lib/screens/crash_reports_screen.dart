import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/crash_reporter.dart';

/// Screen that lists all stored crash logs and lets the user view details
/// or report them as GitHub issues.
class CrashReportsScreen extends StatefulWidget {
  const CrashReportsScreen({super.key});

  @override
  State<CrashReportsScreen> createState() => _CrashReportsScreenState();
}

class _CrashReportsScreenState extends State<CrashReportsScreen> {
  List<Map<String, dynamic>> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  void _loadLogs() {
    final reporter = Provider.of<CrashReporter>(context, listen: false);
    setState(() {
      _logs = reporter.getCrashLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reporter = Provider.of<CrashReporter>(context, listen: false);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Crash Reports',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          if (_logs.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear All Crash Reports?'),
                    content: const Text(
                      'This will permanently delete all stored crash logs. '
                      'This action cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                        ),
                        child: const Text('Clear All'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  reporter.clearAllCrashLogs();
                  _loadLogs();
                }
              },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Clear All'),
            ),
        ],
      ),
      body: _logs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 64, color: Colors.green.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No crash reports',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Everything is running smoothly!',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _logs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final log = _logs[index];
                return _CrashLogCard(
                  log: log,
                  colorScheme: colorScheme,
                  onReport: () => reporter.openGitHubIssue(log),
                  onDelete: () {
                    final filename = log['_filename'] as String?;
                    if (filename != null) {
                      reporter.deleteCrashLog(filename);
                      _loadLogs();
                    }
                  },
                  onTap: () => _showCrashDetail(log),
                );
              },
            ),
    );
  }

  void _showCrashDetail(Map<String, dynamic> log) {
    final reporter = Provider.of<CrashReporter>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.bug_report, color: Colors.red.shade400, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Crash — ${log['source'] ?? 'unknown'}',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detailRow('Timestamp', log['timestamp'] ?? 'N/A'),
                _detailRow('Version', log['version'] ?? 'N/A'),
                _detailRow('Source', log['source'] ?? 'N/A'),
                if (log['environment'] is Map) ...[
                  _detailRow('Desktop', (log['environment'] as Map)['de'] ?? 'N/A'),
                  _detailRow('Display', (log['environment'] as Map)['displayServer'] ?? 'N/A'),
                  _detailRow('OS', (log['environment'] as Map)['os'] ?? 'N/A'),
                ],
                const SizedBox(height: 12),
                const Text('Error',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.errorContainer.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    log['error']?.toString() ?? 'N/A',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                if (log['stackTrace'] != null) ...[
                  const SizedBox(height: 12),
                  const Text('Stack Trace',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 250),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        log['stackTrace'].toString(),
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              reporter.openGitHubIssue(log);
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Report on GitHub'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _CrashLogCard extends StatelessWidget {
  final Map<String, dynamic> log;
  final ColorScheme colorScheme;
  final VoidCallback onReport;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _CrashLogCard({
    required this.log,
    required this.colorScheme,
    required this.onReport,
    required this.onDelete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final source = log['source'] ?? 'unknown';
    final error = (log['error'] ?? 'Unknown error').toString();
    final timestamp = log['timestamp'] ?? '';
    final type = log['type'] as String?;

    IconData icon;
    Color iconColor;
    if (type == 'unclean_shutdown') {
      icon = Icons.power_off_outlined;
      iconColor = Colors.orange;
    } else if (source == 'watchdog') {
      icon = Icons.restart_alt;
      iconColor = Colors.red;
    } else {
      icon = Icons.bug_report_outlined;
      iconColor = Colors.red.shade400;
    }

    // Format timestamp nicely
    String timeStr = timestamp;
    try {
      final dt = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 60) {
        timeStr = '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        timeStr = '${diff.inHours}h ago';
      } else if (diff.inDays < 7) {
        timeStr = '${diff.inDays}d ago';
      } else {
        timeStr = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
    } catch (_) {}

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colorScheme.outline.withOpacity(0.1)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            source.toString().toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      error.length > 120
                          ? '${error.substring(0, 120)}...'
                          : error,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    tooltip: 'Report on GitHub',
                    onPressed: onReport,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: Colors.red.shade300),
                    tooltip: 'Delete',
                    onPressed: onDelete,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
