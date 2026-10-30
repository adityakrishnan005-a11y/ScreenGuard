import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_icon.dart';
import 'package:screenguard/theme/app_theme.dart';
import 'package:screenguard/ui/adaptive.dart';
import 'package:screenguard/widgets/usage_bar.dart';
import 'package:screenguard/widgets/app_list.dart';
import 'package:screenguard/widgets/app_section.dart';
import 'package:screenguard/widgets/day_chart.dart';
import 'package:screenguard/widgets/app_pie_chart.dart';
import 'package:screenguard/widgets/delta_badge.dart';
import 'package:screenguard/widgets/daily_goal_dialog.dart';
import 'package:screenguard/widgets/screen_time_ring.dart';
import 'package:screenguard/utils/format.dart';
import 'package:screenguard/screens/app_detail.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _today = 0;
  int _yesterday = 0;
  int _last30DaysTotal = 0;
  int _idleToday = 0;
  int _focusToday = 0;
  List<Map<String, dynamic>> _perApp = [];
  List<Map<String, dynamic>> _weekData = [];
  int _goal = 0;
  bool _showHint = true;
  int _untracked = 0;
  StreamSubscription? _sub;

  int _weekOffset = 0;
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
    _sub = Stream.periodic(const Duration(seconds: 10)).listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDateHeader(DateTime dt) {
    final now = DateTime.now();
    if (_isSameDay(dt, now)) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (_isSameDay(dt, yesterday)) return 'Yesterday';

    const days = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[dt.weekday]}, ${months[dt.month]} ${dt.day}';
  }

  String _todaySubtitle() {
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    const days = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '$greeting · ${days[now.weekday]}, ${months[now.month]} ${now.day}';
  }

  void _load() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    setState(() {
      _today = db.todayTotalMs();
      _yesterday = db.yesterdayTotalMs();
      _last30DaysTotal = db.last30DaysTotalMs();
      _weekData = db.getWeekData(weekOffset: _weekOffset);
      _perApp = db.perAppForDate(_selectedDate);
      _idleToday = db.getIdleTimeForDate(_selectedDate);
      _focusToday = db.getCompletedFocusSessionsToday();
      _untracked = db.recentUnknownSessions();
      _goal = db.getDailyGoalMs();
    });
  }

  Future<void> _showSetGoalDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => DailyGoalDialog(currentGoalMs: _goal),
    );
    if (changed == true && mounted) {
      _load();
    }
  }

  Color _goalColor(BuildContext context) {
    final palette = AppPalette.of(context);
    if (_goal <= 0) return Theme.of(context).colorScheme.primary;
    final ratio = _today / _goal;
    if (ratio >= 1) return palette.danger;
    if (ratio >= 0.85) return palette.warning;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final maxApp = _perApp.isEmpty ? 0 : ((_perApp.first['t'] as int?) ?? 0);
    final isTodaySelected = _isSameDay(_selectedDate, DateTime.now());
    final friendlyDate = _formatDateHeader(_selectedDate);
    final palette = AppPalette.of(context);

    return AppScrollView(
      onRefresh: () async => _load(),
      children: [
        AppPageHeader(
          title: 'Today',
          subtitle: _todaySubtitle(),
          actions: [
            OutlinedButton.icon(
              onPressed: _showSetGoalDialog,
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: Text(_goal > 0 ? 'Edit daily goal' : 'Set daily goal'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),

        // ── Screen time hero ────────────────────────────────────────────────
        AppSectionCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 620;
              final ring = ScreenTimeRing(
                progress: _goal > 0 ? _today / _goal : 0,
                value: formatDuration(_today),
                caption: _goal > 0 ? 'of ${formatDuration(_goal)} goal' : 'today',
                color: _goalColor(context),
                size: wide ? 196 : 168,
                strokeWidth: wide ? 14 : 12,
              );

              final details = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Screen time',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DeltaBadge(current: _today, previous: _yesterday),
                      if (_goal > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            _today >= _goal
                                ? '${formatDuration(_today - _goal)} over goal'
                                : '${formatDuration(_goal - _today)} left today',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                    ],
                  ),
                  if (_goal > 0) ...[
                    const SizedBox(height: AppSpacing.lg),
                    UsageBar(usedMs: _today, goalMs: _goal),
                  ] else ...[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Set a daily goal to see how close you are to your limit.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                    ),
                  ],
                ],
              );

              if (!wide) {
                return Column(
                  children: [
                    ring,
                    const SizedBox(height: AppSpacing.xl),
                    Align(alignment: Alignment.centerLeft, child: details),
                  ],
                );
              }
              return Row(
                children: [
                  ring,
                  const SizedBox(width: AppSpacing.xxl),
                  Expanded(child: details),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Secondary metrics ───────────────────────────────────────────────
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
                icon: Icons.calendar_month_rounded,
                label: 'Past 30 days',
                value: formatDuration(_last30DaysTotal),
              ),
              AppStatTile(
                icon: Icons.analytics_outlined,
                label: 'Daily average',
                value: formatDuration(_last30DaysTotal ~/ 30),
              ),
              AppStatTile(
                icon: Icons.center_focus_strong_rounded,
                label: 'Focus sessions today',
                value: '$_focusToday',
                accent: palette.success,
              ),
              AppStatTile(
                icon: Icons.timer_off_outlined,
                label: 'Idle today',
                value: formatDuration(_idleToday),
                accent: palette.idle,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Weekly chart + app share ────────────────────────────────────────
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 900;
            final chart = _buildWeeklyChartCard();
            final share = _buildAppShareCard();
            if (!isWide) {
              return Column(
                children: [
                  chart,
                  const SizedBox(height: AppSpacing.lg),
                  share,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: chart),
                const SizedBox(width: AppSpacing.lg),
                Expanded(flex: 3, child: share),
              ],
            );
          },
        ),

        if (_showHint && _untracked > 0) ...[
          const SizedBox(height: AppSpacing.lg),
          AppInfoBanner(
            title: "Some apps aren't being tracked",
            message:
                'They show up as "unknown". Quit & reopen those apps (or log out/in), '
                "then they'll be identified by name.",
            icon: Icons.help_outline_rounded,
            action: TextButton(
              onPressed: () => setState(() => _showHint = false),
              child: const Text('Got it'),
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.xl),

        // ── Most used apps ──────────────────────────────────────────────────
        AppSectionHeader(
          title: 'Most used apps',
          subtitle: friendlyDate,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          trailing: !isTodaySelected
              ? TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectedDate = DateTime.now();
                      _weekOffset = 0;
                    });
                    _load();
                  },
                  icon: const Icon(Icons.today, size: 18),
                  label: const Text('Back to Today'),
                )
              : null,
        ),
        AppSectionCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: _perApp.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Center(
                    child: Text(
                      'No app usage recorded for $friendlyDate.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < _perApp.length; i++) ...[
                      Builder(
                        builder: (context) {
                          final a = _perApp[i];
                          final appName = a['app_name'] as String? ?? a['app'] as String;
                          return AppListTile(
                            name: appName,
                            ms: (a['t'] as int?) ?? 0,
                            maxMs: maxApp,
                            color: palette.colorAt(i),
                            iconPath: AppIconService.resolve(a['app'] as String),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AppDetailScreen(
                                  app: a['app'] as String,
                                  name: appName,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      if (i != _perApp.length - 1)
                        const Divider(indent: AppSpacing.lg, endIndent: AppSpacing.lg),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  Widget _buildWeeklyChartCard() {
    final weekTitle = _weekOffset == 0
        ? 'This Week'
        : (_weekOffset == 1 ? 'Last Week' : '$_weekOffset Weeks Ago');

    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                weekTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded, size: 22),
                    tooltip: 'Previous Week',
                    onPressed: () {
                      setState(() {
                        _weekOffset += 1;
                      });
                      _load();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded, size: 22),
                    tooltip: 'Next Week',
                    onPressed: _weekOffset > 0
                        ? () {
                            setState(() {
                              _weekOffset -= 1;
                            });
                            _load();
                          }
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 190,
            child: DayChart(
              data: _weekData,
              selectedDate: _selectedDate,
              onDaySelected: (dt) {
                setState(() {
                  _selectedDate = dt;
                });
                _load();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppShareCard() {
    return AppSectionCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'App Share',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            _formatDateHeader(_selectedDate),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppPieChart(
            perApp: _perApp,
            idleMs: _idleToday,
          ),
          const SizedBox(height: AppSpacing.md),
          _buildActiveIdleBreakdownRow(),
        ],
      ),
    );
  }

  Widget _buildActiveIdleBreakdownRow() {
    final palette = AppPalette.of(context);
    final activeMs = _perApp.fold<int>(0, (sum, a) => sum + ((a['t'] as int?) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Active: ${formatDuration(activeMs)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: palette.idle,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Idle: ${formatDuration(_idleToday)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
