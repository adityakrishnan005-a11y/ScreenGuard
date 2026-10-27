import 'package:flutter/material.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/utils/format.dart';

class UsageBar extends StatelessWidget {
  final int usedMs;
  final int goalMs;
  const UsageBar({super.key, required this.usedMs, required this.goalMs});

  @override
  Widget build(BuildContext context) {
    if (goalMs <= 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final track = scheme.surfaceContainerHighest;

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
                  color: track,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ratio,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${(ratio * 100).toStringAsFixed(0)}% of daily goal (${formatDuration(goalMs)})',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
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
                      color: track,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: Row(
                        children: [
                          Expanded(
                            flex: goalMs,
                            child: Container(color: scheme.primary),
                          ),
                          Expanded(
                            flex: overtimeMs,
                            child: Container(color: palette.warning),
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
                        color: scheme.onPrimary.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '$percent% of daily goal',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.warning,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    '• ${formatDuration(overtimeMs)} over ${formatDuration(goalMs)} limit',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
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
