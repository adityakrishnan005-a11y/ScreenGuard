import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/widgets/usage_bar.dart';
import 'package:screenguard/widgets/app_list.dart';
import 'package:screenguard/widgets/day_chart.dart';
import 'package:screenguard/widgets/app_pie_chart.dart';
import 'package:screenguard/widgets/delta_badge.dart';
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
  List<Map<String, dynamic>> _perApp = [];
  List<Map<String, dynamic>> _weekData = [];
  final int _goal = 8 * 3600 * 1000;
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

  void _load() {
    final db = Provider.of<DatabaseService>(context, listen: false);
    setState(() {
      _today = db.todayTotalMs();
      _yesterday = db.yesterdayTotalMs();
      _last30DaysTotal = db.last30DaysTotalMs();
      _weekData = db.getWeekData(weekOffset: _weekOffset);
      _perApp = db.perAppForDate(_selectedDate);
      _idleToday = db.getIdleTimeForDate(_selectedDate);
      _untracked = db.recentUnknownSessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxApp = _perApp.isEmpty ? 0 : ((_perApp.first['t'] as int?) ?? 0);
    final isTodaySelected = _isSameDay(_selectedDate, DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('ScreenGuard — Digital Wellbeing for Linux', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1150),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: [
                // Top Hero Cards Grid
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 850;
                    return Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Card 1: Today Overview
                            Expanded(
                              flex: isWide ? 3 : 1,
                              child: _buildHeroCard(
                                title: 'Today',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        FittedBox(
                                          child: Text(
                                            formatDuration(_today),
                                            style: Theme.of(context)
                                                .textTheme
                                                .displaySmall
                                                ?.copyWith(fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                        DeltaBadge(current: _today, previous: _yesterday),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    UsageBar(usedMs: _today, goalMs: _goal),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            // Card 2: 30-Day Total & Daily Average
                            Expanded(
                              flex: isWide ? 3 : 1,
                              child: _buildHeroCard(
                                title: 'Past 30 Days',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      formatDuration(_last30DaysTotal),
                                      style: Theme.of(context)
                                          .textTheme
                                          .displaySmall
                                          ?.copyWith(fontWeight: FontWeight.bold, color: Colors.teal),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Avg: ${formatDuration(_last30DaysTotal ~/ 30)} / day',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Weekly Bar Chart Slider + App Share Donut Chart
                        if (isWide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Card 3: Interactive Weekly Bar Chart Slider
                              Expanded(
                                flex: 4,
                                child: _buildWeeklyChartCard(),
                              ),
                              const SizedBox(width: 16),
                              // Card 4: App Share Pie Chart
                              Expanded(
                                flex: 3,
                                child: _buildHeroCard(
                                  title: 'App Share (${_formatDateHeader(_selectedDate)})',
                                  child: Column(
                                    children: [
                                      AppPieChart(
                                        perApp: _perApp,
                                        idleMs: _idleToday,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildActiveIdleBreakdownRow(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          )
                        else
                          Column(
                            children: [
                              _buildWeeklyChartCard(),
                              const SizedBox(height: 16),
                              _buildHeroCard(
                                title: 'App Share (${_formatDateHeader(_selectedDate)})',
                                child: Column(
                                  children: [
                                    AppPieChart(
                                      perApp: _perApp,
                                      idleMs: _idleToday,
                                    ),
                                    const SizedBox(height: 12),
                                    _buildActiveIdleBreakdownRow(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                      ],
                    );
                  },
                ),

                if (_showHint && _untracked > 0) ...[
                  const SizedBox(height: 16),
                  Card(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Some apps aren\'t being tracked',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text(
                              'They show up as "unknown". Quit & reopen those apps '
                              '(or log out/in), then they\'ll be identified by name.'),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => setState(() => _showHint = false),
                              child: const Text('Got it'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // Per-Day App List Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Most Used Apps (${_formatDateHeader(_selectedDate)})',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (!isTodaySelected)
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _selectedDate = DateTime.now();
                            _weekOffset = 0;
                          });
                          _load();
                        },
                        icon: const Icon(Icons.today, size: 18),
                        label: const Text('Back to Today'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                if (_perApp.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Center(
                      child: Text(
                        'No app usage recorded for ${_formatDateHeader(_selectedDate)}.',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                else
                  ...List.generate(_perApp.length, (index) {
                    final a = _perApp[index];
                    final appName =
                        a['app_name'] as String? ?? a['app'] as String;
                    final color = getAppColor(index);
                    return AppListTile(
                      name: appName,
                      ms: (a['t'] as int?) ?? 0,
                      maxMs: maxApp,
                      color: color,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => AppDetailScreen(
                          app: a['app'] as String,
                          name: appName,
                        ),
                      )),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyChartCard() {
    final weekTitle = _weekOffset == 0
        ? 'This Week'
        : (_weekOffset == 1 ? 'Last Week' : '$_weekOffset Weeks Ago');

    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  weekTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left_rounded, size: 22),
                      tooltip: 'Previous Week',
                      splashRadius: 18,
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
                      splashRadius: 18,
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
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
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
      ),
    );
  }

  Widget _buildActiveIdleBreakdownRow() {
    final activeMs = _perApp.fold<int>(0, (sum, a) => sum + ((a['t'] as int?) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(10),
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
                decoration: const BoxDecoration(
                  color: Colors.teal,
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
                decoration: const BoxDecoration(
                  color: Color(0xFF78909C),
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

  Widget _buildHeroCard({required String title, required Widget child}) {
    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
