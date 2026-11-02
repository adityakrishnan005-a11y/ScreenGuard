import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/utils/format.dart';
import 'package:screenguard/widgets/app_list.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/widgets/day_chart.dart';

/// Samsung Digital Wellbeing-style trends screen: a rolling summary, a daily
/// bar chart and the most-used apps for the selected period.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _periodIndex = 0; // 0 = week, 1 = 30 days

  List<Map<String, dynamic>> _daily = [];
  List<Map<String, dynamic>> _perApp = [];
  int _total = 0;
  int _focusSessions = 0;
  int _goal = 0;
  StreamSubscription? _sub;

  int get _days => _periodIndex == 0 ? 7 : 30;
  String get _periodLabel => _periodIndex == 0 ? 'Last 7 days' : 'Last 30 days';

  @override
  void initState() {
    super.initState();
    _load();
    _sub = Stream.periodic(const Duration(seconds: 30)).listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _load() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: _days - 1));

    setState(() {
      _daily = db.dailyTotals(days: _days);
      _total = db.totalForRange(from, today);
      _perApp = db.perAppForRange(from, today, limit: 10);
      _focusSessions = db.completedFocusSessionsInRange(from, today);
      _goal = db.getDailyGoalMs();
    });
  }

  void _setPeriod(int index) {
    if (index == _periodIndex) return;
    setState(() => _periodIndex = index);
    _load();
  }

  DateTime? get _bestDay {
    if (_daily.isEmpty) return null;
    Map<String, dynamic>? best;
    for (final day in _daily) {
      final value = (day['t'] as int?) ?? 0;
      if (value <= 0) continue;
      if (best == null || value > ((best['t'] as int?) ?? 0)) best = day;
    }
    return best?['date'] as DateTime?;
  }

  int get _bestDayMs {
    var best = 0;
    for (final day in _daily) {
      final value = (day['t'] as int?) ?? 0;
      if (value > best) best = value;
    }
    return best;
  }

  int get _activeDays => _daily.where((d) => ((d['t'] as int?) ?? 0) > 0).length;

  int get _daysWithinGoal {
    if (_goal <= 0) return 0;
    // Days with no computer use count as within the daily goal too.
    return _daily
        .where((d) => ((d['t'] as int?) ?? 0) <= _goal)
        .length;
  }

  String _shortDate(DateTime? date) {
    if (date == null) return '—';
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month]} ${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final average = _total ~/ _days;
    final maxApp = _perApp.isEmpty ? 0 : ((_perApp.first['t'] as int?) ?? 0);
    final palette = AppPalette.of(context);

    return AppScrollView(
      onRefresh: () async => _load(),
      children: [
        AppPageHeader(
          title: 'Reports',
          subtitle: 'Trends for the ${_periodLabel.toLowerCase()}',
          actions: [
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Week')),
                ButtonSegment(value: 1, label: Text('30 days')),
              ],
              selected: {_periodIndex},
              onSelectionChanged: (selection) => _setPeriod(selection.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),

        // ── Summary ────────────────────────────────────────────────────────
        AppSectionCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final tiles = <Widget>[
                AppStatTile(
                  icon: Icons.today_rounded,
                  label: 'Daily average',
                  value: formatDuration(average),
                ),
                AppStatTile(
                  icon: Icons.timelapse_rounded,
                  label: 'Total screen time',
                  value: formatDuration(_total),
                ),
                AppStatTile(
                  icon: Icons.trending_up_rounded,
                  label: 'Busiest day',
                  value:
                      '${_shortDate(_bestDay)} · ${formatDuration(_bestDayMs)}',
                  accent: palette.warning,
                ),
                AppStatTile(
                  icon: Icons.center_focus_strong_rounded,
                  label: 'Focus sessions',
                  value: '$_focusSessions completed',
                  accent: palette.success,
                ),
              ];

              if (wide) {
                return Row(
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      Expanded(child: tiles[i]),
                      if (i != tiles.length - 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.lg,
                          ),
                          child: SizedBox(
                            height: 44,
                            child: VerticalDivider(
                              width: 1,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                    ],
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    tiles[i],
                    if (i != tiles.length - 1)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: Divider(),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Chart ──────────────────────────────────────────────────────────
        AppSectionCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Daily screen time',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          '$_activeDays active ${_activeDays == 1 ? 'day' : 'days'} out of $_days',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    formatDuration(_total),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                height: 220,
                child: DayChart(data: _daily),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Goal adherence ────────────────────────────────────────────────
        if (_goal > 0) ...[
          _GoalAdherenceCard(
            goalMs: _goal,
            daysWithinGoal: _daysWithinGoal,
            totalDays: _daily.length,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],

        // ── Top apps ──────────────────────────────────────────────────────
        AppSectionHeader(
          title: 'Most used apps',
          subtitle: _periodLabel,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
        ),
        AppSectionCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: _perApp.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Center(
                    child: Text(
                      'No app usage recorded for this period.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < _perApp.length; i++) ...[
                      AppListTile(
                        name: _perApp[i]['app_name'] as String? ??
                            _perApp[i]['app'] as String,
                        ms: (_perApp[i]['t'] as int?) ?? 0,
                        maxMs: maxApp,
                        color: palette.colorAt(i),
                        iconPath:
                            AppIconService.resolve(_perApp[i]['app'] as String),
                      ),
                      if (i != _perApp.length - 1)
                        const Divider(indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppInfoBanner(
          icon: Icons.lock_outline_rounded,
          message:
              'Reports are calculated from the sessions stored on this computer only. '
              'Idle time is excluded from the totals above.',
        ),
      ],
    );
  }
}

class _GoalAdherenceCard extends StatelessWidget {
  const _GoalAdherenceCard({
    required this.goalMs,
    required this.daysWithinGoal,
    required this.totalDays,
  });

  final int goalMs;
  final int daysWithinGoal;
  final int totalDays;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final ratio = totalDays == 0 ? 0.0 : daysWithinGoal / totalDays;

    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: palette.success.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.flag_rounded, color: palette.success),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Days within your daily goal',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 8,
                    color: palette.success,
                    backgroundColor: palette.success.withValues(alpha: 0.12),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '$daysWithinGoal of $totalDays days under ${formatDuration(goalMs)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  'Days with no computer use count as within goal.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
