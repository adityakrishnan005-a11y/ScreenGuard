import 'package:flutter/material.dart';
import 'package:screenguard/utils/format.dart';

class UsageBar extends StatelessWidget {
  final int usedMs;
  final int goalMs;
  const UsageBar({super.key, required this.usedMs, required this.goalMs});

  @override
  Widget build(BuildContext context) {
    if (goalMs <= 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;

        if (usedMs <= goalMs) {
          final ratio = (usedMs / goalMs).clamp(0.0, 1.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 10,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ratio,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.teal,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(ratio * 100).toStringAsFixed(0)}% of daily goal (${formatDuration(goalMs)})',
                style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
              ),
            ],
          );
        } else {
          final overtimeMs = usedMs - goalMs;
          final normalRatio = (goalMs / usedMs).clamp(0.0, 1.0);
          final percent = (usedMs / goalMs * 100).toStringAsFixed(0);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    height: 10,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Row(
                        children: [
                          Expanded(
                            flex: goalMs,
                            child: Container(color: Colors.teal),
                          ),
                          Expanded(
                            flex: overtimeMs,
                            child: Container(color: Colors.orange.shade700),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: (totalWidth * normalRatio - 1).clamp(0.0, totalWidth - 2),
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '$percent% of daily goal',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '• ${formatDuration(overtimeMs)} over ${formatDuration(goalMs)} limit',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          );
        }
      },
    );
  }
}
