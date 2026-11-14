import 'dart:async';
import 'dart:io';
import 'package:screenguard/api/dispatch.dart';
import 'package:screenguard/api/policy_api.dart';
import 'package:screenguard/api/transport.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/backend/window_backend.dart';
import 'package:screenguard/services/backend/x11_backend.dart';
import 'package:screenguard/services/backend/gnome_wayland_backend.dart';
import 'package:screenguard/services/backend/cinnamon_backend.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/notification_service.dart';
import 'package:screenguard/services/app_killer.dart';
import 'package:screenguard/services/session_memory.dart';
import 'package:screenguard/services/session_backend.dart';
import 'package:screenguard/services/session_monitor.dart';
import 'package:screenguard/utils/format.dart';

class Tracker {
  final DatabaseService db;
  final AppResolver resolver;

  /// The reconciler is part of the daemon, so it reads policy (notification
  /// preferences) through the same dispatch table the broker reaches, never
  /// by introducing a second data path.
  late final PolicyApi _policy =
      PolicyApi(InProcessTransport(ScreenGuardDispatch(db: db)));
  final Duration pollInterval;
  final int idleThresholdMs;

  /// Durable session state. In the daemon this is the C `digiwelld-session`
  /// worker when it is available; otherwise it is the local Dart journal.
  final SessionMemoryBackend _memory;
  WindowBackend? _backend;

  bool _running = true;
  int? _currentId;
  String? _currentApp;
  String? _currentTitle;
  int? _currentPid;
  int? _currentStartedAtMs;
  bool? _currentIdle;
  int? _lastTickMs;
  bool? _lastIdleReported;

  /// Set during startup so the status API can explain what happened.
  SessionMemory? _restoredMemory;
  int? _resumedSessionId;
  int? _closedSessionId;
  int? _restoredGapMs;

  /// Checkpoint the full snapshot every this many poll ticks (3 s each).
  static const int _checkpointEveryTicks = 5; // ~15 s
  int _ticksSinceCheckpoint = 0;

  /// True between logind's Lock and Unlock signals. While locked, nothing the
  /// poll sees counts as use, even if the lock screen reports a resolvable app.
  bool _sessionLocked = false;

  /// True between PrepareForSleep(true) and PrepareForSleep(false).
  bool _suspended = false;

  SessionMonitor? _sessionMonitor;

  /// Read-only view used by TrackingApi. Nothing else should observe the
  /// tracker's internals.
  bool get isRunning => _running;
  String? get currentApp => _currentApp;
  bool? get currentIdle => _currentIdle;
  static const int _resumeGapThresholdMs = 120 * 1000;

  /// A restart shorter than this can adopt the open session; the app almost
  /// certainly did not change. Longer than this and we close at the last
  /// observed tick instead, so daemon downtime is never counted as usage.
  static const int _restartResumeThresholdMs = 15 * 1000;

  Tracker({
    required this.db,
    required this.resolver,
    WindowBackend? backend,
    this.pollInterval = const Duration(seconds: 3),
    this.idleThresholdMs = 5 * 60 * 1000,
    SessionJournal? journal,
    SessionMemoryBackend? sessionMemory,
  })  : _backend = backend,
        _memory = sessionMemory ??
            LocalSessionMemoryBackend(
                journal ?? SessionJournal(directory: runtimeDirectory()));

