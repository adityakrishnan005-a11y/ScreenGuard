import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

const List<Color> appPalette = [
  Color(0xFF00B4D8), // Cyan / Teal
  Color(0xFF7209B7), // Violet / Purple
  Color(0xFF38B000), // Emerald Green
  Color(0xFFFFA200), // Amber Gold
  Color(0xFFF72585), // Coral Pink
  Color(0xFF4CC9F0), // Sky Blue
  Color(0xFF9E9E9E), // Slate / Grey
];

Color getAppColor(int index) {
  return appPalette[index % appPalette.length];
}

class AppPieChart extends StatefulWidget {
  final List<Map<String, dynamic>> perApp;
  final int idleMs;
  const AppPieChart({super.key, required this.perApp, this.idleMs = 0});

  @override
  State<AppPieChart> createState() => _AppPieChartState();
}

class _AppPieChartState extends State<AppPieChart> {
  int _touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
    final activeMs = widget.perApp.fold<int>(0, (sum, a) => sum + (a['t'] as int));
    final idleMs = widget.idleMs;
    final totalMs = activeMs + idleMs;

    if (totalMs == 0) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(24.0),
        child: Text('No active usage today', style: TextStyle(color: Colors.grey)),
      ));
    }

    final sections = <PieChartSectionData>[];
    final displayApps = widget.perApp.take(4).toList();
    final otherMs = widget.perApp.skip(4).fold<int>(0, (sum, a) => sum + (a['t'] as int));

    for (var i = 0; i < displayApps.length; i++) {
      final item = displayApps[i];
      final ms = item['t'] as int;
      final pct = (ms / totalMs * 100);
      final isTouched = i == _touchedIndex;
      final radius = isTouched ? 44.0 : 36.0;
      final color = getAppColor(i);

      sections.add(PieChartSectionData(
        color: color,
        value: ms.toDouble(),
        title: pct >= 8 ? '${pct.toStringAsFixed(0)}%' : '',
        radius: radius,
        titleStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ));
    }

    if (otherMs > 0) {
      final pct = (otherMs / totalMs * 100);
      final isTouched = displayApps.length == _touchedIndex;
      final color = getAppColor(displayApps.length);
      sections.add(PieChartSectionData(
        color: color,
        value: otherMs.toDouble(),
        title: pct >= 8 ? '${pct.toStringAsFixed(0)}%' : '',
        radius: isTouched ? 44.0 : 36.0,
        titleStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ));
    }

    const idleColor = Color(0xFF78909C); // Blue Grey / Slate
    if (idleMs > 0) {
      final pct = (idleMs / totalMs * 100);
      final idleIndex = displayApps.length + (otherMs > 0 ? 1 : 0);
      final isTouched = idleIndex == _touchedIndex;
      sections.add(PieChartSectionData(
        color: idleColor,
        value: idleMs.toDouble(),
        title: pct >= 8 ? '${pct.toStringAsFixed(0)}%' : '',
        radius: isTouched ? 44.0 : 36.0,
        titleStyle: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ));
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 130,
          child: PieChart(
            PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (FlTouchEvent event, pieTouchResponse) {
                  setState(() {
                    if (!event.isInterestedForInteractions ||
                        pieTouchResponse == null ||
                        pieTouchResponse.touchedSection == null) {
                      _touchedIndex = -1;
                      return;
                    }
                    _touchedIndex =
                        pieTouchResponse.touchedSection!.touchedSectionIndex;
                  });
                },
              ),
              borderData: FlBorderData(show: false),
              sectionsSpace: 2,
              centerSpaceRadius: 28,
              sections: sections,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            for (var i = 0; i < displayApps.length; i++)
              _LegendItem(
                color: getAppColor(i),
                label: displayApps[i]['app_name'] as String? ??
                    displayApps[i]['app'] as String,
              ),
            if (otherMs > 0)
              _LegendItem(
                color: getAppColor(displayApps.length),
                label: 'Other',
              ),
            if (idleMs > 0)
              const _LegendItem(
                color: idleColor,
                label: 'Idle / Away',
              ),
          ],
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 90),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
