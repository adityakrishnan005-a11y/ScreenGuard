import 'package:flutter/material.dart';

import 'package:screenguard/theme/app_theme.dart';

/// Curated icons that can be assigned to a focus mode. Keys are persisted in
/// the database so the mapping must stay stable.
const Map<String, IconData> focusProfileIcons = {
  'center_focus_strong': Icons.center_focus_strong_rounded,
  'spa': Icons.spa_rounded,
  'work': Icons.work_rounded,
  'school': Icons.school_rounded,
  'code': Icons.code_rounded,
  'fitness_center': Icons.fitness_center_rounded,
  'menu_book': Icons.menu_book_rounded,
  'bedtime': Icons.bedtime_rounded,
  'music_note': Icons.music_note_rounded,
  'sports_esports': Icons.sports_esports_rounded,
  'brush': Icons.brush_rounded,
  'coffee': Icons.local_cafe_rounded,
  'psychology': Icons.psychology_rounded,
  'groups': Icons.groups_rounded,
};

IconData focusProfileIcon(String key) =>
    focusProfileIcons[key] ?? Icons.center_focus_strong_rounded;

/// Horizontally scrollable strip of circular focus-mode buttons.
///
/// The selected mode gets a neon-blue glow ring while the others stay muted.
/// When a session is running ([locked]) every other mode is dimmed; tapping one
/// still calls [onSelect] so the screen can explain how to switch.
class FocusProfileSelector extends StatelessWidget {
  const FocusProfileSelector({
    super.key,
    required this.profiles,
    required this.selectedId,
    required this.locked,
    required this.onSelect,
    required this.onAdd,
  });

  final List<Map<String, dynamic>> profiles;
  final int? selectedId;

  /// True while a focus session is running.
  final bool locked;

  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  static const double _itemWidth = 96;
  static const double _circleSize = 68;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      for (final profile in profiles)
        SizedBox(
          width: _itemWidth,
          child: _ProfileCircle(
            icon: focusProfileIcon(profile['icon'] as String? ?? ''),
            label: profile['name'] as String? ?? 'Focus',
            selected: profile['id'] == selectedId,
            dimmed: locked && profile['id'] != selectedId,
            size: _circleSize,
            onTap: () => onSelect(profile['id'] as int),
          ),
        ),
      SizedBox(
        width: _itemWidth,
        child: _ProfileCircle(
          icon: Icons.add_rounded,
          label: 'Add',
          selected: false,
          dimmed: locked,
          dashed: true,
          size: _circleSize,
          onTap: onAdd,
        ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final fits = items.length * _itemWidth <= constraints.maxWidth;
        final row = Row(
          mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment:
              fits ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: items,
        );

        if (fits) {
          return SizedBox(height: 112, child: Center(child: row));
        }
        return SizedBox(
          height: 112,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: row,
          ),
        );
      },
    );
  }
}

class _ProfileCircle extends StatelessWidget {
  const _ProfileCircle({
    required this.icon,
    required this.label,
    required this.selected,
    required this.dimmed,
    required this.size,
    required this.onTap,
    this.dashed = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool dimmed;
  final double size;
  final VoidCallback onTap;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final neon = palette.chartBar;

    final decoration = selected
        ? BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                neon.withValues(alpha: 0.34),
                neon.withValues(alpha: 0.12),
              ],
            ),
            border: Border.all(color: neon, width: 2.4),
            boxShadow: [
              BoxShadow(
                color: neon.withValues(alpha: 0.55),
                blurRadius: 20,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: neon.withValues(alpha: 0.25),
                blurRadius: 38,
                spreadRadius: 5,
              ),
            ],
          )
        : BoxDecoration(
            shape: BoxShape.circle,
            color: dashed
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.25)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            border: Border.all(
              color: dashed
                  ? scheme.outlineVariant
                  : scheme.outlineVariant.withValues(alpha: 0.55),
              width: dashed ? 1.6 : 1.2,
            ),
          );

    return Opacity(
      opacity: dimmed ? 0.42 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Focus mode $label',
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.sm,
              horizontal: AppSpacing.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: selected ? 1.06 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: size,
                    height: size,
                    decoration: decoration,
                    child: Icon(
                      icon,
                      size: size * 0.42,
                      color: selected
                          ? neon
                          : dimmed
                              ? scheme.onSurfaceVariant
                              : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    letterSpacing: selected ? 0.2 : 0,
                    color: selected ? neon : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