  bool _isWaylandRunning() {
    final wayland = Platform.environment['WAYLAND_DISPLAY'];
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    if ((wayland != null && wayland.isNotEmpty) || sessionType == 'wayland') {
      return true;
    }
    // Also check for Wayland socket in user runtime directory
    final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'] ??
        '/run/user/${Platform.environment['UID'] ?? '1000'}';
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
    final desktop =
        (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
    if (desktop.contains('gnome')) {
      return GnomeWaylandBackend();
    }
    // Cinnamon is X11, but its compositor hides the real focus from the X
    // server. Muffin's debug D-Bus interface is authoritative there.
    if (desktop.contains('cinnamon') || desktop.contains('x-cinnamon')) {
      return CinnamonBackend();
    }
    return X11Backend();
  }

  int _consecutiveUnknownTicks = 0;

  Future<void> run() async {
    _backend ??= _selectBackend();
    stderr.writeln(
        '[tracker] backend=${_backend.runtimeType} WAYLAND_DISPLAY=${Platform.environment['WAYLAND_DISPLAY']} XDG_SESSION_TYPE=${Platform.environment['XDG_SESSION_TYPE']}');
    final debug = Platform.environment['SG_DEBUG'] == '1';
    db.init();
    resolver.init();

    final startupMs = DateTime.now().millisecondsSinceEpoch;
    final memory = _memory.load();
    _recoverSessionMemory(memory, startupMs);
    // The worker may have closed the session itself while we were down; the
    // SQLite row is still open and must be ended at the same honest boundary.
    _applyWorkerRecovery(_memory.recovery, memory, startupMs);
    // Repair any session the journal did not know about. The session we just
    // resumed is genuinely open and must not be capped as an orphan.
    final orphans = db.closeOrphanedSessions(
      maxDurationMs: pollInterval.inMilliseconds * 2,
      preserveId: _resumedSessionId,
    );
    if (debug) {
      if (memory != null) {
        stderr.writeln(
          '[tracker] session memory backend=${_memory.name} '
          'seq=${_memory.info()['last_seq']} '
          'resumed=$_resumedSessionId closed=$_closedSessionId '
          'gapMs=$_restoredGapMs',
        );
      }
      if (orphans > 0) {
        stderr.writeln('[tracker] closed $orphans orphaned session(s)');
      }
    }

    _lastTickMs ??= startupMs;
    if (_dayStartMs == 0) _dayStartMs = _startOfDayMs(DateTime.now());
    _memory.checkpoint(_capture(startupMs));
    _scheduleRollover();
    _startSessionMonitor();
    while (_running) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // A large gap since the last tick means the machine was suspended
      // (logind's signal may have been missed, e.g. no system bus); close the
      // open session at the last good tick time and start fresh.
      if (_lastTickMs != null &&
          now - _lastTickMs! > _resumeGapThresholdMs &&
          _currentId != null) {
        db.closeSession(_currentId!, _lastTickMs!);
        _clearCurrentSession();
        _persist();
      }
      try {
        final w = await _backend!.getActiveWindow();
        final idleMs = await _backend!.getIdleMs();
        final isIdle = idleMs > idleThresholdMs;
        if (debug) {
          stderr.writeln(
              '[tracker] tick app=${w.app} idleMs=$idleMs isIdle=$isIdle');
        }

        // Dynamic auto-recovery: If X11Backend keeps returning 'unknown' on boot,
        // re-check if the Wayland session has become ready and switch automatically.
        if (w.app == 'unknown' && _backend is X11Backend) {
          _consecutiveUnknownTicks++;
          if (_consecutiveUnknownTicks >= 5 && _isWaylandRunning()) {
            stderr.writeln(
                '[tracker] Wayland session detected after boot. Switching backend to GnomeWaylandBackend.');
            _backend = GnomeWaylandBackend();
            _consecutiveUnknownTicks = 0;
            _persist();
          }
        } else {
          _consecutiveUnknownTicks = 0;
        }

        handle(w.app, w.title, w.pid, isIdle);
      } catch (_) {
        // transient backend error; retry next tick
      }
      _lastTickMs = DateTime.now().millisecondsSinceEpoch;
      _ticksSinceCheckpoint++;
      if (_ticksSinceCheckpoint >= _checkpointEveryTicks) {
        _ticksSinceCheckpoint = 0;
        _memory.checkpoint(_capture(_lastTickMs!));
      }
      await Future.delayed(pollInterval);
    }
  }

