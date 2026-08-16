import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:screenguard/utils/format.dart';

class DayChart extends StatelessWidget {
  final List<Map<String, dynamic>> data;
  final DateTime? selectedDate;
  final ValueChanged<DateTime>? onDaySelected;

  const DayChart({
    super.key,
    required this.data,
    this.selectedDate,
    this.onDaySelected,
  });

  bool _isSameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const Center(
          child: Text('No weekly data yet', style: TextStyle(color: Colors.grey)));
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;

    final groups = <BarChartGroupData>[];
    double maxRawY = 1.0;

    for (var i = 0; i < data.length; i++) {
      final hours = (data[i]['t'] as int) / 3600000;
      if (hours > maxRawY) maxRawY = hours;
    }

    final maxY = (maxRawY * 1.25).ceilToDouble();

    for (var i = 0; i < data.length; i++) {
      final hours = (data[i]['t'] as int) / 3600000;
      final dt = data[i]['date'] as DateTime? ?? DateTime.tryParse(data[i]['d'] as String? ?? '');
      final isSelected = _isSameDay(selectedDate, dt);

      groups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: hours,
            width: isSelected ? 20 : 16,
            color: isSelected ? Colors.amber[700] : primaryColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            backDrawRodData: BackgroundBarChartRodData(
              show: true,
              toY: maxY,
              color: primaryColor.withValues(alpha: 0.08),
            ),
          )
        ],
      ));
    }

    final interval = maxY > 4 ? 2.0 : 1.0;

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        barGroups: groups,
        maxY: maxY,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final item = data[groupIndex];
              final totalMs = item['t'] as int;
              final dt = item['date'] as DateTime? ?? DateTime.tryParse(item['d'] as String? ?? '');
              const dayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
              final dayName = dt != null ? dayNames[dt.weekday] : '';

              return BarTooltipItem(
                '$dayName\n${formatDuration(totalMs)}',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
          touchCallback: (FlTouchEvent event, barTouchResponse) {
            if (event is FlTapUpEvent && barTouchResponse != null && barTouchResponse.spot != null) {
              final idx = barTouchResponse.spot!.touchedBarGroupIndex;
              if (idx >= 0 && idx < data.length && onDaySelected != null) {
                final dt = data[idx]['date'] as DateTime? ?? DateTime.tryParse(data[idx]['d'] as String? ?? '');
                if (dt != null) {
                  onDaySelected!(dt);
                }
              }
            }
          },
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: interval,
              getTitlesWidget: (value, _) {
                if (value % interval != 0) return const SizedBox.shrink();
                return Text(
                  '${value.toInt()}h',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, _) {
                final idx = value.toInt();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                final item = data[idx];
                final dt = item['date'] as DateTime? ?? DateTime.tryParse(item['d'] as String? ?? '');
                final isSelected = _isSameDay(selectedDate, dt);
                const names = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                final wdName = dt != null ? names[dt.weekday] : '';

                return Padding(
                  padding: const EdgeInsets.only(top: 6.0),
                  child: Text(
                    wdName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected
                          ? Colors.amber[800]
                          : (isDark ? Colors.grey[300] : Colors.grey[700]),
                    ),
                  ),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: interval,
          getDrawingHorizontalLine: (value) => FlLine(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
            strokeWidth: 1,
            dashArray: [4, 4],
          ),
        ),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}
