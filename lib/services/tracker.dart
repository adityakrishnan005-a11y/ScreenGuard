import 'dart:async';
import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/backend/window_backend.dart';
import 'package:screenguard/services/backend/x11_backend.dart';
import 'package:screenguard/services/backend/gnome_wayland_backend.dart';
import 'package:screenguard/services/app_resolver.dart';

class Tracker {
  final DatabaseService db;
  final AppResolver resolver;
  final Duration pollInterval;
  final int idleThresholdMs;
  WindowBackend? _backend;

  WindowBackend? get backend => _backend;

  bool _running = true;
  int? _currentId;
  String? _currentApp;
  bool? _currentIdle;
  int? _lastTickMs;
  static const int _resumeGapThresholdMs = 30 * 1000;

  Tracker({
    required this.db,
    required this.resolver,
    WindowBackend? backend,
    this.pollInterval = const Duration(seconds: 3),
    this.idleThresholdMs = 5 * 60 * 1000,
  }) : _backend = backend;

  WindowBackend _selectBackend() {
    final wayland = Platform.environment['WAYLAND_DISPLAY'];
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    if ((wayland != null && wayland.isNotEmpty) || sessionType == 'wayland') {
      return GnomeWaylandBackend();
    }
    return X11Backend();
  }

  Future<void> run() async {
    _backend ??= _selectBackend();
    stderr.writeln('[tracker] backend=${_backend.runtimeType} WAYLAND_DISPLAY=${Platform.environment['WAYLAND_DISPLAY']} XDG_SESSION_TYPE=${Platform.environment['XDG_SESSION_TYPE']}');
    final debug = Platform.environment['SG_DEBUG'] == '1';
    db.init();
    resolver.init();
    ProcessSignal.sigterm.watch().listen((_) => _shutdown());
    ProcessSignal.sigint.watch().listen((_) => _shutdown());
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    while (_running) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // A large gap since the last tick means the machine was suspended;
      // close the open session at the last good tick time and start fresh.
      if (_lastTickMs != null && now - _lastTickMs! > _resumeGapThresholdMs && _currentId != null) {
        db.closeSession(_currentId!, _lastTickMs!);
        _currentId = null;
        _currentApp = null;
        _currentIdle = null;
      }
      try {
        final w = await _backend!.getActiveWindow();
        final idleMs = await _backend!.getIdleMs();
        final isIdle = idleMs > idleThresholdMs;
        if (debug) stderr.writeln('[tracker] tick app=${w.app} idleMs=$idleMs isIdle=$isIdle');
        handle(w.app, w.title, w.pid, isIdle);
      } catch (_) {
        // transient backend error; retry next tick
      }
      _lastTickMs = DateTime.now().millisecondsSinceEpoch;
      await Future.delayed(pollInterval);
    }
  }

  void handle(String app, String? title, int? pid, bool isIdle) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (app == 'unknown' ||
        app.isEmpty ||
        app == 'com.example.screenguard' ||
        app == 'screenguard') {
      // Exclude screen locker, shell actor, unknown, or ScreenGuard itself.
      if (_currentId != null) {
        db.closeSession(_currentId!, now);
        _currentId = null;
        _currentApp = null;
        _currentIdle = null;
      }
      return;
    }
    if (_currentId != null && (app != _currentApp || isIdle != _currentIdle)) {
      db.closeSession(_currentId!, now);
      _currentId = null;
    }
    if (_currentId == null) {
      final meta = resolver.resolve(app);
      _currentId = db.openSession(
        app: app,
        appName: meta.name,
        title: title,
        pid: pid,
        startedAt: now,
        idle: isIdle,
      );
      _currentApp = app;
      _currentIdle = isIdle;
    }

    if (!isIdle) {
      _checkAppLimit(app);
      _checkFocusMode(app);
    }
  }

  void _checkFocusMode(String app) {
    final activeFocus = db.getActiveFocusState();
    if (activeFocus == null) return;

    if (db.isDistractingApp(app)) {
      final meta = resolver.resolve(app);
      _backend?.minimizeActiveWindow();
      _sendNotification(
        'Focus Mode Active 🎯',
        '${meta.name} is paused during your focus session.',
      );
    }
  }

  final Set<String> _warnedAppsToday = {};
  int _lastWarnDay = -1;

  void _checkAppLimit(String app) {
    final nowDay = DateTime.now().day;
    if (_lastWarnDay != nowDay) {
      _warnedAppsToday.clear();
      _lastWarnDay = nowDay;
    }

    final limitData = db.getAppLimit(app);
    if (limitData == null || (limitData['enabled'] as int? ?? 1) == 0) return;

    final limitMs = (limitData['limit_ms'] as int?) ?? 0;
    final extMs = (limitData['temp_extension_ms'] as int?) ?? 0;
    final effectiveLimitMs = limitMs + extMs;
    if (effectiveLimitMs <= 0) return;

    final todayMs = db.getAppTodayMs(app);
    final meta = resolver.resolve(app);

    // 90% Warning Threshold
    if (todayMs >= (effectiveLimitMs * 0.9) && todayMs < effectiveLimitMs) {
      if (!_warnedAppsToday.contains(app)) {
        _warnedAppsToday.add(app);
        _sendNotification(
          'ScreenGuard Warning',
          'You have almost reached your daily limit for ${meta.name}.',
        );
      }
    }

    // 100% Limit Reached -> Minimize & Launch Lockout Screen
    if (todayMs >= effectiveLimitMs) {
      _backend?.minimizeActiveWindow();
      _sendNotification(
        'Time\'s Up!',
        'Daily limit reached for ${meta.name}.',
      );
      _launchLockoutScreen(app);
    }
  }

  void _sendNotification(String summary, String body) {
    try {
      Process.run('notify-send', [summary, body, '-i', 'dialog-warning']);
    } catch (_) {}
  }

  void _launchLockoutScreen(String app) {
    try {
      final candidates = [
        '/usr/bin/screenguard',
        '/opt/screenguard/screenguard',
        '${Directory.current.path}/build/linux/x64/release/bundle/screenguard',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          Process.run(c, ['--times-up=$app']);
          return;
        }
      }
    } catch (_) {}
  }

  void _shutdown() {
    if (_currentId != null) {
      db.closeSession(_currentId!, DateTime.now().millisecondsSinceEpoch);
    }
    _running = false;
    exit(0);
  }
}