  /// Adopt the journaled session when the restart was quick, otherwise close
  /// it at the last tick the old process actually observed. Never let the
  /// generic orphan repair truncate a long session to one poll interval.
  void _recoverSessionMemory(SessionMemory? memory, int nowMs) {
    _restoredMemory = memory;
    if (memory == null) return;

    final id = memory.currentSessionId;
    final app = memory.currentApp;
    final gap = memory.lastTickMs == null ? null : nowMs - memory.lastTickMs!;
    _restoredGapMs = gap;

    if (id == null || app == null) {
      _restoreEnvironment(memory, gap);
      return;
    }

    final row = db.getSession(id);
    final stillOpen = row != null && row['ended_at'] == null;
    if (!stillOpen) {
      _restoreEnvironment(memory, gap);
      return;
    }

    final startedAt = row['started_at'] as int? ??
        memory.sessionStartedAtMs ??
        memory.lastTickMs ??
        nowMs;
    final quickRestart =
        gap != null && gap >= 0 && gap <= _restartResumeThresholdMs;

    if (quickRestart) {
      final rowIdle = row['idle'] as int?;
      _currentId = id;
      _currentApp = (row['app'] as String?) ?? app;
      _currentTitle = (row['title'] as String?) ?? memory.currentTitle;
      _currentPid = (row['pid'] as int?) ?? memory.currentPid;
      _currentStartedAtMs = startedAt;
      _currentIdle = rowIdle == null ? memory.currentIdle : rowIdle != 0;
      _lastIdleReported = memory.lastIdleReported;
      _resumedSessionId = id;
      _restoreEnvironment(memory, gap);
      return;
    }

    // Slow restart: the app may have changed while we were down. End the
    // session at its last observed tick so its duration stays honest.
    final lastTick = memory.lastTickMs ?? nowMs;
    final closeAt = lastTick < startedAt
        ? startedAt
        : (lastTick > nowMs ? nowMs : lastTick);
    db.closeSession(id, closeAt);
    _closedSessionId = id;
    // The session ended at the last observation, so that is also the newest
    // tick the checkpoint may claim.
    _lastTickMs = closeAt;
    _restoreEnvironment(memory, gap);
  }

  /// Mirror a close that `digiwelld-session` performed at its own startup.
  ///
  /// The worker owns the durable decision, but the SQLite row is still open.
  /// A close report can outlive the restart that produced it, so it is only
  /// applied while the worker still reports no current session. The database
  /// guard makes a repeated application harmless.
  void _applyWorkerRecovery(
      SessionWorkerRecovery? recovery, SessionMemory? memory, int nowMs) {
    if (recovery == null) return;
    final id = recovery.closedSessionId;
    if (id == null) return;
    if (memory?.currentSessionId != null) return;
    // The tracker may already have closed a newer session during its own
    // recovery; that decision is more recent than the worker's report.
    if (_closedSessionId != null) return;

    final closeAt = recovery.closeAtMs ?? memory?.lastTickMs ?? nowMs;
    final row = db.getSession(id);
    if (row != null && row['ended_at'] == null) {
      db.closeSession(id, closeAt);
    }
    _closedSessionId = id;
    _lastTickMs ??= closeAt;
    _restoredGapMs = recovery.restartGapMs ?? _restoredGapMs;
  }

  void _restoreEnvironment(SessionMemory memory, int? gapMs) {
    // Lock/suspend are live signals, not durable facts. Restoring a stale
    // `true` after a restart could suppress tracking indefinitely if the
    // matching unlock/resume signal was missed. Start from the monitor's
    // initial (unlocked, awake) state and let the next signal correct it.
    final fresh = gapMs != null && gapMs >= 0 && gapMs <= _resumeGapThresholdMs;
    _consecutiveUnknownTicks = fresh ? memory.consecutiveUnknownTicks : 0;
    _dayStartMs = fresh && memory.dayStartMs != 0
        ? memory.dayStartMs
        : _startOfDayMs(DateTime.now());
  }

  SessionMemory _capture(int writtenAtMs) => SessionMemory(
        writtenAtMs: writtenAtMs,
        currentSessionId: _currentId,
        currentApp: _currentApp,
        currentTitle: _currentTitle,
        currentPid: _currentPid,
        currentIdle: _currentIdle,
        sessionStartedAtMs: _currentStartedAtMs,
        lastTickMs: _lastTickMs,
        lastIdleReported: _lastIdleReported,
        sessionLocked: _sessionLocked,
        suspended: _suspended,
        dayStartMs: _dayStartMs,
        consecutiveUnknownTicks: _consecutiveUnknownTicks,
      );

