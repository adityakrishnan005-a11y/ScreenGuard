import 'dart:io';

import 'package:screenguard/api/transport.dart';
import 'package:screenguard/services/db.dart';

/// The daemon-side implementation of [StorageWriteSink], backed by
/// `digiwelld-store`.
///
/// The store is the single writer for sessions and events. Reads still use
/// the daemon's own SQLite connection: WAL lets a reader see every committed
/// write without taking the write lock.
///
/// Failure policy mirrors what the worker exists to protect:
///
///   * [openSession] throws. The tracker skips the tick and retries; it never
///     invents a session id or records against a row that was not created.
///   * [recordEvent], [closeSession] and [closeOrphanedSessions] are
///     best-effort. Losing a diagnostic event is harmless, and a lost close
///     is repaired by `closeOrphanedSessions` on the next daemon start (the
///     same guarantee a crash already relies on). Crashing the daemon while
///     the store restarts would lose far more.
class StoreWriteSink implements StorageWriteSink {
  StoreWriteSink(this._transport);

  final Transport _transport;
  bool _reported = false;

  void _noteFailure(String what, TransportException e) {
    if (_reported) return;
    _reported = true;
    stderr.writeln('[store] $what failed: ${e.reason}');
  }

  void _noteSuccess() {
    _reported = false;
  }

  @override
  void recordEvent(String kind, {int? at, String? app, String? detail}) {
    try {
      _transport.call('storage', 'recordEvent', {
        'kind': kind,
        'at': at,
        'app': app,
        'detail': detail,
      });
      _noteSuccess();
    } on TransportException catch (e) {
      _noteFailure('recordEvent($kind)', e);
    }
  }

  @override
  int openSession({
    required String app,
    String? appName,
    String? title,
    int? pid,
    required int startedAt,
    required bool idle,
  }) {
    try {
      final id = _transport.call('storage', 'openSession', {
        'app': app,
        'appName': appName,
        'title': title,
        'pid': pid,
        'startedAt': startedAt,
        'idle': idle,
      }) as int;
      _noteSuccess();
      return id;
    } on TransportException catch (e) {
      _noteFailure('openSession($app)', e);
      rethrow;
    }
  }

  @override
  void closeSession(int id, int endedAt) {
    try {
      _transport
          .call('storage', 'closeSession', {'id': id, 'endedAt': endedAt});
      _noteSuccess();
    } on TransportException catch (e) {
      _noteFailure('closeSession($id)', e);
    }
  }

  @override
  int closeOrphanedSessions({int maxDurationMs = 10000, int? preserveId}) {
    try {
      final repaired = _transport.call('storage', 'closeOrphanedSessions', {
        'maxDurationMs': maxDurationMs,
        'preserveId': preserveId,
      }) as int;
      _noteSuccess();
      return repaired;
    } on TransportException catch (e) {
      _noteFailure('closeOrphanedSessions', e);
      return 0;
    }
  }
}
