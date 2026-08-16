import 'package:flutter/material.dart';
import 'package:screenguard/utils/format.dart';

class DeltaBadge extends StatelessWidget {
  final int current;
  final int previous;
  const DeltaBadge({super.key, required this.current, required this.previous});

  @override
  Widget build(BuildContext context) {
    if (previous == 0 || previous < 5 * 60 * 1000) {
      // If yesterday has zero or negligible recorded time (<5m), delta is not meaningful.
      return const SizedBox.shrink();
    }
    final pct = percentChange(current, previous);
    final up = pct >= 0;
    final color = up ? Colors.red : Colors.green;
    final label = '${up ? '+' : ''}${pct.toStringAsFixed(0)}% vs yesterday';
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
