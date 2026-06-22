import 'package:flutter/material.dart';
import 'package:screenguard/utils/format.dart';

class DeltaBadge extends StatelessWidget {
  final int current;
  final int previous;
  const DeltaBadge({super.key, required this.current, required this.previous});

  @override
  Widget build(BuildContext context) {
    final pct = percentChange(current, previous);
    final up = pct >= 0;
    final color = up ? Colors.red : Colors.green;
    final label = '${up ? '+' : ''}${pct.toStringAsFixed(0)}% vs yesterday';
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.15),
      labelStyle: TextStyle(color: color),
    );
  }
}
