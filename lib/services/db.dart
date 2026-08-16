import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

class DatabaseService {
  late final Database db;
  late final String path;

  String _resolvePath() {
    final home = Platform.environment['HOME'];
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = xdg != null
        ? '$xdg/screenguard'
        : '${home ?? '/tmp'}/.local/share/screenguard';
    Directory(base).createSync(recursive: true);
    return '$base/usage.db';
  }

  void init({String? path}) {
    this.path = path ?? _resolvePath();
    db = sqlite3.open(this.path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA busy_timeout=5000;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app TEXT NOT NULL,
        app_name TEXT,
        title TEXT,
        pid INTEGER,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        duration_ms INTEGER,
        idle INTEGER DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS app_limits (
        app TEXT PRIMARY KEY,
        limit_ms INTEGER NOT NULL,
        temp_extension_ms INTEGER DEFAULT 0,
        enabled INTEGER DEFAULT 1
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS distracting_apps (
        app TEXT PRIMARY KEY
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS focus_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        duration_minutes INTEGER NOT NULL,
        completed INTEGER DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS active_focus_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        end_time_ms INTEGER NOT NULL,
        duration_minutes INTEGER NOT NULL
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app);');
    _migrateCorruptedAppNames();
  }

  void _migrateCorruptedAppNames() {
    try {
      db.execute("UPDATE sessions SET app_name = 'Firefox' WHERE (app = 'org.mozilla.firefox' OR app = 'firefox') AND (app_name LIKE 'Open the Profile Manager%' OR app_name LIKE 'Open a New %' OR app_name IS NULL);");
      db.execute("UPDATE sessions SET app_name = 'Chromium' WHERE (app = 'chromium-browser' OR app = 'chromium') AND (app_name LIKE 'Open a New %' OR app_name IS NULL);");
      db.execute("UPDATE sessions SET app_name = 'Files' WHERE app LIKE '%nautilus%' AND (app_name = 'New Window' OR app_name IS NULL);");
      db.execute("UPDATE sessions SET app_name = 'Terminal' WHERE app LIKE '%ptyxis%' AND (app_name = 'Preferences' OR app_name LIKE 'New %' OR app_name IS NULL);");
      db.execute("UPDATE sessions SET app_name = 'Text Editor' WHERE app LIKE '%texteditor%' AND (app_name = 'New Window' OR app_name IS NULL);");
    } catch (_) {}
  }

  int openSession({
    required String app,
    String? appName,
    String? title,
    int? pid,
    required int startedAt,
    required bool idle,
  }) {
    db.execute(
      'INSERT INTO sessions (app, app_name, title, pid, started_at, idle) VALUES (?,?,?,?,?,?)',
      [app, appName, title, pid, startedAt, idle ? 1 : 0],
    );
    return db.lastInsertRowId;
  }

  void closeSession(int id, int endedAt) {
    final rows = db.select('SELECT started_at FROM sessions WHERE id = ?', [id]);
    if (rows.isEmpty) return;
    final started = rows.first['started_at'] as int;
    final duration = endedAt - started;
    db.execute(
      'UPDATE sessions SET ended_at = ?, duration_ms = ? WHERE id = ?',
      [endedAt, duration, id],
    );
  }

  static const _excludedAppsFilter =
      "app NOT IN ('unknown', 'com.example.screenguard', 'screenguard') AND app NOT LIKE 'window:%'";

  int todayTotalMs() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COALESCE(SUM(duration_ms),0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ?;",
      [start],
    );
    return rows.first['t'] as int;
  }

  int yesterdayTotalMs() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final yesterdayEnd = todayStart.millisecondsSinceEpoch - 1;

    final rows = db.select(
      "SELECT COALESCE(SUM(duration_ms),0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ?;",
      [yesterdayStart, yesterdayEnd],
    );
    return rows.first['t'] as int;
  }

  List<Map<String, dynamic>> perAppToday({int limit = 10}) {
    return perAppForDate(DateTime.now(), limit: limit);
  }

  List<Map<String, dynamic>> last7Days() {
    return getWeekData(weekOffset: 0);
  }

  List<Map<String, dynamic>> appHistory(String app, {int days = 7}) {
    return db
        .select(
          "SELECT date(started_at/1000,'unixepoch','localtime') AS d, SUM(duration_ms) AS t FROM sessions WHERE idle=0 AND app = ? AND started_at >= strftime('%s','now',?,'start of day')*1000 GROUP BY d ORDER BY d;",
          [app, '-${days - 1} day'],
        )
        .cast<Map<String, dynamic>>();
  }

  int recentUnknownSessions({int minutes = 10}) {
    final rows = db.select(
      "SELECT COUNT(*) AS t FROM sessions WHERE app = 'unknown' AND started_at >= (strftime('%s','now') - ?)*1000;",
      [minutes * 60],
    );
    return rows.first['t'] as int;
  }

