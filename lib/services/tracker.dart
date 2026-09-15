import 'dart:async';
import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/backend/window_backend.dart';
import 'package:screenguard/services/backend/x11_backend.dart';
import 'package:screenguard/services/backend/gnome_wayland_backend.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/sound_service.dart';
import 'package:screenguard/utils/format.dart';

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
        app == 'screenguard' ||
        app.startsWith('window:') ||
        title == 'screenguard') {
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
      _checkAppLimit(app, pid: pid);
      _checkFocusMode(app, pid: pid);
      _checkDailyGoal();
    }
    _checkFocusSessionCompletion();
  }

  // Previous-state tracker for Pomodoro phase transitions
  bool _hadActiveFocusSession = false;
  int _lastFocusDurationMinutes = 0;
  int _prevCycle = -1;       // -1 = no session
  bool _prevIsBreak = false;

  void _checkFocusSessionCompletion() {
    final activeFocus = db.getActiveFocusState();

    if (activeFocus == null) {
      // Session ended (all cycles done or cancelled)
      if (_hadActiveFocusSession) {
        _hadActiveFocusSession = false;
        final totalCycles = _prevCycle > 0 ? _prevCycle : 1;
        _sendNotification(
          '🎉 All Focus Sessions Complete!',
          'Amazing work! You finished all $totalCycles focus ${totalCycles == 1 ? "session" : "sessions"} of $_lastFocusDurationMinutes min.',
          icon: 'dialog-information',
          eventKey: 'focus_mode',
        );
      }
      _prevCycle = -1;
      _prevIsBreak = false;
      return;
    }

    final isPaused = (activeFocus['is_paused'] as int? ?? 0) == 1;
    if (isPaused) return; // Don't fire notifications while paused

    final currentCycle = activeFocus['current_cycle'] as int? ?? 1;
    final totalCycles = activeFocus['total_cycles'] as int? ?? 1;
    final isBreak = (activeFocus['is_break'] as int? ?? 0) == 1;
    final durationMins = activeFocus['duration_minutes'] as int? ?? 0;
    final breakMins = activeFocus['break_duration_minutes'] as int? ?? 5;

    _hadActiveFocusSession = true;
    _lastFocusDurationMinutes = durationMins;

    // First tick — initialise without notifying
    if (_prevCycle == -1) {
      _prevCycle = currentCycle;
      _prevIsBreak = isBreak;
      return;
    }

    // Detect transition: focus phase → break phase (same cycle)
    if (!_prevIsBreak && isBreak && currentCycle == _prevCycle) {
      _sendNotification(
        '✅ Session $currentCycle Complete — Take a Break!',
        'Cycle $currentCycle/$totalCycles done. Enjoy your $breakMins-minute break 🛋️',
        icon: 'dialog-information',
        eventKey: 'focus_mode',
      );
    }

    // Detect transition: break phase → focus phase (next cycle started)
    if (_prevIsBreak && !isBreak && currentCycle == _prevCycle + 1) {
      _sendNotification(
        '🎯 Focus Session $currentCycle Starting!',
        'Break over — time to focus. Cycle $currentCycle/$totalCycles • $durationMins min',
        icon: 'dialog-information',
        eventKey: 'focus_mode',
      );
    }

    _prevCycle = currentCycle;
    _prevIsBreak = isBreak;
  }

  final Map<String, int> _lastDistractionNotifyMs = {};

  void _closeAndTerminateApp(String app, {int? pid}) {
    _backend?.closeActiveWindow();
    if (pid != null && pid > 100) {
      try {
        Process.run('kill', ['-TERM', '$pid']);
      } catch (_) {}
    }
  }

  void _checkFocusMode(String app, {int? pid}) {
    final activeFocus = db.getActiveFocusState();
    if (activeFocus == null ||
        (activeFocus['is_paused'] as int? ?? 0) == 1 ||
        (activeFocus['is_break'] as int? ?? 0) == 1) {
      return;
    }

    if (db.isDistractingApp(app)) {
      final meta = resolver.resolve(app);
      _closeAndTerminateApp(app, pid: pid);
      final lastMs = _lastDistractionNotifyMs[app] ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastMs > 10000) {
        _lastDistractionNotifyMs[app] = now;
        _sendNotification(
          'Focus Mode Active 🎯',
          '${meta.name} was closed during your focus session.',
          eventKey: 'focus_mode',
        );
      }
    }
  }

  final Set<String> _warnedAppsToday = {};
  final Set<String> _lockedAppsNotifiedToday = {};
  int _lastWarnDay = -1;
  bool _notified50PercentGoal = false;
  bool _notified100PercentGoal = false;
  int _lastOvertimeMilestoneIndex = 0;

  void _checkDailyGoal() {
    final nowDay = DateTime.now().day;
    if (_lastWarnDay != nowDay) {
      _warnedAppsToday.clear();
      _lockedAppsNotifiedToday.clear();
      _lastDistractionNotifyMs.clear();
      _notified50PercentGoal = false;
      _notified100PercentGoal = false;
      _lastOvertimeMilestoneIndex = 0;
      _lastWarnDay = nowDay;
    }

    final goalMs = db.getDailyGoalMs();
    if (goalMs <= 0) return;

    final todayMs = db.todayTotalMs();

    // 1. 50% Daily Goal Milestone
    if (todayMs >= (goalMs * 0.5) && !_notified50PercentGoal) {
      _notified50PercentGoal = true;
      _sendNotification(
        'ScreenGuard — Daily Goal',
        '50% daily goal of screen time reached. Kindly take a break.',
        icon: 'dialog-information',
        eventKey: 'daily_goal_50',
      );
    }

    // 2. 100% Daily Goal Milestone
    if (todayMs >= goalMs && !_notified100PercentGoal) {
      _notified100PercentGoal = true;
      _sendNotification(
        'ScreenGuard — Daily Goal Reached',
        '100% daily goal of screen time reached.',
        icon: 'dialog-warning',
        eventKey: 'daily_goal_100',
      );
    }

    // 3. Overtime Milestones (every 50% extra screen time beyond the daily goal)
    if (todayMs > goalMs) {
      final overtimeMs = todayMs - goalMs;
      final stepMs = (goalMs * 0.5).round();
      if (stepMs > 0) {
        final currentMilestone = overtimeMs ~/ stepMs;
        if (currentMilestone > _lastOvertimeMilestoneIndex) {
          _lastOvertimeMilestoneIndex = currentMilestone;
          final milestoneOvertimeMs = currentMilestone * stepMs;
          _sendNotification(
            'ScreenGuard — Goal Exceeded',
            'Your screen time has exceeded ${formatDuration(milestoneOvertimeMs)} above the daily goal.',
            icon: 'dialog-warning',
            eventKey: 'goal_overtime',
          );
        }
      }
    }
  }

  void _checkAppLimit(String app, {int? pid}) {
    final nowDay = DateTime.now().day;
    if (_lastWarnDay != nowDay) {
      _warnedAppsToday.clear();
      _lockedAppsNotifiedToday.clear();
      _lastDistractionNotifyMs.clear();
      _notified50PercentGoal = false;
      _notified100PercentGoal = false;
      _lastOvertimeMilestoneIndex = 0;
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
          eventKey: 'app_limit',
        );
      }
    }

    // 100% Limit Reached -> Close app & Launch Lockout Screen
    if (todayMs >= effectiveLimitMs) {
      _closeAndTerminateApp(app, pid: pid);
      if (!_lockedAppsNotifiedToday.contains(app)) {
        _lockedAppsNotifiedToday.add(app);
        _sendNotification(
          'Time\'s Up!',
          'Daily limit reached for ${meta.name}. App was closed.',
          eventKey: 'app_limit',
        );
      }
      _launchLockoutScreen(app);
    } else {
      _lockedAppsNotifiedToday.remove(app);
    }
  }

  void _sendNotification(
    String summary,
    String body, {
    String icon = 'dialog-warning',
    String eventKey = 'daily_goal_100',
  }) {
    if (db.isNotificationsGloballyEnabled() && db.isEventNotificationEnabled(eventKey)) {
      try {
        Process.run('notify-send', [summary, body, '-i', icon, '-a', 'ScreenGuard']);
      } catch (_) {}
    }

    if (db.isSoundGloballyEnabled() && db.isEventSoundEnabled(eventKey)) {
      final soundTheme = db.getSoundTheme();
      final customPath = db.getCustomSoundPath();
      SoundService.playSound(soundId: soundTheme, customPath: customPath);
    }
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
