import 'dart:convert';
import 'dart:io';

import 'package:screenguard/api/sync_unix_socket.dart';
import 'package:screenguard/services/session_memory.dart';

/// Where the tracker's durable session state is written.
///
/// The contract is intentionally the same for both implementations:
///
///   * [SessionJournal] (Dart)  — the transitional local writer
///   * [SessionWorkerBackend]   — the C `digiwelld-session` worker
///
/// Both use the same `session-state.json` + `session-journal.jsonl` format, so
/// either one can take over from the other after a crash. Only one of them
/// writes at a time.
abstract class SessionMemoryBackend {
  /// The latest state, or null when nothing has been written yet.
  SessionMemory? load();

  /// Record a transition. The local journal appends a full state; the remote
  /// worker diffs it against the last state it saw and sends the matching
  /// begin/tick/close/env transition.
  void append(SessionMemory state);

  /// Write a compact snapshot and truncate the journal.
  void checkpoint(SessionMemory state);

  /// Delete the durable state. Used by tests and by the daemon's hard reset.
  void clear();

  /// Paths, sequence numbers and worker health, for diagnostics.
  Map<String, Object?> info();

  /// A recovery decision made by a remote worker at its own startup. Null for
  /// the local journal, whose decision is made by [Tracker].
  SessionWorkerRecovery? get recovery;

  /// Short name for logs.
  String get name;
}

/// The transitional writer: [SessionJournal] in the daemon's runtime dir.
class LocalSessionMemoryBackend implements SessionMemoryBackend {
  LocalSessionMemoryBackend(this.journal);

  final SessionJournal journal;

  @override
  SessionMemory? load() => journal.load();

  @override
  void append(SessionMemory state) => journal.append(state);

  @override
  void checkpoint(SessionMemory state) => journal.checkpoint(state);

  @override
  void clear() => journal.clear();

  @override
  Map<String, Object?> info() => journal.info();

  @override
  SessionWorkerRecovery? get recovery => null;

  @override
  String get name => 'local-journal';
}

/// The recovery report from the worker's own startup.
class SessionWorkerRecovery {
  const SessionWorkerRecovery({
    this.restored = false,
    this.resumedSessionId,
    this.closedSessionId,
    this.closeAtMs,
    this.restartGapMs,
  });

  final bool restored;
  final int? resumedSessionId;
  final int? closedSessionId;
  final int? closeAtMs;
  final int? restartGapMs;

