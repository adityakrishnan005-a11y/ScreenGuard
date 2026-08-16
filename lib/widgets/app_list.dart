import 'package:flutter/material.dart';
import 'package:screenguard/utils/format.dart';

class AppListTile extends StatelessWidget {
  final String name;
  final int ms;
  final int maxMs;
  final Color color;
  final VoidCallback? onTap;

  const AppListTile({
    super.key,
    required this.name,
    required this.ms,
    required this.maxMs,
    this.color = Colors.teal,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = maxMs == 0 ? 0.0 : (ms / maxMs).clamp(0.0, 1.0);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.18),
          child: Text(
            initial,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              formatDuration(ms),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