  int getAppTodayMs(String app) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COALESCE(SUM(duration_ms),0) AS t FROM sessions WHERE idle=0 AND app = ? AND started_at >= ?;",
      [app, start],
    );
    return rows.first['t'] as int;
  }

  Map<String, dynamic>? getAppLimit(String app) {
    final rows = db.select('SELECT * FROM app_limits WHERE app = ?', [app]);
    if (rows.isEmpty) return null;
    return rows.first.cast<String, dynamic>();
  }

  List<Map<String, dynamic>> getAllAppLimits() {
    return db.select('SELECT * FROM app_limits').cast<Map<String, dynamic>>();
  }

  void setAppLimit(String app, int limitMs, {bool enabled = true}) {
    db.execute(
      'INSERT INTO app_limits (app, limit_ms, temp_extension_ms, enabled) VALUES (?, ?, 0, ?) ON CONFLICT(app) DO UPDATE SET limit_ms = ?, enabled = ?;',
      [app, limitMs, enabled ? 1 : 0, limitMs, enabled ? 1 : 0],
    );
  }

  void addTempExtension(String app, int extensionMs) {
    db.execute(
      'UPDATE app_limits SET temp_extension_ms = temp_extension_ms + ? WHERE app = ?',
      [extensionMs, app],
    );
  }

  void deleteAppLimit(String app) {
    db.execute('DELETE FROM app_limits WHERE app = ?', [app]);
  }

  Set<String> getDistractingApps() {
    final rows = db.select('SELECT app FROM distracting_apps');
    return rows.map((r) => r['app'] as String).toSet();
  }

  void toggleDistractingApp(String app) {
    final exists = db.select('SELECT app FROM distracting_apps WHERE app = ?', [app]);
    if (exists.isNotEmpty) {
      db.execute('DELETE FROM distracting_apps WHERE app = ?', [app]);
    } else {
      db.execute('INSERT INTO distracting_apps (app) VALUES (?)', [app]);
    }
  }

  bool isDistractingApp(String app) {
    final rows = db.select('SELECT app FROM distracting_apps WHERE app = ?', [app]);
    return rows.isNotEmpty;
  }

  void startFocusSession(int durationMinutes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final endTime = now + (durationMinutes * 60 * 1000);
    db.execute(
      'INSERT INTO active_focus_state (id, end_time_ms, duration_minutes) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET end_time_ms = ?, duration_minutes = ?;',
      [endTime, durationMinutes, endTime, durationMinutes],
    );
    db.execute(
      'INSERT INTO focus_sessions (started_at, duration_minutes, completed) VALUES (?, ?, 0)',
      [now, durationMinutes],
    );
  }

  Map<String, dynamic>? getActiveFocusState() {
    final rows = db.select('SELECT * FROM active_focus_state WHERE id = 1');
    if (rows.isEmpty) return null;
    final state = rows.first.cast<String, dynamic>();
    final endTime = state['end_time_ms'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= endTime) {
      db.execute('DELETE FROM active_focus_state WHERE id = 1');
      db.execute(
        "UPDATE focus_sessions SET ended_at = ?, completed = 1 WHERE ended_at IS NULL AND duration_minutes = ?",
        [endTime, state['duration_minutes']],
      );
      return null;
    }
    return state;
  }

  void cancelFocusSession() {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute('DELETE FROM active_focus_state WHERE id = 1');
    db.execute('UPDATE focus_sessions SET ended_at = ?, completed = 0 WHERE ended_at IS NULL', [now]);
  }

  int getCompletedFocusSessionsToday() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COUNT(*) AS t FROM focus_sessions WHERE completed = 1 AND started_at >= ?;",
      [start],
    );
    return rows.first['t'] as int;
  }

  List<Map<String, dynamic>> allTrackedApps() {
    return db
        .select(
          "SELECT app, COALESCE(app_name, app) AS app_name, SUM(duration_ms) AS t FROM sessions WHERE $_excludedAppsFilter GROUP BY app ORDER BY app_name ASC;",
        )
        .cast<Map<String, dynamic>>();
  }

  List<Map<String, dynamic>> perAppForDate(DateTime date, {int limit = 10}) {
    final start = DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999).millisecondsSinceEpoch;

    return db
        .select(
          "SELECT app, app_name, SUM(duration_ms) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ? GROUP BY app ORDER BY t DESC LIMIT ?;",
          [start, end, limit],
        )
        .cast<Map<String, dynamic>>();
  }

  List<Map<String, dynamic>> getWeekData({int weekOffset = 0}) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final endOfWindow = todayStart.subtract(Duration(days: weekOffset * 7));
    final startOfWindow = endOfWindow.subtract(const Duration(days: 6));

    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < 7; i++) {
      final day = startOfWindow.add(Duration(days: i));
      final dayStart = day.millisecondsSinceEpoch;
      final dayEnd = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;

      final rows = db.select(
        "SELECT COALESCE(SUM(duration_ms),0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ?;",
        [dayStart, dayEnd],
      );
      final totalMs = rows.first['t'] as int;
      final dateStr = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      result.add({'d': dateStr, 't': totalMs, 'date': day});
    }
    return result;
  }

  int last30DaysTotalMs() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 29)).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COALESCE(SUM(duration_ms),0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ?;",
      [start],
    );
    return rows.first['t'] as int;
  }

  void close() => db.dispose();
}
