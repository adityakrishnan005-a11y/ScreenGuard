part of 'screenguard_api.dart';

/// **Storage** — raw persistence, guarded.
///
/// The only interface allowed to write facts (`openSession`, `closeSession`) or
/// to destroy them (`clearAllUsageData` and friends). The guard is structural:
/// `ScreenGuardApi.forGui()` never builds a StorageApi, so GUI code has no
/// reachable path to these methods, and the dispatcher additionally refuses
/// every storage call when it runs without storage rights.
///
/// Do not hand this to a screen, a widget, or a network client.
class StorageApi {
  StorageApi._(this._t);

  final Transport _t;

  /// Mirrors `DatabaseService.recordEvent`.
  void recordEvent(String kind, {int? at, String? app, String? detail}) =>
      _t.call('storage', 'recordEvent', {'kind': kind, 'at': at, 'app': app, 'detail': detail});

  /// Mirrors `DatabaseService.openSession`.
  int openSession({required String app, String? appName, String? title, int? pid, required int startedAt, required bool idle}) =>
      _t.call('storage', 'openSession', {'app': app, 'appName': appName, 'title': title, 'pid': pid, 'startedAt': startedAt, 'idle': idle}) as int;

  /// Mirrors `DatabaseService.closeSession`.
  void closeSession(int id, int endedAt) =>
      _t.call('storage', 'closeSession', {'id': id, 'endedAt': endedAt});

  /// Mirrors `DatabaseService.databaseFileSize`.
  int databaseFileSize() =>
      _t.call('storage', 'databaseFileSize', const {}) as int;

  /// Mirrors `DatabaseService.sessionCount`.
  int sessionCount() =>
      _t.call('storage', 'sessionCount', const {}) as int;

  /// Mirrors `DatabaseService.dayStartMs`.
  int dayStartMs(DateTime day) =>
      _t.call('storage', 'dayStartMs', {'day': day.millisecondsSinceEpoch}) as int;

  /// Mirrors `DatabaseService.nextDayStartMs`.
  int nextDayStartMs(DateTime day) =>
      _t.call('storage', 'nextDayStartMs', {'day': day.millisecondsSinceEpoch}) as int;

  /// Mirrors `DatabaseService.deleteSessionsInRange`.
  int deleteSessionsInRange(DateTime from, DateTime to) =>
      _t.call('storage', 'deleteSessionsInRange', {'from': from.millisecondsSinceEpoch, 'to': to.millisecondsSinceEpoch}) as int;

  /// Mirrors `DatabaseService.deleteSessionsOnDates`.
  int deleteSessionsOnDates(Iterable<DateTime> days) =>
      _t.call('storage', 'deleteSessionsOnDates', {'days': days.map((d) => d.millisecondsSinceEpoch).toList()}) as int;

  /// Mirrors `DatabaseService.clearAllUsageData`.
  int clearAllUsageData() =>
      _t.call('storage', 'clearAllUsageData', const {}) as int;

  /// Mirrors `DatabaseService.closeOrphanedSessions`.
  ///
  /// [preserveId] is the session the session-memory journal just resumed; it
  /// is genuinely open and must survive crash recovery. The tracker passes it
  /// so a quick restart is never truncated to one polling interval.
  int closeOrphanedSessions({int maxDurationMs = 10000, int? preserveId}) =>
      _t.call('storage', 'closeOrphanedSessions', {
        'maxDurationMs': maxDurationMs,
        'preserveId': preserveId,
      }) as int;
}
