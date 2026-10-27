import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/utils/format.dart';

/// A single app usage row. It renders without its own card/border so callers
/// can group several rows inside one rounded section card.
class AppListTile extends StatelessWidget {
  final String name;
  final int ms;
  final int maxMs;
  final Color color;
  final VoidCallback? onTap;
  final String? iconPath;

  const AppListTile({
    super.key,
    required this.name,
    required this.ms,
    required this.maxMs,
    this.color = AppTheme.seed,
    this.onTap,
    this.iconPath,
  });

  Widget _letterAvatar(Color color, String initial) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: color.withValues(alpha: 0.16),
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _leading(Color color, String initial) {
    final path = iconPath;
    if (path == null) return _letterAvatar(color, initial);
    final Widget image = AppIconService.isSvg(path)
        ? SvgPicture.file(
            File(path),
            width: 36,
            height: 36,
            fit: BoxFit.cover,
          )
        : Image.file(
            File(path),
            width: 36,
            height: 36,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _letterAvatar(color, initial),
          );
    return SizedBox(
      width: 36,
      height: 36,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: image,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = maxMs == 0 ? 0.0 : (ms / maxMs).clamp(0.0, 1.0);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      leading: _leading(color, initial),
      title: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            formatDuration(ms),
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            color: color,
            backgroundColor: color.withValues(alpha: 0.12),
          ),
        ),
      ),
      onTap: onTap,
    );
  }
}