  factory SessionWorkerRecovery.fromJson(Map<String, Object?> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    return SessionWorkerRecovery(
      restored: json['restored'] == true,
      resumedSessionId: asInt(json['resumed_session_id']),
      closedSessionId: asInt(json['closed_session_id']),
      closeAtMs: asInt(json['close_at_ms']),
      restartGapMs: asInt(json['restart_gap_ms']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'restored': restored,
        'resumed_session_id': resumedSessionId,
        'closed_session_id': closedSessionId,
        'close_at_ms': closeAtMs,
        'restart_gap_ms': restartGapMs,
      };
}

class SessionWorkerException implements Exception {
  SessionWorkerException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// A blocking client for `digiwelld-session`.
///
/// The worker is a local process on a private AF_UNIX socket. The calls are
/// synchronous because the tracker is synchronous; one round trip is a few
/// microseconds. A short timeout keeps a wedged worker from stalling the
/// observation loop: the caller falls back to the local journal.
class SessionWorkerBackend implements SessionMemoryBackend {
  SessionWorkerBackend({
    required this.socketPath,
    this.timeout = const Duration(milliseconds: 800),
    this.startupGrace = const Duration(seconds: 2),
  });

  final String socketPath;
  final Duration timeout;

  /// How long the first load may wait for the broker to finish starting the
  /// worker. The broker spawns both children together; a daemon that connects
  /// before the worker binds would otherwise start tracking through the local
  /// fallback and leave the worker's recovered session behind.
  final Duration startupGrace;

  SessionMemory? _lastSent;
  SessionWorkerRecovery? _recovery;
  bool _startupGracePending = true;

  @override
  String get name => 'digiwelld-session';

  @override
  SessionWorkerRecovery? get recovery => _recovery;

  @override
  SessionMemory? load() {
    final deadline = DateTime.now().add(startupGrace);
    final waitForStartup = _startupGracePending;
    _startupGracePending = false;
    while (true) {
      try {
        return _loadOnce();
      } on SessionWorkerException {
        if (!waitForStartup || !DateTime.now().isBefore(deadline)) rethrow;
        sleep(const Duration(milliseconds: 50));
      }
    }
  }

  SessionMemory? _loadOnce() {
    final raw = _call('session', 'restore', const <String, Object?>{});
    if (raw is! Map) return null;
    final reply = raw.cast<String, Object?>();
    final recovery = reply['recovery'];
    if (recovery is Map) {
      _recovery = SessionWorkerRecovery.fromJson(
        recovery.cast<String, Object?>(),
      );
    }
    final state = reply['state'];
    if (state is! Map) return null;
    final memory = SessionMemory.fromJson(
      state.map((key, value) => MapEntry(key.toString(), value)),
    );
    _lastSent = memory;
    return memory;
  }

  @override
  void append(SessionMemory state) {
    _sync(state);
  }

  @override
  void checkpoint(SessionMemory state) {
    _sync(state);
    _call('session', 'checkpoint', const <String, Object?>{});
  }

  @override
  void clear() {
    final current = _lastSent?.currentSessionId;
    if (current != null) {
      _call('session', 'close', <String, Object?>{
        'id': current,
        'at_ms': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _call('session', 'checkpoint', const <String, Object?>{});
    _lastSent = null;
  }

  @override
  Map<String, Object?> info() {
    try {
      final raw = _call('session', 'status', const <String, Object?>{});
      if (raw is! Map) {
        return <String, Object?>{'remote': true, 'enabled': false};
      }
      final status = raw.cast<String, Object?>();
      final state = status['state'];
      final writtenAt = state is Map ? state['written_at_ms'] : null;
      return <String, Object?>{
        'directory': status['state_dir'],
        'snapshot_path': status['snapshot_path'],
        'journal_path': status['journal_path'],
        'journal_entries': status['journal_entries'],
        'last_seq': status['seq'],
        'last_written_at_ms': writtenAt,
        'snapshot_bytes': status['snapshot_bytes'],
        'journal_bytes': status['journal_bytes'],
        'enabled': true,
        'remote': true,
        'socket': socketPath,
        'worker': status,
      };
    } catch (e) {
      return <String, Object?>{
        'remote': true,
        'enabled': false,
        'socket': socketPath,
        'error': e.toString(),
      };
    }
  }

  /// Try the worker once. Returns null when it is not reachable.
  bool probe() {
    try {
      final raw = _call('system', 'ping', const <String, Object?>{});
      return raw == 'pong' || raw == true;
    } catch (_) {
      return false;
    }
  }

  /// Bring the worker's view in line with [state].
  ///
  /// The worker is transition-oriented, not a state store. Diffing against the
  /// last state we sent means a tracker restart or a worker restart can be
  /// repaired with the smallest honest sequence:
  ///
  ///   id changed null -> X      begin
  ///   id changed X -> null      close X at the last observed tick
  ///   id changed X -> Y         close X, begin Y
  ///   same id                   tick (+ env if the live flags changed)
  void _sync(SessionMemory state) {
    if (_lastSent == null) {
      // A caller that did not load first still needs a base. If the worker is
      // reachable this also refreshes the recovery report; failure propagates
      // so the fallback wrapper can take over.
      load();
    }
    final last = _lastSent;
    final lastId = last?.currentSessionId;
    final id = state.currentSessionId;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (lastId != id) {
      if (lastId != null) {
        _call('session', 'close', <String, Object?>{
          'id': lastId,
          'at_ms': state.lastTickMs ?? now,
        });
      }
      if (id != null) {
        _call('session', 'begin', <String, Object?>{
          'id': id,
          'app': state.currentApp ?? '',
          'title': state.currentTitle ?? '',
          'pid': state.currentPid ?? 0,
          'idle': state.currentIdle ?? false,
          'at_ms': state.sessionStartedAtMs ?? state.lastTickMs ?? now,
          'started_at_ms': state.sessionStartedAtMs ?? now,
        });
      }
    } else if (id != null) {
      // `begin` is idempotent for the same id, so this both refreshes the
      // tick and reopens the session if the worker restarted while we were
      // in fallback mode.
      _call('session', 'begin', <String, Object?>{
        'id': id,
        'app': state.currentApp ?? '',
        'title': state.currentTitle ?? '',
        'pid': state.currentPid ?? 0,
        'idle': state.currentIdle ?? false,
        'at_ms': state.lastTickMs ?? now,
        'started_at_ms': state.sessionStartedAtMs ?? now,
      });
    }

    final envChanged = last == null ||
        last.sessionLocked != state.sessionLocked ||
        last.suspended != state.suspended ||
        last.dayStartMs != state.dayStartMs ||
        last.consecutiveUnknownTicks != state.consecutiveUnknownTicks;
    if (envChanged) {
      _call('session', 'env', <String, Object?>{
        'locked': state.sessionLocked,
        'suspended': state.suspended,
        'day_start_ms': state.dayStartMs,
        'unknown_ticks': state.consecutiveUnknownTicks,
      });
    }
    _lastSent = state;
  }

  Object? _call(String domain, String method, Map<String, Object?> args) {
    SyncUnixSocket socket;
    try {
      socket = SyncUnixSocket.connect(socketPath, timeout: timeout);
    } on SyncSocketException catch (e) {
      throw SessionWorkerException('worker-connect-failed:${e.errno}');
    }

    try {
      socket.writeAll(utf8.encode('$domain $method ${jsonEncode(args)}\n'));
      final bytes = <int>[];
      var complete = false;
      while (bytes.length < 4 * 1024 * 1024 && !complete) {
        final chunk = socket.readSome(65536);
        if (chunk.isEmpty) break;
        for (final byte in chunk) {
          if (byte == 0x0a) {
            complete = true;
            break;
          }
          bytes.add(byte);
        }
      }
      if (bytes.isEmpty) throw SessionWorkerException('worker-empty-response');
      if (bytes.last == 0x0d) bytes.removeLast();
      final line = utf8.decode(bytes, allowMalformed: true);
      if (line.startsWith('ok ')) {
        final payload = line.substring(3);
        try {
          return jsonDecode(payload);
        } on FormatException {
          return payload;
        }
      }
      if (line == 'ok') return null;
      if (line.startsWith('err ')) {
        throw SessionWorkerException(line.substring(4));
      }
      throw SessionWorkerException('worker-malformed-response');
    } on SessionWorkerException {
      rethrow;
    } on SyncSocketException catch (e) {
      throw SessionWorkerException('worker-io-failed:${e.errno}');
    } catch (e) {
      throw SessionWorkerException('worker-failed:$e');
    } finally {
      socket.close();
    }
  }
}

/// Uses [digiwelld-session] when it is reachable and falls back to the local
/// journal when it is not.
///
/// The fallback is deliberately not silent: [usingFallback] is exposed for the
/// status API, and every retry first reloads the worker's state so a worker
/// that restarted during the outage is brought back in line with the tracker
/// rather than left with a stale session id.
class FallbackSessionMemoryBackend implements SessionMemoryBackend {
  FallbackSessionMemoryBackend({
    required this.primary,
    required this.fallback,
    this.retryInterval = const Duration(seconds: 5),
  });

  final SessionWorkerBackend primary;
  final LocalSessionMemoryBackend fallback;
  final Duration retryInterval;

  bool _usingFallback = false;
  int _lastRetryMs = 0;

  bool get usingFallback => _usingFallback;

  @override
  String get name => _usingFallback
      ? '${fallback.name} (worker-unavailable)'
      : primary.name;

  @override
  SessionWorkerRecovery? get recovery =>
      _usingFallback ? null : primary.recovery;

  bool _shouldRetry(int now) {
    if (!_usingFallback) return true;
    if (now - _lastRetryMs < retryInterval.inMilliseconds) return false;
    _lastRetryMs = now;
    return true;
  }

  @override
  SessionMemory? load() {
    _lastRetryMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final state = primary.load();
      _usingFallback = false;
      return state;
    } catch (_) {
      _usingFallback = true;
      return fallback.load();
    }
  }

  @override
  void append(SessionMemory state) {
    _write(state, checkpoint: false);
  }

  @override
  void checkpoint(SessionMemory state) {
    _write(state, checkpoint: true);
  }

  void _write(SessionMemory state, {required bool checkpoint}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_shouldRetry(now)) {
      try {
        if (_usingFallback) {
          // The worker restarted while we were writing locally. Reloading
          // first makes _sync diff against what the worker actually has.
          primary.load();
        }
        if (checkpoint) {
          primary.checkpoint(state);
        } else {
          primary.append(state);
        }
        _usingFallback = false;
        return;
      } catch (_) {
        _usingFallback = true;
      }
    }
    if (checkpoint) {
      fallback.checkpoint(state);
    } else {
      fallback.append(state);
    }
  }

  @override
  void clear() {
    try {
      primary.clear();
      _usingFallback = false;
    } catch (_) {
      _usingFallback = true;
      fallback.clear();
    }
  }

  @override
  Map<String, Object?> info() {
    if (!_usingFallback) {
      final remote = primary.info();
      if (remote['enabled'] == true) return remote;
    }
    return <String, Object?>{
      ...fallback.info(),
      'remote': false,
      'fallback': true,
      'worker_socket': primary.socketPath,
    };
  }
}

/// Build the backend the daemon should use.
///
/// `SCREENGUARD_SESSION_SOCKET` is set by the broker when it supervises the C
/// worker. Without it the daemon keeps its historical local journal, so a
/// source build that does not compile the worker still tracks correctly.
///
/// When the worker is enabled, the fallback journal lives in a subdirectory:
/// the worker owns the canonical files, and two writers appending to the same
/// journal would interleave `seq` values. The fallback is only ever used when
/// the worker is unreachable, and the next successful write reconciles the
/// worker with the tracker's current state.
SessionMemoryBackend buildSessionMemoryBackend({
  required String runtimeDir,
  String? socketPath,
}) {
  final socket = socketPath ??
      Platform.environment['SCREENGUARD_SESSION_SOCKET'] ??
      '';
  if (socket.isEmpty) {
    return LocalSessionMemoryBackend(SessionJournal(directory: runtimeDir));
  }
  return FallbackSessionMemoryBackend(
    primary: SessionWorkerBackend(socketPath: socket),
    fallback: LocalSessionMemoryBackend(
      SessionJournal(directory: '$runtimeDir/session-fallback'),
    ),
  );
}
