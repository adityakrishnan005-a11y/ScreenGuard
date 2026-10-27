import 'package:flutter/material.dart';

import 'package:screenguard/theme/app_theme.dart';

/// Large circular progress gauge used for the "screen time" hero card.
///
/// The ring animates when [progress] changes, which makes the 10-second
/// dashboard refresh feel alive without being distracting.
class ScreenTimeRing extends StatelessWidget {
  const ScreenTimeRing({
    super.key,
    required this.progress,
    required this.value,
    this.caption,
    this.color,
    this.size = 188,
    this.strokeWidth = 14,
    this.icon,
    this.valueStyle,
  });

  /// 0.0 – 1.0. Values above 1 are clamped for the arc but the caller can use
  /// [color] to signal overtime.
  final double progress;
  final String value;
  final String? caption;
  final Color? color;
  final double size;
  final double strokeWidth;
  final IconData? icon;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final clamped = progress.clamp(0.0, 1.0).toDouble();

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: clamped),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        builder: (context, animated, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  value: animated,
                  strokeWidth: strokeWidth,
                  strokeCap: StrokeCap.round,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.12),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: accent),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  Text(
                    value,
                    textAlign: TextAlign.center,
                    style: (valueStyle ?? theme.textTheme.headlineMedium)?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      caption!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
