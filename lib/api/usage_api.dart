import 'transport.dart';

/// **Usage** — facts, read-only.
///
/// Everything here answers "what happened". No method in this class mutates
/// state. Recording new sessions lives in `StorageApi` and is only reachable
/// from the daemon.
class UsageApi {
  UsageApi(this._t);

  final Transport _t;

  /// Mirrors `DatabaseService.recentEvents`.
  List<Map<String, dynamic>> recentEvents({int limit = 200}) =>
      (_t.call('usage', 'recentEvents', {'limit': limit}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.eventCount`.
  int eventCount() =>
      _t.call('usage', 'eventCount', const {}) as int;

  /// Mirrors `DatabaseService.eventsForDay`.
  List<Map<String, dynamic>> eventsForDay(DateTime day) =>
      (_t.call('usage', 'eventsForDay', {'day': day.millisecondsSinceEpoch}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.todayTotalMs`.
  int todayTotalMs() =>
      _t.call('usage', 'todayTotalMs', const {}) as int;

  /// Mirrors `DatabaseService.yesterdayTotalMs`.
  int yesterdayTotalMs() =>
      _t.call('usage', 'yesterdayTotalMs', const {}) as int;

  /// Mirrors `DatabaseService.appHistory`.
  List<Map<String, dynamic>> appHistory(String app, {int days = 7}) =>
      (_t.call('usage', 'appHistory', {'app': app, 'days': days}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.recentUnknownSessions`.
  int recentUnknownSessions({int minutes = 10}) =>
      _t.call('usage', 'recentUnknownSessions', {'minutes': minutes}) as int;

  /// Mirrors `DatabaseService.getAppTodayMs`.
  int getAppTodayMs(String app, {List<String>? aliases}) =>
      _t.call('usage', 'getAppTodayMs', {'app': app, 'aliases': aliases}) as int;

  /// Mirrors `DatabaseService.lastAppActivityMs`.
  int? lastAppActivityMs(String app, {List<String>? aliases}) =>
      _t.call('usage', 'lastAppActivityMs', {'app': app, 'aliases': aliases}) as int?;

  /// Mirrors `DatabaseService.isAppInactive`.
  bool isAppInactive(String app, {List<String>? aliases, int inactiveAfterMs = 12 * 60 * 60 * 1000}) =>
      _t.call('usage', 'isAppInactive', {'app': app, 'aliases': aliases, 'inactiveAfterMs': inactiveAfterMs}) as bool;

  /// Mirrors `DatabaseService.inactiveApps`.
  List<String> inactiveApps({int inactiveAfterMs = 12 * 60 * 60 * 1000}) =>
      (_t.call('usage', 'inactiveApps', {'inactiveAfterMs': inactiveAfterMs}) as List).cast<String>();

  /// Mirrors `DatabaseService.getLastFocusSession`.
  Map<String, dynamic>? getLastFocusSession() =>
      _t.call('usage', 'getLastFocusSession', const {}) as Map<String,dynamic>?;

  /// Mirrors `DatabaseService.getCompletedFocusSessionsToday`.
  int getCompletedFocusSessionsToday() =>
      _t.call('usage', 'getCompletedFocusSessionsToday', const {}) as int;

  /// Mirrors `DatabaseService.allTrackedApps`.
  List<Map<String, dynamic>> allTrackedApps() =>
      (_t.call('usage', 'allTrackedApps', const {}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.perAppForDate`.
  List<Map<String, dynamic>> perAppForDate(DateTime date, {int limit = 10}) =>
      (_t.call('usage', 'perAppForDate', {'date': date.millisecondsSinceEpoch, 'limit': limit}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.getIdleTimeForDate`.
  int getIdleTimeForDate(DateTime date) =>
      _t.call('usage', 'getIdleTimeForDate', {'date': date.millisecondsSinceEpoch}) as int;

  /// Mirrors `DatabaseService.getWeekData`.
  List<Map<String, dynamic>> getWeekData({int weekOffset = 0}) =>
      (_t.call('usage', 'getWeekData', {'weekOffset': weekOffset}) as List).cast<Map<String,dynamic>>();

  /// Mirrors `DatabaseService.last30DaysTotalMs`.
  int last30DaysTotalMs() =>
      _t.call('usage', 'last30DaysTotalMs', const {}) as int;

  /// Mirrors `DatabaseService.sessionDateRange`.
  List<int>? sessionDateRange() =>
      (_t.call('usage', 'sessionDateRange', const {}) as List?)?.cast<int>();
}