  /// Record one transition. Cheap enough to call only when something actually
  /// changed; the periodic checkpoint keeps `lastTickMs` fresh.
  void _persist() {
    _memory.append(_capture(DateTime.now().millisecondsSinceEpoch));
  }

  void _clearCurrentSession() {
    _currentId = null;
    _currentApp = null;
    _currentTitle = null;
    _currentPid = null;
    _currentStartedAtMs = null;
    _currentIdle = null;
  }

  /// Diagnostics and the future C handover surface.
  Map<String, Object?> sessionMemoryInfo() => <String, Object?>{
        'journal': _memory.info(),
        'backend': _memory.name,
        'restored': _restoredMemory != null,
        'resumed_session_id': _resumedSessionId,
        'closed_session_id': _closedSessionId,
        'restart_gap_ms': _restoredGapMs,
        'current_session_id': _currentId,
        'current_app': _currentApp,
        'current_idle': _currentIdle,
        'last_tick_ms': _lastTickMs,
        'day_start_ms': _dayStartMs,
        'locked': _sessionLocked,
        'suspended': _suspended,
      };

  /// Force a snapshot + journal truncate. Called by the API and at shutdown.
  ///
  /// SQLite history is deliberately untouched: merging adjacent rows would
  /// change session boundaries for no storage benefit that matters.
  void compactSessionMemory() {
    _memory.checkpoint(_capture(DateTime.now().millisecondsSinceEpoch));
  }

  void handle(String app, String? title, int? pid, bool isIdle) {
    // Run before the "unknown/lockscreen" early return: the day must roll over
    // even if nobody is using an app at midnight.
    _rolloverIfDayChanged();
    final now = DateTime.now().millisecondsSinceEpoch;
    // This poll is the latest observation; session-memory checkpoints should
    // not fall back to the previous loop's timestamp.
    _lastTickMs = now;
    if (_sessionLocked ||
        _suspended ||
        app == 'unknown' ||
        app.isEmpty ||
        app == 'com.example.screenguard' ||
        app == 'screenguard' ||
        app.startsWith('window:') ||
        title == 'screenguard') {
      // Exclude screen locker, shell actor, unknown, or ScreenGuard itself.
      if (_currentId != null) {
        db.closeSession(_currentId!, now);
        _clearCurrentSession();
        _persist();
      }
      // Still run focus-session completion even on excluded windows so Pomodoro
      // transitions aren't delayed indefinitely while on the lockscreen. The
      // policy worker owns the state machine; skip the tick if it is
      // restarting rather than advancing it from here.
      final focus = _readFocusState();
      if (focus.available) _checkFocusSessionCompletion(focus.state);
      return;
    }
    // Desktop wallpaper/panel focus counts as idle time, not app usage.
    // (File managers — thunar, nemo, dolphin, nautilus — are NOT in
    // desktopShellApps and keep tracking as normal active apps.)
    if (DatabaseService.desktopShellApps.contains(app)) {
      isIdle = true;
    }
    // Record the transition, not every tick: the event stream should answer
    // "when did the user stop being active", not "what did we poll".
    if (_lastIdleReported != isIdle) {
      if (_lastIdleReported != null) {
        db.recordEvent(
          isIdle ? DatabaseService.evIdleEnter : DatabaseService.evIdleLeave,
          at: now,
          app: app,
        );
      }
      _lastIdleReported = isIdle;
      _persist();
    }
    if (_currentId != null && (app != _currentApp || isIdle != _currentIdle)) {
      db.closeSession(_currentId!, now);
      _clearCurrentSession();
      _persist();
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
      _currentTitle = title;
      _currentPid = pid;
      _currentStartedAtMs = now;
      _currentIdle = isIdle;
      _persist();
    }

    // --- Daily reset ---
    // The exact timer below normally does this. This call is the safety net
    // for a suspended machine or a wall-clock jump: it is idempotent.
    _rolloverIfDayChanged();

    // Fetch focus state once per tick and share it across all checkers (INEFF-1 fix).
    final focus = _readFocusState();
    if (!isIdle && focus.available) {
      final activeFocus = focus.state;
      final inBreak = (activeFocus?['is_break'] as int? ?? 0) == 1;
      _checkAppLimit(app, pid: pid, inBreak: inBreak);
      _checkFocusMode(app, activeFocus: activeFocus, pid: pid);
      _checkDailyGoal();
    }
    if (focus.available) _checkFocusSessionCompletion(focus.state);
  }

