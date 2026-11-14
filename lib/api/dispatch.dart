import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/tracker.dart';

/// A request that cannot be served. The message is the wire-level reason.
class DispatchException implements Exception {
  const DispatchException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// Conversions from decoded JSON back to Dart types. Every value crosses a
/// socket (or the in-process shortcut) as JSON, so nothing may arrive as the
/// exact type the database call expects.

T _req<T>(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) throw DispatchException('missing-argument:$key');
  return value as T;
}

int _ri(Map<String, Object?> args, String key) => _req<num>(args, key).toInt();
bool _rb(Map<String, Object?> args, String key) => _req<bool>(args, key);
String _rs(Map<String, Object?> args, String key) => _req<String>(args, key);
DateTime _rdt(Map<String, Object?> args, String key) =>
    DateTime.fromMillisecondsSinceEpoch(_ri(args, key));
Iterable<DateTime> _rdts(Map<String, Object?> args, String key) =>
    _req<List<Object?>>(args, key)
        .map((Object? e) =>
            DateTime.fromMillisecondsSinceEpoch((e! as num).toInt()))
        .toList();

int _i(Object? v, [int? fallback]) =>
    v == null ? (fallback ?? 0) : (v as num).toInt();
int? _ni(Object? v) => v == null ? null : (v as num).toInt();
String _s(Object? v, [String fallback = '']) =>
    v == null ? fallback : v as String;
String? _ns(Object? v) => v == null ? null : v as String;
bool _b(Object? v, [bool fallback = false]) => v == null ? fallback : v as bool;
List<String>? _ls(Object? v) =>
    v == null ? null : (v as List).map((Object? e) => e! as String).toList();

/// The one implementation of every domain method.
///
/// The daemon owns the canonical instance (it has storage). The GUI builds a
/// read-only fallback instance only when no broker socket is reachable; that
/// instance is refused every storage mutation by [allowStorage].
class ScreenGuardDispatch {
  ScreenGuardDispatch({
    required this.db,
    this.tracker,
    this.allowStorage = true,
  });

  final DatabaseService db;
  final Tracker? tracker;

  /// Structural guard for the in-process fallback: usage and policy are
  /// readable/editable, storage is not.
  final bool allowStorage;

  /// The subset of the storage domain a screen may ask for directly. These
  /// are explicit user intents ("delete this range", "forget everything"),
  /// not the raw record primitives, so they stay available even when
  /// [allowStorage] is false.
  static const maintenanceMethods = {
    'databaseFileSize',
    'databaseFilePath',
    'sessionCount',
    'deleteSessionsInRange',
    'deleteSessionsOnDates',
    'clearAllUsageData',
  };

  static const domains = {'system', 'usage', 'policy', 'tracking', 'storage'};

  /// Synchronous by design: the GUI's domain façade is synchronous and a
  /// local unix-socket round trip is microseconds. Async only at the edges.
  Object? call(String domain, String method, Map<String, Object?> args) {
    if (!domains.contains(domain)) {
      throw const DispatchException('unknown-domain');
    }
    switch (domain) {
      case 'system':
        return _system(method, args);
      case 'usage':
        return _usage(method, args);
      case 'policy':
        return _policy(method, args);
      case 'tracking':
        return _tracking(method, args);
      case 'storage':
        if (!allowStorage && !maintenanceMethods.contains(method)) {
          throw const DispatchException('forbidden');
        }
        return _storage(method, args);
    }
    throw const DispatchException('unknown-domain');
  }

  Object? _system(String method, Map<String, Object?> args) {
    switch (method) {
      case 'ping':
        return 'pong';
      case 'version':
        return const String.fromEnvironment('SCREENGUARD_VERSION',
            defaultValue: 'dev');
    }
    throw const DispatchException('unknown-method');
  }

