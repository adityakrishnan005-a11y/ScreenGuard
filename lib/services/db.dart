import 'dart:ffi';
import 'dart:io';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

bool _sqliteInitialized = false;

void _ensureSqliteLoaded() {
  if (_sqliteInitialized) return;
  _sqliteInitialized = true;
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      final candidates = [
        'libsqlite3.so.0',
        'libsqlite3.so',
        '/usr/lib64/libsqlite3.so.0',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
        '/usr/lib/libsqlite3.so.0',
      ];
      for (final name in candidates) {
        try {
          return DynamicLibrary.open(name);
        } catch (_) {}
      }
      return DynamicLibrary.process();
    });
  }
}

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

  bool _initialized = false;

  void init({String? path}) {
    if (_initialized) return; // Guard against double-init
    _initialized = true;
    _ensureSqliteLoaded();
    this.path = path ?? _resolvePath();
    db = sqlite3.open(this.path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA busy_timeout=5000;');
    db.execute('PRAGMA synchronous=NORMAL;');
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
        duration_minutes INTEGER NOT NULL,
        is_paused INTEGER DEFAULT 0,
        remaining_seconds INTEGER DEFAULT 0
      );
    ''');
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN is_paused INTEGER DEFAULT 0;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN remaining_seconds INTEGER DEFAULT 0;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN current_cycle INTEGER DEFAULT 1;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN total_cycles INTEGER DEFAULT 1;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN is_break INTEGER DEFAULT 0;');
    } catch (_) {}
    try {
      db.execute('ALTER TABLE active_focus_state ADD COLUMN break_duration_minutes INTEGER DEFAULT 5;');
    } catch (_) {}
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app);');
    _migrateCorruptedAppNames();
    _purgeDesktopShellSessions();
  }

  /// One-time cleanup for history recorded before desktop-shell windows
  /// were excluded: those rows are wallpaper/panel focus time, not app use.
  void _purgeDesktopShellSessions() {
    try {
      final placeholders = desktopShellApps.map((_) => '?').join(',');
      db.execute(
        'DELETE FROM sessions WHERE app IN ($placeholders);',
        desktopShellApps,
      );
    } catch (_) {}
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
    final duration = endedAt > started ? endedAt - started : 0;
    db.execute(
      'UPDATE sessions SET ended_at = ?, duration_ms = ? WHERE id = ?',
      [endedAt, duration, id],
    );
  }

  /// Desktop shell components whose windows represent the wallpaper/panel,
  /// not real app usage. Tracked like `unknown`: excluded from every total
  /// and never given an open session. Lowercase app ids (backends lowercase).
  /// NOTE: file managers (caja, nemo, nautilus, pcmanfm) are deliberately NOT
  /// here — only their desktop-only counterparts — so Files tracking keeps
  /// working on MATE/Cinnamon/LXQt.
  static const desktopShellApps = [
    'xfdesktop', // XFCE desktop
    'nemo-desktop', // Cinnamon desktop (file manager is `nemo`)
    'plasmashell', // KDE Plasma shell
    'gnome-shell', // GNOME shell
    'mutter', // GNOME compositor
  ];

  static String get _excludedAppsFilter {
    final shells = desktopShellApps.map((a) => "'$a'").join(',');
    return "app NOT IN ('unknown', 'com.example.screenguard', 'screenguard', $shells) AND app NOT LIKE 'window:%'";
  }

  int todayTotalMs() {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ?;",
      [nowMs, start],
    );
    return rows.first['t'] as int;
  }

  int yesterdayTotalMs() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final yesterdayEnd = todayStart.millisecondsSinceEpoch - 1;

    final rows = db.select(
      "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ?;",
      [yesterdayEnd, yesterdayStart, yesterdayEnd],
    );
    return rows.first['t'] as int;
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

  int getAppTodayMs(String app, {List<String>? aliases}) {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final appList = (aliases != null && aliases.isNotEmpty)
        ? (aliases.contains(app) ? aliases : [app, ...aliases])
        : [app];
    final placeholders = List.filled(appList.length, '?').join(',');
    final rows = db.select(
      "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=0 AND app IN ($placeholders) AND started_at >= ?;",
      [nowMs, ...appList, start],
    );
    return rows.first['t'] as int;
  }

  Map<String, dynamic>? getAppLimit(String app, {List<String>? aliases}) {
    var rows = db.select('SELECT * FROM app_limits WHERE app = ?', [app]);
    if (rows.isNotEmpty) return rows.first.cast<String, dynamic>();

    if (aliases != null) {
      for (final alias in aliases) {
        if (alias == app) continue;
        rows = db.select('SELECT * FROM app_limits WHERE app = ?', [alias]);
        if (rows.isNotEmpty) return rows.first.cast<String, dynamic>();
      }
    }
    return null;
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
    // Always read from the DB: this is a tiny table and the daemon relies on
    // it every tick. Caching it meant that removing an app from the Focus
    // list had no effect until the daemon was restarted — real users saw the
    // app keep being blocked after they had unchecked it.
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

  bool isDistractingApp(String app, {List<String>? aliases}) {
    final set = getDistractingApps();
    if (set.contains(app)) return true;
    if (aliases != null) {
      for (final a in aliases) {
        if (set.contains(a)) return true;
      }
    }
    return false;
  }

  void startFocusSession(int durationMinutes, {int? totalCycles, int? breakMinutes}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final endTime = now + (durationMinutes * 60 * 1000);
    final remainingSec = durationMinutes * 60;
    final cycles = totalCycles ?? (isPomodoroLoopEnabled() ? getPomodoroCyclesCount() : 1);
    final brkMins = breakMinutes ?? getPomodoroBreakMinutes();

    db.execute(
      'INSERT INTO active_focus_state (id, end_time_ms, duration_minutes, is_paused, remaining_seconds, current_cycle, total_cycles, is_break, break_duration_minutes) VALUES (1, ?, ?, 0, ?, 1, ?, 0, ?) ON CONFLICT(id) DO UPDATE SET end_time_ms = ?, duration_minutes = ?, is_paused = 0, remaining_seconds = ?, current_cycle = 1, total_cycles = ?, is_break = 0, break_duration_minutes = ?;',
      [
        endTime, durationMinutes, remainingSec, cycles, brkMins,
        endTime, durationMinutes, remainingSec, cycles, brkMins
      ],
    );
    db.execute(
      'INSERT INTO focus_sessions (started_at, duration_minutes, completed) VALUES (?, ?, 0)',
      [now, durationMinutes],
    );
  }

  void pauseFocusSession() {
    final state = getActiveFocusState();
    if (state == null || (state['is_paused'] as int? ?? 0) == 1) return;
    final endTime = state['end_time_ms'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    final remainingSec = ((endTime - now) / 1000).ceil().clamp(0, 999999);
    db.execute(
      'UPDATE active_focus_state SET is_paused = 1, remaining_seconds = ? WHERE id = 1;',
      [remainingSec],
    );
  }

  void resumeFocusSession() {
    final rows = db.select('SELECT * FROM active_focus_state WHERE id = 1');
    if (rows.isEmpty) return;
    final state = rows.first.cast<String, dynamic>();
    if ((state['is_paused'] as int? ?? 0) == 0) return;
    final isBreak = (state['is_break'] as int? ?? 0) == 1;
    final fallbackMins = isBreak
        ? (state['break_duration_minutes'] as int? ?? 5)
        : (state['duration_minutes'] as int? ?? 25);
    final remainingSec = (state['remaining_seconds'] as int?) ?? (fallbackMins * 60);
    final now = DateTime.now().millisecondsSinceEpoch;
    final newEndTime = now + (remainingSec * 1000);
    db.execute(
      'UPDATE active_focus_state SET is_paused = 0, end_time_ms = ? WHERE id = 1;',
      [newEndTime],
    );
  }

  Map<String, dynamic>? getActiveFocusState() {
    final rows = db.select('SELECT * FROM active_focus_state WHERE id = 1');
    if (rows.isEmpty) return null;
    final state = rows.first.cast<String, dynamic>();
    final isPaused = (state['is_paused'] as int? ?? 0) == 1;
    if (isPaused) {
      return state;
    }
    final endTime = state['end_time_ms'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= endTime) {
      final isBreak = (state['is_break'] as int? ?? 0) == 1;
      final currentCycle = (state['current_cycle'] as int? ?? 1);
      final totalCycles = (state['total_cycles'] as int? ?? 1);
      final workDurationMins = state['duration_minutes'] as int;
      final breakMins = state['break_duration_minutes'] as int? ?? 5;

      if (!isBreak) {
        // Focus phase completed
        db.execute(
          "UPDATE focus_sessions SET ended_at = ?, completed = 1 WHERE ended_at IS NULL AND duration_minutes = ?",
          [endTime, workDurationMins],
        );

        if (currentCycle < totalCycles) {
          if (breakMins > 0) {
            // Transition to Break phase
            final breakEndMs = now + (breakMins * 60 * 1000);
            final breakSec = breakMins * 60;
            db.execute(
              'UPDATE active_focus_state SET is_break = 1, end_time_ms = ?, remaining_seconds = ? WHERE id = 1;',
              [breakEndMs, breakSec],
            );
            final updated = db.select('SELECT * FROM active_focus_state WHERE id = 1');
            return updated.first.cast<String, dynamic>();
          } else {
            // No break duration configured: transition directly to next Focus cycle
            final nextCycle = currentCycle + 1;
            final nextWorkEndMs = now + (workDurationMins * 60 * 1000);
            final nextWorkSec = workDurationMins * 60;
            db.execute(
              'UPDATE active_focus_state SET is_break = 0, current_cycle = ?, end_time_ms = ?, remaining_seconds = ? WHERE id = 1;',
              [nextCycle, nextWorkEndMs, nextWorkSec],
            );
            db.execute(
              'INSERT INTO focus_sessions (started_at, duration_minutes, completed) VALUES (?, ?, 0)',
              [now, workDurationMins],
            );
            final updated = db.select('SELECT * FROM active_focus_state WHERE id = 1');
            return updated.first.cast<String, dynamic>();
          }
        } else {
          // All cycles completed
          db.execute('DELETE FROM active_focus_state WHERE id = 1');
          return null;
        }
      } else {
        // Break phase completed -> transition to next Focus cycle
        final nextCycle = currentCycle + 1;
        if (nextCycle <= totalCycles) {
          final nextWorkEndMs = now + (workDurationMins * 60 * 1000);
          final nextWorkSec = workDurationMins * 60;
          db.execute(
            'UPDATE active_focus_state SET is_break = 0, current_cycle = ?, end_time_ms = ?, remaining_seconds = ? WHERE id = 1;',
            [nextCycle, nextWorkEndMs, nextWorkSec],
          );
          db.execute(
            'INSERT INTO focus_sessions (started_at, duration_minutes, completed) VALUES (?, ?, 0)',
            [now, workDurationMins],
          );
          final updated = db.select('SELECT * FROM active_focus_state WHERE id = 1');
          return updated.first.cast<String, dynamic>();
        } else {
          db.execute('DELETE FROM active_focus_state WHERE id = 1');
          return null;
        }
      }
    }
    return state;
  }

  void cancelFocusSession() {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute('DELETE FROM active_focus_state WHERE id = 1');
    db.execute('UPDATE focus_sessions SET ended_at = ?, completed = 0 WHERE ended_at IS NULL', [now]);
  }

  Map<String, dynamic>? getLastFocusSession() {
    final rows = db.select('SELECT * FROM focus_sessions ORDER BY id DESC LIMIT 1');
    if (rows.isEmpty) return null;
    return rows.first.cast<String, dynamic>();
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final effectiveEnd = end < nowMs ? end : nowMs;

    return db
        .select(
          "SELECT app, app_name, SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ? GROUP BY app ORDER BY t DESC LIMIT ?;",
          [effectiveEnd, start, end, limit],
        )
        .cast<Map<String, dynamic>>();
  }

  int getIdleTimeForDate(DateTime date) {
    final start = DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999).millisecondsSinceEpoch;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final effectiveEnd = end < nowMs ? end : nowMs;

    final rows = db.select(
      "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=1 AND started_at >= ? AND started_at <= ?;",
      [effectiveEnd, start, end],
    );
    return rows.first['t'] as int;
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

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final effectiveEnd = dayEnd < nowMs ? dayEnd : nowMs;

      final rows = db.select(
        "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ? AND started_at <= ?;",
        [effectiveEnd, dayStart, dayEnd],
      );
      final totalMs = rows.first['t'] as int;
      final dateStr = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      result.add({'d': dateStr, 't': totalMs, 'date': day});
    }
    return result;
  }

  int last30DaysTotalMs() {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 29)).millisecondsSinceEpoch;
    final rows = db.select(
      "SELECT COALESCE(SUM(CASE WHEN ended_at IS NULL THEN MAX(0, ? - started_at) ELSE duration_ms END), 0) AS t FROM sessions WHERE idle=0 AND $_excludedAppsFilter AND started_at >= ?;",
      [nowMs, start],
    );
    return rows.first['t'] as int;
  }

  int getDailyGoalMs() {
    final rows = db.select('SELECT value FROM settings WHERE key = ?;', ['daily_goal_ms']);
    if (rows.isEmpty || rows.first['value'] == null) {
      return 0;
    }
    return int.tryParse(rows.first['value'].toString()) ?? 0;
  }

  void setDailyGoalMs(int goalMs) {
    if (goalMs <= 0) {
      db.execute('DELETE FROM settings WHERE key = ?;', ['daily_goal_ms']);
    } else {
      db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
        ['daily_goal_ms', goalMs.toString()],
      );
    }
  }

  final Map<String, String> _settingsCache = {};
  int _lastSettingsFetchMs = 0;
  static const int _settingsCacheTtlMs = 10000; // 10-second TTL to pick up GUI changes

  void _refreshSettingsCache() {
    _settingsCache.clear();
    try {
      final rows = db.select('SELECT key, value FROM settings');
      for (final r in rows) {
        final k = r['key'] as String?;
        final v = r['value'];
        if (k != null && v != null) {
          _settingsCache[k] = v.toString();
        }
      }
    } catch (_) {}
    _lastSettingsFetchMs = DateTime.now().millisecondsSinceEpoch;
  }

  String getSetting(String key, {String defaultValue = ''}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSettingsFetchMs > _settingsCacheTtlMs) {
      _refreshSettingsCache();
    }
    return _settingsCache[key] ?? defaultValue;
  }

  void setSetting(String key, String value) {
    _settingsCache[key] = value;
    db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      [key, value],
    );
  }

  bool isNotificationsGloballyEnabled() {
    return getSetting('notifications_enabled', defaultValue: '1') == '1';
  }

  void setNotificationsGloballyEnabled(bool enabled) {
    setSetting('notifications_enabled', enabled ? '1' : '0');
  }

  bool isSoundGloballyEnabled() {
    return getSetting('sound_enabled', defaultValue: '1') == '1';
  }

  void setSoundGloballyEnabled(bool enabled) {
    setSetting('sound_enabled', enabled ? '1' : '0');
  }

  String getSoundTheme() {
    return getSetting('sound_theme', defaultValue: 'chime');
  }

  void setSoundTheme(String theme) {
    setSetting('sound_theme', theme);
  }

  String getCustomSoundPath() {
    return getSetting('custom_sound_path', defaultValue: '');
  }

  void setCustomSoundPath(String path) {
    setSetting('custom_sound_path', path);
  }

  bool isEventNotificationEnabled(String eventKey) {
    return getSetting('notify_$eventKey', defaultValue: '1') == '1';
  }

  void setEventNotificationEnabled(String eventKey, bool enabled) {
    setSetting('notify_$eventKey', enabled ? '1' : '0');
  }

  bool isEventSoundEnabled(String eventKey) {
    return getSetting('sound_$eventKey', defaultValue: '1') == '1';
  }

  void setEventSoundEnabled(String eventKey, bool enabled) {
    setSetting('sound_$eventKey', enabled ? '1' : '0');
  }

  bool isPomodoroLoopEnabled() {
    return getSetting('pomodoro_loop_enabled', defaultValue: '0') == '1';
  }

  void setPomodoroLoopEnabled(bool enabled) {
    setSetting('pomodoro_loop_enabled', enabled ? '1' : '0');
  }

  /// Strict focus blocking: when ON, distracting apps are closed + killed
  /// immediately (legacy behavior). When OFF (default), the window is only
  /// minimized and a warning screen offers a 1-minute save grace or manual
  /// close — so unsaved work is never destroyed without consent.
  bool isFocusStrictAutoclose() {
    return getSetting('focus_strict_autoclose', defaultValue: '0') == '1';
  }

  void setFocusStrictAutoclose(bool enabled) {
    setSetting('focus_strict_autoclose', enabled ? '1' : '0');
  }

  /// Focus screen app-picker layout: 'grid' (GNOME app-grid style, icon over
  /// name) or 'list' (checkbox rows with usage time, the default).
  bool isFocusAppGridLayout() {
    return getSetting('focus_app_list_layout', defaultValue: 'list') == 'grid';
  }

  void setFocusAppGridLayout(bool grid) {
    setSetting('focus_app_list_layout', grid ? 'grid' : 'list');
  }

  /// 1-minute save grace: timestamp (ms) until which [app] is exempt from
  /// focus blocking, set from the focus warning screen.
  int getFocusGraceUntilMs(String app) {
    return int.tryParse(
            getSetting('focus_grace_$app', defaultValue: '0')) ??
        0;
  }

  void setFocusGraceMinutes(String app, int minutes) {
    setSetting('focus_grace_$app',
        '${DateTime.now().millisecondsSinceEpoch + minutes * 60000}');
  }

  bool isFocusGraceActive(String app) {
    return DateTime.now().millisecondsSinceEpoch < getFocusGraceUntilMs(app);
  }

  int getPomodoroCyclesCount() {
    final val = getSetting('pomodoro_cycles_count', defaultValue: '4');
    return int.tryParse(val) ?? 4;
  }

  void setPomodoroCyclesCount(int count) {
    setSetting('pomodoro_cycles_count', count.clamp(1, 20).toString());
  }

  int getPomodoroBreakMinutes() {
    final val = getSetting('pomodoro_break_minutes', defaultValue: '5');
    return int.tryParse(val) ?? 5;
  }

  void setPomodoroBreakMinutes(int minutes) {
    setSetting('pomodoro_break_minutes', minutes.clamp(1, 60).toString());
  }

  bool hasNotifiedDailyMilestone(String milestoneKey, String dateKey) {
    return getSetting('last_notified_$milestoneKey') == dateKey;
  }

  void markDailyMilestoneNotified(String milestoneKey, String dateKey) {
    setSetting('last_notified_$milestoneKey', dateKey);
  }

  int getOvertimeMilestoneIndex(String dateKey) {
    final savedDate = getSetting('overtime_milestone_date');
    if (savedDate != dateKey) return 0;
    return int.tryParse(getSetting('overtime_milestone_index', defaultValue: '0')) ?? 0;
  }

  void setOvertimeMilestoneIndex(String dateKey, int index) {
    setSetting('overtime_milestone_date', dateKey);
    setSetting('overtime_milestone_index', index.toString());
  }

  // ── Data management (Settings > Data tab) ──────────────────────────────
  // Usage-data deletes only. App limits, distracting-app list and all other
  // settings are intentionally preserved.

  int databaseFileSize() {
    try {
      return File(path).statSync().size;
    } catch (_) {
      return 0;
    }
  }

  int sessionCount() {
    try {
      final rows = db.select('SELECT COUNT(*) AS c FROM sessions;');
      return (rows.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Returns [oldestStartedAtMs, newestStartedAtMs], or null when empty.
  List<int>? sessionDateRange() {
    try {
      final rows = db.select(
        'SELECT MIN(started_at) AS lo, MAX(started_at) AS hi FROM sessions;',
      );
      if (rows.isEmpty) return null;
      final lo = rows.first['lo'] as int?;
      final hi = rows.first['hi'] as int?;
      if (lo == null || hi == null) return null;
      return [lo, hi];
    } catch (_) {
      return null;
    }
  }

  static int dayStartMs(DateTime day) =>
      DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;

  static int nextDayStartMs(DateTime day) =>
      DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch;

  int _deleteSessionsBetween(int startMs, int endMs) {
    db.execute(
      'DELETE FROM sessions WHERE started_at >= ? AND started_at < ?;',
      [startMs, endMs],
    );
    final sessions = db.getUpdatedRows();
    db.execute(
      'DELETE FROM focus_sessions WHERE started_at >= ? AND started_at < ?;',
      [startMs, endMs],
    );
    return sessions + db.getUpdatedRows();
  }

  /// Delete usage history from [from] (inclusive) to [to] (inclusive day).
  int deleteSessionsInRange(DateTime from, DateTime to) {
    final start = dayStartMs(from);
    final end = nextDayStartMs(to);
    if (end <= start) return 0;
    final n = _deleteSessionsBetween(start, end);
    _vacuum();
    return n;
  }

  /// Delete usage history on exactly the given calendar days (local time).
  int deleteSessionsOnDates(Iterable<DateTime> days) {
    var total = 0;
    for (final d in days) {
      total += _deleteSessionsBetween(dayStartMs(d), nextDayStartMs(d));
    }
    _vacuum();
    return total;
  }

  /// Delete ALL usage history (sessions + focus history + active focus state).
  /// Limits, block-list and settings are kept.
  int clearAllUsageData() {
    db.execute('DELETE FROM sessions;');
    var n = db.getUpdatedRows();
    db.execute('DELETE FROM focus_sessions;');
    n += db.getUpdatedRows();
    try {
      db.execute('DELETE FROM active_focus_state;');
    } catch (_) {}
    // Stale goal/overtime markers would otherwise suppress future notifications.
    for (final k in [
      'last_notified_goal_50',
      'last_notified_goal_100',
      'overtime_milestone_date',
      'overtime_milestone_index',
    ]) {
      try {
        db.execute('DELETE FROM settings WHERE key = ?;', [k]);
      } catch (_) {}
    }
    _vacuum();
    return n;
  }

  void _vacuum() {
    try {
      db.execute('VACUUM;');
    } catch (_) {}
  }

  /// Crash recovery: close sessions left open by a SIGKILL/crash/power loss.
  /// A new daemon instance never adopts them (its [_currentId] starts null),
  /// so without this they would inflate every total forever via the live
  /// `now - started_at` formula. The orphan's real end is unknowable, so its
  /// duration is capped at [maxDurationMs] (one honest polling interval).
  /// Returns the number of rows repaired.
  int closeOrphanedSessions({int maxDurationMs = 10000}) {
    try {
      final rows = db.select(
        'SELECT id, started_at FROM sessions WHERE ended_at IS NULL;',
      );
      for (final r in rows) {
        final id = r['id'] as int;
        final started = r['started_at'] as int;
        final ended = started + maxDurationMs;
        db.execute(
          'UPDATE sessions SET ended_at = ?, duration_ms = ? WHERE id = ?;',
          [ended, maxDurationMs, id],
        );
      }
      return rows.length;
    } catch (_) {
      return 0;
    }
  }
}
