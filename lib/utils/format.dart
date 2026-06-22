String formatDuration(int ms) {
  final totalMin = (ms / 60000).floor();
  final h = (totalMin / 60).floor();
  final m = totalMin % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '<1m';
}

double percentChange(int current, int previous) {
  if (previous == 0) return current > 0 ? 100 : 0;
  return ((current - previous) / previous) * 100;
}