  Object? _usage(String method, Map<String, Object?> args) {
    switch (method) {
      case 'recentEvents':
        return db.recentEvents(limit: _i(args['limit'], 200));
      case 'eventCount':
        return db.eventCount();
      case 'eventsForDay':
        return db.eventsForDay(_rdt(args, 'day'));
      case 'todayTotalMs':
        return db.todayTotalMs();
      case 'yesterdayTotalMs':
        return db.yesterdayTotalMs();
      case 'appHistory':
        return db.appHistory(_rs(args, 'app'), days: _i(args['days'], 7));
      case 'recentUnknownSessions':
        return db.recentUnknownSessions(minutes: _i(args['minutes'], 10));
      case 'getAppTodayMs':
        return db.getAppTodayMs(_rs(args, 'app'),
            aliases: _ls(args['aliases']));
      case 'lastAppActivityMs':
        return db.lastAppActivityMs(_rs(args, 'app'),
            aliases: _ls(args['aliases']));
      case 'isAppInactive':
        return db.isAppInactive(_rs(args, 'app'),
            aliases: _ls(args['aliases']),
            inactiveAfterMs: _i(args['inactiveAfterMs'], 12 * 60 * 60 * 1000));
      case 'inactiveApps':
        return db.inactiveApps(
            inactiveAfterMs: _i(args['inactiveAfterMs'], 12 * 60 * 60 * 1000));
      case 'getLastFocusSession':
        return db.getLastFocusSession();
      case 'getCompletedFocusSessionsToday':
        return db.getCompletedFocusSessionsToday();
      case 'allTrackedApps':
        return db.allTrackedApps();
      case 'perAppForDate':
        return db.perAppForDate(_rdt(args, 'date'),
            limit: _i(args['limit'], 10));
      case 'getIdleTimeForDate':
        return db.getIdleTimeForDate(_rdt(args, 'date'));
      case 'getWeekData':
        return db.getWeekData(weekOffset: _i(args['weekOffset'], 0));
      case 'last30DaysTotalMs':
        return db.last30DaysTotalMs();
      case 'sessionDateRange':
        return db.sessionDateRange();
    }
    throw const DispatchException('unknown-method');
  }

  Object? _policy(String method, Map<String, Object?> args) {
    switch (method) {
      case 'getAppLimit':
        return db.getAppLimit(_rs(args, 'app'), aliases: _ls(args['aliases']));
      case 'setAppLimit':
        db.setAppLimit(_rs(args, 'app'), _ri(args, 'limitMs'),
            enabled: _b(args['enabled'], true));
        return null;
      case 'addTempExtension':
        db.addTempExtension(_rs(args, 'app'), _ri(args, 'extensionMs'));
        return null;
      case 'deleteAppLimit':
        db.deleteAppLimit(_rs(args, 'app'));
        return null;
      case 'getDistractingApps':
        return db.getDistractingApps().toList();
      case 'toggleDistractingApp':
        db.toggleDistractingApp(_rs(args, 'app'));
        return null;
      case 'isDistractingApp':
        return db.isDistractingApp(_rs(args, 'app'),
            aliases: _ls(args['aliases']));
      case 'startFocusSession':
        db.startFocusSession(_ri(args, 'durationMinutes'),
            totalCycles: _ni(args['totalCycles']),
            breakMinutes: _ni(args['breakMinutes']));
        return null;
      case 'pauseFocusSession':
        db.pauseFocusSession();
        return null;
      case 'resumeFocusSession':
        db.resumeFocusSession();
        return null;
      case 'getActiveFocusState':
        return db.getActiveFocusState();
      case 'cancelFocusSession':
        db.cancelFocusSession();
        return null;
      case 'getDailyGoalMs':
        return db.getDailyGoalMs();
      case 'setDailyGoalMs':
        db.setDailyGoalMs(_ri(args, 'goalMs'));
        return null;
      case 'getSetting':
        return db.getSetting(_rs(args, 'key'),
            defaultValue: _s(args['defaultValue'], ''));
      case 'setSetting':
        db.setSetting(_rs(args, 'key'), _rs(args, 'value'));
        return null;
      case 'isNotificationsGloballyEnabled':
        return db.isNotificationsGloballyEnabled();
      case 'setNotificationsGloballyEnabled':
        db.setNotificationsGloballyEnabled(_rb(args, 'enabled'));
        return null;
      case 'isSoundGloballyEnabled':
        return db.isSoundGloballyEnabled();
      case 'setSoundGloballyEnabled':
        db.setSoundGloballyEnabled(_rb(args, 'enabled'));
        return null;
      case 'getSoundTheme':
        return db.getSoundTheme();
      case 'setSoundTheme':
        db.setSoundTheme(_rs(args, 'theme'));
        return null;
      case 'getCustomSoundPath':
        return db.getCustomSoundPath();
      case 'setCustomSoundPath':
        db.setCustomSoundPath(_rs(args, 'path'));
        return null;
      case 'isEventNotificationEnabled':
        return db.isEventNotificationEnabled(_rs(args, 'eventKey'));
      case 'setEventNotificationEnabled':
        db.setEventNotificationEnabled(
            _rs(args, 'eventKey'), _rb(args, 'enabled'));
        return null;
      case 'isEventSoundEnabled':
        return db.isEventSoundEnabled(_rs(args, 'eventKey'));
      case 'setEventSoundEnabled':
        db.setEventSoundEnabled(_rs(args, 'eventKey'), _rb(args, 'enabled'));
        return null;
      case 'isPomodoroLoopEnabled':
        return db.isPomodoroLoopEnabled();
      case 'setPomodoroLoopEnabled':
        db.setPomodoroLoopEnabled(_rb(args, 'enabled'));
        return null;
      case 'isFocusStrictAutoclose':
        return db.isFocusStrictAutoclose();
      case 'setFocusStrictAutoclose':
        db.setFocusStrictAutoclose(_rb(args, 'enabled'));
        return null;
      case 'isFocusAppGridLayout':
        return db.isFocusAppGridLayout();
      case 'setFocusAppGridLayout':
        db.setFocusAppGridLayout(_rb(args, 'grid'));
        return null;
      case 'getFocusGraceUntilMs':
        return db.getFocusGraceUntilMs(_rs(args, 'app'));
      case 'setFocusGraceMinutes':
        db.setFocusGraceMinutes(_rs(args, 'app'), _ri(args, 'minutes'));
        return null;
      case 'isFocusGraceActive':
        return db.isFocusGraceActive(_rs(args, 'app'));
      case 'getPomodoroCyclesCount':
        return db.getPomodoroCyclesCount();
      case 'setPomodoroCyclesCount':
        db.setPomodoroCyclesCount(_ri(args, 'count'));
        return null;
      case 'getPomodoroBreakMinutes':
        return db.getPomodoroBreakMinutes();
      case 'setPomodoroBreakMinutes':
        db.setPomodoroBreakMinutes(_ri(args, 'minutes'));
        return null;
      case 'hasNotifiedDailyMilestone':
        return db.hasNotifiedDailyMilestone(
            _rs(args, 'milestoneKey'), _rs(args, 'dateKey'));
      case 'markDailyMilestoneNotified':
        db.markDailyMilestoneNotified(
            _rs(args, 'milestoneKey'), _rs(args, 'dateKey'));
        return null;
      case 'getOvertimeMilestoneIndex':
        return db.getOvertimeMilestoneIndex(_rs(args, 'dateKey'));
      case 'setOvertimeMilestoneIndex':
        db.setOvertimeMilestoneIndex(_rs(args, 'dateKey'), _ri(args, 'index'));
        return null;
    }
    throw const DispatchException('unknown-method');
  }