  /// Focus state is owned by digiwelld-policy once it is configured.
  ///
  /// DatabaseService.getActiveFocusState() is not a pure read: it completes an
  /// expired phase and inserts the next focus session. Calling it here after
  /// the policy worker exists would make the daemon a second state-machine
  /// writer and both processes would insert the same cycle. When the worker
  /// socket is configured, this reads through it and reports the tick as
  /// unavailable while it restarts, instead of falling back and racing it.
  _FocusRead _readFocusState() {
    final path = Platform.environment['SCREENGUARD_POLICY_SOCKET'];
    if (path == null || path.isEmpty) {
      return _FocusRead(true, db.getActiveFocusState());
    }
    try {
      final state = BrokerTransport(socketPath: path)
          .call('policy', 'getActiveFocusState', const {});
      return _FocusRead(true, state as Map<String, dynamic>?);
    } on TransportException {
      return const _FocusRead(false, null);
    }
  }

  // Previous-state tracker for Pomodoro phase transitions
  bool _hadActiveFocusSession = false;
  int _lastFocusDurationMinutes = 0;
  int _prevCycle = -1; // -1 = no active session
  bool _prevIsBreak = false;

  // Accept pre-fetched activeFocus to avoid double DB read per tick (INEFF-1 fix).
  void _checkFocusSessionCompletion(Map<String, dynamic>? activeFocus) {
    if (activeFocus == null) {
      // Session ended: check if it completed naturally or was cancelled
      if (_hadActiveFocusSession) {
        _hadActiveFocusSession = false;
        final lastSession = db.getLastFocusSession();
        final wasCompleted =
            lastSession != null && (lastSession['completed'] as int? ?? 0) == 1;
        if (wasCompleted) {
          final totalCycles = _prevCycle > 0 ? _prevCycle : 1;
          _sendNotification(
            '🎉 All Focus Sessions Complete!',
            'Amazing work! You finished all $totalCycles focus ${totalCycles == 1 ? "session" : "sessions"} of $_lastFocusDurationMinutes min.',
            icon: 'dialog-information',
            eventKey: 'focus_mode',
          );
        }
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
  // Now escalates (WM_DELETE → TERM → KILL → tree) via AppKiller so Proton
  // games actually die instead of shrugging off a lone SIGTERM.
  Future<void> _closeAndTerminateApp(String app, {int? pid}) async {
    await AppKiller.close(app: app, pid: pid, backend: _backend);
  }

  // INEFF-1 fix: accepts pre-fetched activeFocus instead of re-querying DB.
  void _checkFocusMode(String app,
      {required Map<String, dynamic>? activeFocus, int? pid}) {
    if (activeFocus == null ||
        (activeFocus['is_paused'] as int? ?? 0) == 1 ||
        (activeFocus['is_break'] as int? ?? 0) == 1) {
      return;
    }

    final aliases = resolver.getAliases(app);
    if (db.isDistractingApp(app, aliases: aliases)) {
      // 1-minute save grace from the warning screen: leave the app alone.
      if (db.isFocusGraceActive(app)) {
        _graceWasActive.add(app);
        return;
      }
      // Grace just expired while the app is still focused: warn immediately
      // instead of waiting out the re-show throttle.
      if (_graceWasActive.remove(app)) {
        _lastFocusWarnMs[app] = 0;
      }
      final meta = resolver.resolve(app);

      // Strict mode (opt-in setting): legacy instant close + kill.
      if (db.isFocusStrictAutoclose()) {
        _closeAndTerminateApp(app,
            pid: pid); // fire-and-forget async is intentional
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
        return;
      }

      // Default: never destroy unsaved work. Minimize only, then show the
      // persistent warning screen — relentless: re-shown every few seconds
      // while the app stays focused, so dismissal forces a real decision.
      unawaited(_minimizeOnly());
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - (_lastFocusWarnMs[app] ?? 0) > 5000) {
        _lastFocusWarnMs[app] = now;
        _sendNotification(
          'Focus Mode Active 🎯',
          '${meta.name} was minimized — open ScreenGuard to close it or take 1 minute to save.',
          eventKey: 'focus_mode',
        );
        _launchFocusBlockScreen(app, pid);
      }
    }
  }

  final Map<String, int> _lastFocusWarnMs = {};
  final Set<String> _graceWasActive = {};

  Future<void> _minimizeOnly() async {
    try {
      final minimized = await _backend?.minimizeActiveWindow() ?? false;
      if (minimized) return;
      // The window refused to minimize (fullscreen games, stubborn toolkits).
      // Do not destroy work: move focus away instead, which still takes the
      // app off the user's screen.
      await _backend?.switchAwayFromActiveWindow();
    } catch (_) {}
  }

  void _launchFocusBlockScreen(String app, int? pid) {
    try {
      final home = Platform.environment['HOME'] ?? '';
      final candidates = [
        '$home/.local/opt/screenguard/screenguard',
        '/usr/local/bin/screenguard',
        '/usr/bin/screenguard',
        '/opt/screenguard/screenguard',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          final args = ['--focus-block=$app'];
          if (pid != null) args.add('--pid=$pid');
          Process.run(c, args);
          return;
        }
      }
    } catch (_) {}
  }

  final Set<String> _warnedAppsToday = {};
  final Set<String> _lockedAppsNotifiedToday = {};

  /// Start of the tracking day, in ms. A change means midnight passed.
  int _dayStartMs = 0;

  /// Fires exactly at local midnight. The daemon is always running (supervised
  /// by the broker or systemd), so this is more reliable than re-reading the
  /// clock every 3s and more precise than "first tick after midnight".
  Timer? _rolloverTimer;

  static int _startOfDayMs(DateTime t) =>
      DateTime(t.year, t.month, t.day).millisecondsSinceEpoch;

  void _startSessionMonitor() {
    _sessionMonitor?.stop();
    final monitor = SessionMonitor(
      onLock: () => _setLocked(true),
      onUnlock: () => _setLocked(false),
      onSuspend: () => _setSuspended(true),
      onResume: () => _setSuspended(false),
    );
    _sessionMonitor = monitor;
    unawaited(monitor.start());
  }

  void _setLocked(bool locked) {
    if (_sessionLocked == locked) return;
    _sessionLocked = locked;
    final now = DateTime.now().millisecondsSinceEpoch;
    db.recordEvent(
      locked ? DatabaseService.evLock : DatabaseService.evUnlock,
      at: now,
    );
    if (locked) {
      // The lock instant is the honest end of the current session.
      if (_currentId != null) {
        db.closeSession(_currentId!, now);
        _clearCurrentSession();
      }
      _lastIdleReported = null;
    } else {
      // Re-base both detectors: the lock period is not a resume gap and must
      // not be mistaken for activity.
      _lastTickMs = null;
      _lastIdleReported = null;
    }
    _persist();
  }

  void _setSuspended(bool suspended) {
    if (_suspended == suspended) return;
    _suspended = suspended;
    final now = DateTime.now().millisecondsSinceEpoch;
    db.recordEvent(
      suspended ? DatabaseService.evSuspend : DatabaseService.evResume,
      at: now,
    );
    if (suspended) {
      if (_currentId != null) {
        db.closeSession(_currentId!, now);
        _clearCurrentSession();
      }
      _lastIdleReported = null;
    } else {
      _lastTickMs = null;
      _lastIdleReported = null;
    }
    _persist();
  }

  void _scheduleRollover() {
    _rolloverTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    _rolloverTimer = Timer(nextMidnight.difference(now), () {
      _rolloverAt(nextMidnight.millisecondsSinceEpoch);
      _scheduleRollover();
    });
  }

  void _rolloverIfDayChanged() {
    final todayStart = _startOfDayMs(DateTime.now());
    if (_dayStartMs == 0) {
      _dayStartMs = todayStart;
      return;
    }
    if (todayStart != _dayStartMs) {
      _rolloverAt(todayStart);
      _scheduleRollover();
    }
  }

  /// Partition the day at [boundaryMs] (local midnight), not at "now".
  void _rolloverAt(int boundaryMs) {
    if (_currentId != null) {
      // Any remaining slice belongs to the old day: close it at the boundary.
      db.closeSession(_currentId!, boundaryMs);
      _clearCurrentSession();
    }
    _warnedAppsToday.clear();
    _lockedAppsNotifiedToday.clear();
    _lastDistractionNotifyMs.clear();
    db.recordEvent(DatabaseService.evDayRollover, at: boundaryMs);
    _dayStartMs =
        _startOfDayMs(DateTime.fromMillisecondsSinceEpoch(boundaryMs));
    // Re-base the suspend detector: a boundary is not a resume gap.
    _lastTickMs = null;
    _persist();
  }

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

  void _checkAppLimit(String app, {int? pid, bool inBreak = false}) {
    // BUG-1 fix: daily reset is now done centrally in handle() — removed from here.
    // Pomodoro breaks pause limit enforcement entirely: no warnings, no
    // lockouts while on break. Resumes automatically when work restarts.
    if (inBreak) return;
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

    // 100% Limit Reached -> Lockout Screen (+ optional strict close)
    if (todayMs >= effectiveLimitMs) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (db.isFocusStrictAutoclose()) {
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
      } else {
        // Default: never destroy unsaved work. Minimize only; the lockout
        // screen offers +15 min, edit, or explicit close.
        unawaited(_minimizeOnly());
        if (!_lockedAppsNotifiedToday.contains(app)) {
          _lockedAppsNotifiedToday.add(app);
          _sendNotification(
            'Time\'s Up!',
            'Daily limit reached for ${meta.name}. Window was minimized — nothing was closed.',
            icon: 'dialog-warning',
            urgency: 'critical',
            eventKey: 'app_limit',
          );
        }
      }
      // (Re-)show the lockout screen relentlessly — every few seconds per
      // app while over limit — so dismissal forces a real decision.
      if (nowMs - (_lastLimitScreenMs[app] ?? 0) > 5000) {
        _lastLimitScreenMs[app] = nowMs;
        _launchLockoutScreen(app, pid);
      }
    } else {
      _lockedAppsNotifiedToday.remove(app);
    }
  }

