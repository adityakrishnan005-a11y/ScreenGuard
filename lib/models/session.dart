class Session {
  final int? id;
  final String app;
  final String? appName;
  final String? title;
  final int? pid;
  final int startedAt;
  final int? endedAt;
  final int? durationMs;
  final bool idle;

  const Session({
    this.id,
    required this.app,
    this.appName,
    this.title,
    this.pid,
    required this.startedAt,
    this.endedAt,
    this.durationMs,
    this.idle = false,
  });

  factory Session.fromMap(Map<String, dynamic> m) => Session(
        id: m['id'] as int?,
        app: m['app'] as String,
        appName: m['app_name'] as String?,
        title: m['title'] as String?,
        pid: m['pid'] as int?,
        startedAt: m['started_at'] as int,
        endedAt: m['ended_at'] as int?,
        durationMs: m['duration_ms'] as int?,
        idle: (m['idle'] as int? ?? 0) == 1,
      );
}
