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
  static const int _resumeGapThresholdMs = 120 * 1000;

  Tracker({
    required this.db,
    required this.resolver,
    WindowBackend? backend,
    this.pollInterval = const Duration(seconds: 3),
    this.idleThresholdMs = 5 * 60 * 1000,
  }) : _backend = backend;

  bool _isWaylandRunning() {
    final wayland = Platform.environment['WAYLAND_DISPLAY'];
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    if ((wayland != null && wayland.isNotEmpty) || sessionType == 'wayland') {
      return true;
    }
    // Also check for Wayland socket in user runtime directory
    final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'] ?? '/run/user/${Platform.environment['UID'] ?? '1000'}';
    try {
      final dir = Directory(runtimeDir);
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity.uri.pathSegments.last.startsWith('wayland-')) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  WindowBackend _selectBackend() {
    if (_isWaylandRunning()) {
      return GnomeWaylandBackend();
    }
    final desktop = (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    if (desktop.contains('gnome')) {
      return GnomeWaylandBackend();
    }
    return X11Backend();
  }

  int _consecutiveUnknownTicks = 0;

  Future<void> run() async {
    _backend ??= _selectBackend();
    stderr.writeln('[tracker] backend=${_backend.runtimeType} WAYLAND_DISPLAY=${Platform.environment['WAYLAND_DISPLAY']} XDG_SESSION_TYPE=${Platform.environment['XDG_SESSION_TYPE']}');
    final debug = Platform.environment['SG_DEBUG'] == '1';
    db.init();
    resolver.init();
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

        // Dynamic auto-recovery: If X11Backend keeps returning 'unknown' on boot,
        // re-check if the Wayland session has become ready and switch automatically.
        if (w.app == 'unknown' && _backend is X11Backend) {
          _consecutiveUnknownTicks++;
          if (_consecutiveUnknownTicks >= 5 && _isWaylandRunning()) {
            stderr.writeln('[tracker] Wayland session detected after boot. Switching backend to GnomeWaylandBackend.');
            _backend = GnomeWaylandBackend();
            _consecutiveUnknownTicks = 0;
          }
        } else {
          _consecutiveUnknownTicks = 0;
        }

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
      // Still run focus-session completion even on excluded windows so Pomodoro
      // transitions aren't delayed indefinitely while on the lockscreen.
      _checkFocusSessionCompletion(null);
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

    // --- Daily reset: do this exactly ONCE per tick, before any check methods ---
    final nowDay = DateTime.now().day;
    if (_lastWarnDay != -1 && _lastWarnDay != nowDay) {
      // Midnight rollover: split open session so usage is cleanly partitioned per day
      if (_currentId != null && _currentApp != null) {
        db.closeSession(_currentId!, now);
        final meta = resolver.resolve(_currentApp!);
        _currentId = db.openSession(
          app: _currentApp!,
          appName: meta.name,
          title: title,
          pid: pid,
          startedAt: now,
          idle: isIdle,
        );
      }
      _warnedAppsToday.clear();
      _lockedAppsNotifiedToday.clear();
      _lastDistractionNotifyMs.clear();
    }
    _lastWarnDay = nowDay;


    // Fetch focus state once per tick and share it across all checkers (INEFF-1 fix).
    final activeFocus = db.getActiveFocusState();

    if (!isIdle) {
      _checkAppLimit(app, pid: pid);
      _checkFocusMode(app, activeFocus: activeFocus, pid: pid);
      _checkDailyGoal();
    }
    _checkFocusSessionCompletion(activeFocus);
  }


  // Previous-state tracker for Pomodoro phase transitions
  bool _hadActiveFocusSession = false;
  int _lastFocusDurationMinutes = 0;
  int _prevCycle = -1;       // -1 = no active session
  bool _prevIsBreak = false;

  // Accept pre-fetched activeFocus to avoid double DB read per tick (INEFF-1 fix).
  void _checkFocusSessionCompletion(Map<String, dynamic>? activeFocus) {
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

  // BUG-3 fix: sequence close then SIGTERM with a delay; pid > 1000 guard.
  Future<void> _closeAndTerminateApp(String app, {int? pid}) async {
    try {
      await _backend?.closeActiveWindow();
    } catch (_) {}
    if (pid != null && pid > 1000) {
      // Give the app 1 second to handle the close signal before SIGTERM.
      await Future.delayed(const Duration(seconds: 1));
      try {
        await Process.run('kill', ['-TERM', '$pid']);
      } catch (_) {}
    }
  }

  // INEFF-1 fix: accepts pre-fetched activeFocus instead of re-querying DB.
  void _checkFocusMode(String app, {required Map<String, dynamic>? activeFocus, int? pid}) {
    if (activeFocus == null ||
        (activeFocus['is_paused'] as int? ?? 0) == 1 ||
        (activeFocus['is_break'] as int? ?? 0) == 1) {
      return;
    }

    final aliases = resolver.getAliases(app);
    if (db.isDistractingApp(app, aliases: aliases)) {
      final meta = resolver.resolve(app);
      _closeAndTerminateApp(app, pid: pid); // fire-and-forget async is intentional
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

  String _todayDateKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void _checkDailyGoal() {
    // BUG-1 fix: daily reset is now done centrally in handle() — removed from here.
    final goalMs = db.getDailyGoalMs();
    if (goalMs <= 0) return;

    final todayMs = db.todayTotalMs();
    final dateKey = _todayDateKey();

    // 1. 50% Daily Goal Milestone (only if currently between 50% and 100%)
    if (todayMs >= (goalMs * 0.5) && todayMs < goalMs) {
      if (!db.hasNotifiedDailyMilestone('goal_50', dateKey)) {
        db.markDailyMilestoneNotified('goal_50', dateKey);
        _sendNotification(
          'ScreenGuard — Daily Goal',
          '50% daily goal of screen time reached. Kindly take a break.',
          icon: 'dialog-information',
          eventKey: 'daily_goal_50',
        );
      }
    } else if (todayMs >= goalMs) {
      // If already at or past 100%, mark 50% as passed without sending a stale 50% alert
      if (!db.hasNotifiedDailyMilestone('goal_50', dateKey)) {
        db.markDailyMilestoneNotified('goal_50', dateKey);
      }

      // 2. 100% Daily Goal Milestone
      if (!db.hasNotifiedDailyMilestone('goal_100', dateKey)) {
        db.markDailyMilestoneNotified('goal_100', dateKey);
        // Initialize overtime baseline to the current level to prevent firing both 100% and overtime in the same tick
        final stepMs = (goalMs * 0.5).round();
        if (stepMs > 0) {
          final currentMilestone = (todayMs - goalMs) ~/ stepMs;
          db.setOvertimeMilestoneIndex(dateKey, currentMilestone);
        }
        _sendNotification(
          'ScreenGuard — Daily Goal Reached',
          '100% daily goal of screen time reached.',
          icon: 'dialog-warning',
          eventKey: 'daily_goal_100',
        );
        return;
      }

      // 3. Overtime Milestones (every 50% extra screen time beyond the daily goal)
      final overtimeMs = todayMs - goalMs;
      final stepMs = (goalMs * 0.5).round();
      if (stepMs > 0) {
        final currentMilestone = overtimeMs ~/ stepMs;
        final lastOvertimeIndex = db.getOvertimeMilestoneIndex(dateKey);
        if (currentMilestone > lastOvertimeIndex) {
          db.setOvertimeMilestoneIndex(dateKey, currentMilestone);
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
    // BUG-1 fix: daily reset is now done centrally in handle() — removed from here.
    final aliases = resolver.getAliases(app);
    final limitData = db.getAppLimit(app, aliases: aliases);
    if (limitData == null || (limitData['enabled'] as int? ?? 1) == 0) return;

    final limitMs = (limitData['limit_ms'] as int?) ?? 0;
    final extMs = (limitData['temp_extension_ms'] as int?) ?? 0;
    final effectiveLimitMs = limitMs + extMs;
    if (effectiveLimitMs <= 0) return;

    final todayMs = db.getAppTodayMs(app, aliases: aliases);
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
      _closeAndTerminateApp(app, pid: pid); // fire-and-forget async
      if (!_lockedAppsNotifiedToday.contains(app)) {
        _lockedAppsNotifiedToday.add(app);
        _sendNotification(
          'Time\'s Up!',
          'Daily limit reached for ${meta.name}. App was closed.',
          icon: 'dialog-warning',
          urgency: 'critical',
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
    String urgency = 'normal',
  }) {
    final notifyGlobal = db.isNotificationsGloballyEnabled();
    final notifyEvent = db.isEventNotificationEnabled(eventKey);
    stderr.writeln('[tracker] notify request: eventKey=$eventKey notifyGlobal=$notifyGlobal notifyEvent=$notifyEvent summary="$summary"');

    if (notifyGlobal && notifyEvent) {
      try {
        final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'] ?? '/run/user/${Platform.environment['UID'] ?? '1000'}';
        final dbusBus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? 'unix:path=$runtimeDir/bus';
        Process.run(
          'notify-send',
          [
            summary,
            body,
            '-u',
            urgency,
            '-i',
            icon,
            '-a',
            'ScreenGuard',
            '-h',
            'string:desktop-entry:screenguard',
          ],
          environment: {
            ...Platform.environment,
            'DBUS_SESSION_BUS_ADDRESS': dbusBus,
          },
        ).then((res) {
          if (res.exitCode != 0) {
            stderr.writeln('[tracker] notify-send exitCode=${res.exitCode} stderr=${res.stderr}');
          } else {
            stderr.writeln('[tracker] notify-send sent successfully: "$summary"');
          }
        }).catchError((e) {
          stderr.writeln('[tracker] notify-send error: $e');
        });
      } catch (e) {
        stderr.writeln('[tracker] notify-send sync error: $e');
      }
    }

    if (db.isSoundGloballyEnabled() && db.isEventSoundEnabled(eventKey)) {
      final soundTheme = db.getSoundTheme();
      final customPath = db.getCustomSoundPath();
      SoundService.playSound(soundId: soundTheme, customPath: customPath);
    }
  }

  void _launchLockoutScreen(String app) {
    // BUG-16 fix: include user-local install path; remove invalid CWD dev path.
    try {
      final home = Platform.environment['HOME'] ?? '';
      final candidates = [
        '$home/.local/opt/screenguard/screenguard',   // user-local install (install.sh default)
        '/usr/local/bin/screenguard',
        '/usr/bin/screenguard',
        '/opt/screenguard/screenguard',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          Process.run(c, ['--times-up=$app']);
          return;
        }
      }
    } catch (_) {}
  }

  void stop() {
    if (_currentId != null) {
      db.closeSession(_currentId!, DateTime.now().millisecondsSinceEpoch);
      _currentId = null;
    }
    _running = false;
  }
}