  Object? _tracking(String method, Map<String, Object?> args) {
    switch (method) {
// tracking: control of the observation loop itself
      case 'start':
        final t = tracker;
        if (t == null) throw const DispatchException('daemon-unavailable');
        t.run();
        return null;
      case 'stop':
        final t = tracker;
        if (t == null) throw const DispatchException('daemon-unavailable');
        t.stop();
        return null;
      case 'isRunning':
        return tracker?.isRunning;
      case 'currentApp':
        return tracker?.currentApp;
      case 'currentIdle':
        return tracker?.currentIdle;
      case 'pollIntervalMs':
        return tracker?.pollInterval.inMilliseconds;
      case 'idleThresholdMs':
        return tracker?.idleThresholdMs;
      case 'sessionMemory':
        final t = tracker;
        if (t == null) throw const DispatchException('daemon-unavailable');
        return t.sessionMemoryInfo();
      case 'compactSessionMemory':
        final t = tracker;
        if (t == null) throw const DispatchException('daemon-unavailable');
        t.compactSessionMemory();
        return null;
    }
    throw const DispatchException('unknown-method');
  }

  Object? _storage(String method, Map<String, Object?> args) {
    switch (method) {
      // Not a DatabaseService method: the path is a process property, but the
      // "your data" panel needs it without opening the database itself.
      case 'databaseFilePath':
        return db.path;

      case 'init':
        db.init(path: _ns(args['path']));
        return null;
      case 'recordEvent':
        db.recordEvent(_rs(args, 'kind'),
            at: _ni(args['at']),
            app: _ns(args['app']),
            detail: _ns(args['detail']));
        return null;
      case 'openSession':
        return db.openSession(
            app: _rs(args, 'app'),
            appName: _ns(args['appName']),
            title: _ns(args['title']),
            pid: _ni(args['pid']),
            startedAt: _ri(args, 'startedAt'),
            idle: _rb(args, 'idle'));
      case 'closeSession':
        db.closeSession(_ri(args, 'id'), _ri(args, 'endedAt'));
        return null;
      case 'databaseFileSize':
        return db.databaseFileSize();
      case 'sessionCount':
        return db.sessionCount();
      case 'dayStartMs':
        return DatabaseService.dayStartMs(_rdt(args, 'day'));
      case 'nextDayStartMs':
        return DatabaseService.nextDayStartMs(_rdt(args, 'day'));
      case 'deleteSessionsInRange':
        return db.deleteSessionsInRange(_rdt(args, 'from'), _rdt(args, 'to'));
      case 'deleteSessionsOnDates':
        return db.deleteSessionsOnDates(_rdts(args, 'days'));
      case 'clearAllUsageData':
        return db.clearAllUsageData();
      case 'closeOrphanedSessions':
        return db.closeOrphanedSessions(
            maxDurationMs: _i(args['maxDurationMs'], 10000),
            preserveId: _ni(args['preserveId']));
    }
    throw const DispatchException('unknown-method');
  }
}