  final Map<String, int> _lastLimitScreenMs = {};

  void _sendNotification(
    String summary,
    String body, {
    String icon = 'dialog-warning',
    String eventKey = 'daily_goal_100',
    String urgency = 'normal',
  }) {
    NotificationService.show(
      policy: _policy,
      eventKey: eventKey,
      title: summary,
      body: body,
      icon: icon,
      urgency: urgency,
    );
  }

  void _launchLockoutScreen(String app, int? pid) {
    // BUG-16 fix: include user-local install path; remove invalid CWD dev path.
    try {
      final home = Platform.environment['HOME'] ?? '';
      final candidates = [
        '$home/.local/opt/screenguard/screenguard', // user-local install (install.sh default)
        '/usr/local/bin/screenguard',
        '/usr/bin/screenguard',
        '/opt/screenguard/screenguard',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) {
          final args = ['--times-up=$app'];
          if (pid != null) args.add('--pid=$pid');
          Process.run(c, args);
          return;
        }
      }
    } catch (_) {}
  }

  void stop() {
    _rolloverTimer?.cancel();
    _rolloverTimer = null;
    _sessionMonitor?.stop();
    _sessionMonitor = null;
    _lastIdleReported = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_currentId != null) {
      db.closeSession(_currentId!, now);
      _clearCurrentSession();
    }
    // A clean stop is an observation boundary too: the snapshot should end at
    // the same instant the database row did, not at the previous poll.
    _lastTickMs = now;
    // A clean stop is a compact boundary: the next process starts from a
    // snapshot with no open session, not from a journal full of history.
    _memory.checkpoint(_capture(now));
    _running = false;
  }
}

/// One tick's view of the focus state. [available] is false when the policy
/// worker is configured but unreachable; the tracker then skips focus checks
/// for that tick instead of letting the daemon advance the state machine.
class _FocusRead {
  const _FocusRead(this.available, this.state);
  final bool available;
  final Map<String, dynamic>? state;
}
