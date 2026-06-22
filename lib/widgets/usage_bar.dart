import 'package:flutter/material.dart';

class UsageBar extends StatelessWidget {
  final int usedMs;
  final int goalMs;
  const UsageBar({super.key, required this.usedMs, required this.goalMs});

  @override
  Widget build(BuildContext context) {
    final ratio = goalMs == 0 ? 0.0 : (usedMs / goalMs).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: ratio, minHeight: 12),
        const SizedBox(height: 4),
        Text('${(ratio * 100).toStringAsFixed(0)}% of daily goal'),
      ],
    );
  }
}
