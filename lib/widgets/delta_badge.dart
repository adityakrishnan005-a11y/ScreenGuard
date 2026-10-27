import 'package:flutter/material.dart';
import 'package:screenguard/theme/app_theme.dart';
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
    final palette = AppPalette.of(context);
    final pct = percentChange(current, previous);
    final up = pct >= 0;
    final color = up ? palette.danger : palette.success;
    final label = '${up ? '+' : ''}${pct.toStringAsFixed(0)}% vs yesterday';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
