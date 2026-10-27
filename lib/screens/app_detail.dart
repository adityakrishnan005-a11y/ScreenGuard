import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/widgets/day_chart.dart';
import 'package:screenguard/widgets/app_limit_dialog.dart';
import 'package:screenguard/utils/format.dart';

class AppDetailScreen extends StatefulWidget {
  final String app;
  final String name;

  const AppDetailScreen({
    super.key,
    required this.app,
    required this.name,
  });

  @override
  State<AppDetailScreen> createState() => _AppDetailScreenState();
}

class _AppDetailScreenState extends State<AppDetailScreen> {
  List<Map<String, dynamic>> _history = [];
  int _todayMs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    setState(() {
      _history = db.appHistory(widget.app, days: 7);
      _todayMs = db.getAppTodayMs(widget.app);
    });
  }

  @override
  Widget build(BuildContext context) {
    final db = Provider.of<DatabaseService>(context);
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final limitData = db.getAppLimit(widget.app);
    final limitMs = (limitData?['limit_ms'] as int?) ?? 0;
    final extMs = (limitData?['temp_extension_ms'] as int?) ?? 0;
    final hasLimit = limitMs > 0 && (limitData?['enabled'] as int? ?? 1) == 1;
    final weekTotal = _history.fold<int>(0, (sum, row) => sum + ((row['t'] as int?) ?? 0));
    final average = weekTotal ~/ 7;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
      ),
      body: AppScrollView(
        children: [
          // ── App identity ────────────────────────────────────────────────
          AppSectionCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Row(
              children: [
                _AppAvatar(app: widget.app, name: widget.name, size: 64),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        'Today: ${formatDuration(_todayMs)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _LimitBadge(hasLimit: hasLimit),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ── Period summary ──────────────────────────────────────────────
          AppSectionCard(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.lg,
            ),
            child: Wrap(
              spacing: AppSpacing.xxl,
              runSpacing: AppSpacing.lg,
              children: [
                AppStatTile(
                  icon: Icons.calendar_view_week_rounded,
                  label: 'Last 7 days',
                  value: formatDuration(weekTotal),
                ),
                AppStatTile(
                  icon: Icons.analytics_outlined,
                  label: 'Daily average',
                  value: formatDuration(average),
                ),
                AppStatTile(
                  icon: Icons.timer_outlined,
                  label: 'Daily limit',
                  value: hasLimit ? formatDuration(limitMs + extMs) : 'Not set',
                  accent: hasLimit ? palette.warning : theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // ── Limit management ────────────────────────────────────────────
          AppSectionCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: (hasLimit ? palette.warning : theme.colorScheme.primary)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    hasLimit ? Icons.timer : Icons.timer_outlined,
                    color: hasLimit ? palette.warning : theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Daily app limit',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        hasLimit
                            ? 'Limit set to ${formatDuration(limitMs + extMs)} / day'
                            : 'No time limit set for this app',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await showDialog(
                      context: context,
                      builder: (_) => AppLimitDialog(
                        app: widget.app,
                        appName: widget.name,
                        currentLimitMs: limitMs,
                      ),
                    );
                    _load();
                  },
                  icon: Icon(hasLimit ? Icons.edit_rounded : Icons.add_alarm_rounded),
                  label: Text(hasLimit ? 'Edit' : 'Set limit'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── History chart ───────────────────────────────────────────────
          const AppSectionHeader(
            title: 'Last 7 days usage',
            subtitle: 'Active screen time per day',
            padding: EdgeInsets.fromLTRB(
              AppSpacing.xs,
              AppSpacing.xs,
              AppSpacing.xs,
              AppSpacing.sm,
            ),
          ),
          AppSectionCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: SizedBox(
              height: 240,
              child: DayChart(data: _history),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

class _LimitBadge extends StatelessWidget {
  const _LimitBadge({required this.hasLimit});

  final bool hasLimit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = hasLimit ? palette.warning : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        hasLimit ? 'Limit set' : 'No limit',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _AppAvatar extends StatelessWidget {
  const _AppAvatar({
    required this.app,
    required this.name,
    required this.size,
  });

  final String app;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = AppIconService.resolve(app);
    final fallback = Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: TextStyle(
        fontSize: size * 0.38,
        fontWeight: FontWeight.w700,
        color: scheme.primary,
      ),
    );

    Widget image;
    if (path == null) {
      image = fallback;
    } else if (AppIconService.isSvg(path)) {
      image = SvgPicture.file(File(path), fit: BoxFit.contain);
    } else {
      image = Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.16),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: image,
    );
  }
}
