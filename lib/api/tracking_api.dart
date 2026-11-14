import 'transport.dart';

/// **Tracking** — control of the observation loop itself.
///
/// This is the only domain that can start or stop the reconciler. It is
/// constructed only by `ScreenGuardApi.forDaemon()`.
class TrackingApi {
  TrackingApi(this._t);

  final Transport _t;

  Future<void> start() async => _t.call('tracking', 'start', const {});

  void stop() => _t.call('tracking', 'stop', const {});

  bool get isRunning => _t.call('tracking', 'isRunning', const {}) as bool;

  String? get currentApp =>
      _t.call('tracking', 'currentApp', const {}) as String?;

  bool? get currentIdle =>
      _t.call('tracking', 'currentIdle', const {}) as bool?;

  Duration get pollInterval => Duration(
      milliseconds: _t.call('tracking', 'pollIntervalMs', const {}) as int);

  int get idleThresholdMs =>
      _t.call('tracking', 'idleThresholdMs', const {}) as int;

  /// Detailed session-memory state: the journal paths, the session that was
  /// resumed or closed at startup, and the current in-memory session. This is
  /// the introspection surface the C session worker will replace.
  Map<String, dynamic> get sessionMemory =>
      (_t.call('tracking', 'sessionMemory', const {}) as Map)
          .cast<String, dynamic>();

  /// Force a snapshot + journal truncate. Safe to call at any time.
  ///
  /// This only compacts the crash-recovery files. SQLite usage history is
  /// never rewritten or merged, so totals and session boundaries stay exact.
  void compactSessionMemory() =>
      _t.call('tracking', 'compactSessionMemory', const {});
}
