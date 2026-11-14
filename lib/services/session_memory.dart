import 'dart:convert';
import 'dart:io';

/// The session-related state that must survive a daemon restart.
///
/// This is deliberately a *small* snapshot: it contains only what the tracker
/// needs to decide whether an open session can be resumed or must be closed at
/// its last observed tick. Policy state (limits, focus, milestones) belongs to
/// the policy service and is not duplicated here.
///
/// The file format is the contract that `digiwelld-session` will read when the
/// session worker moves to C. Keep the JSON keys stable.
class SessionMemory {
  static const int schemaVersion = 1;

  final int version;

  /// When this snapshot was written. Used to reject stale lock/suspend state.
  final int writtenAtMs;

  /// The open `sessions.id`, or null when no session is open.
  final int? currentSessionId;
  final String? currentApp;
  final String? currentTitle;
  final int? currentPid;
  final bool? currentIdle;
  final int? sessionStartedAtMs;

  /// Last time the tracker actually observed the session.
  final int? lastTickMs;
  final bool? lastIdleReported;

  final bool sessionLocked;
  final bool suspended;
  final int dayStartMs;
  final int consecutiveUnknownTicks;

  const SessionMemory({
    this.version = schemaVersion,
    required this.writtenAtMs,
    this.currentSessionId,
    this.currentApp,
    this.currentTitle,
    this.currentPid,
    this.currentIdle,
    this.sessionStartedAtMs,
    this.lastTickMs,
    this.lastIdleReported,
    this.sessionLocked = false,
    this.suspended = false,
    this.dayStartMs = 0,
    this.consecutiveUnknownTicks = 0,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'written_at_ms': writtenAtMs,
        'current_session_id': currentSessionId,
        'current_app': currentApp,
        'current_title': currentTitle,
        'current_pid': currentPid,
        'current_idle': currentIdle,
        'session_started_at_ms': sessionStartedAtMs,
        'last_tick_ms': lastTickMs,
        'last_idle_reported': lastIdleReported,
        'session_locked': sessionLocked,
        'suspended': suspended,
        'day_start_ms': dayStartMs,
        'consecutive_unknown_ticks': consecutiveUnknownTicks,
      };

  factory SessionMemory.fromJson(Map<String, Object?> json) {
    return SessionMemory(
      version: _int(json['version']) ?? schemaVersion,
      writtenAtMs: _int(json['written_at_ms']) ?? 0,
      currentSessionId: _int(json['current_session_id']),
      currentApp: _str(json['current_app']),
      currentTitle: _str(json['current_title']),
      currentPid: _int(json['current_pid']),
      currentIdle: _bool(json['current_idle']),
      sessionStartedAtMs: _int(json['session_started_at_ms']),
      lastTickMs: _int(json['last_tick_ms']),
      lastIdleReported: _bool(json['last_idle_reported']),
      sessionLocked: _bool(json['session_locked']) ?? false,
      suspended: _bool(json['suspended']) ?? false,
      dayStartMs: _int(json['day_start_ms']) ?? 0,
      consecutiveUnknownTicks: _int(json['consecutive_unknown_ticks']) ?? 0,
    );
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;
  static String? _str(Object? value) => value is String ? value : null;
  static bool? _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }
}

/// Append-only journal + compact snapshot for [SessionMemory].
///
/// Design:
///
///   * transitions are appended to `session-journal.jsonl`;
///   * a periodic checkpoint atomically rewrites `session-state.json` and
///     truncates the journal;
///   * every record carries a monotonic `seq`, so a crash between the snapshot
///     rename and the journal truncate cannot replay stale state;
///   * a partially written final line is ignored, not fatal.
///
/// The journal lives under `XDG_RUNTIME_DIR/screenguard`, next to the sockets:
/// it is per-login state, not long-term history. The database remains the
/// long-term record.
class SessionJournal {
  SessionJournal({
    required this.directory,
    this.compactAfter = 128,
  });

  final String directory;

  /// Compact after this many appended transitions.
  final int compactAfter;

  File get _snapshotFile => File('$directory/session-state.json');
  File get _journalFile => File('$directory/session-journal.jsonl');

  int _seq = 0;
  int _entries = 0;
  int _lastWrittenAtMs = 0;
  bool _enabled = true;
  final Set<String> _secured = <String>{};

  bool get enabled => _enabled;
  int get entries => _entries;
  int get lastSeq => _seq;

  Map<String, Object?> info() => <String, Object?>{
        'directory': directory,
        'snapshot_path': _snapshotFile.path,
        'journal_path': _journalFile.path,
        'journal_entries': _entries,
        'last_seq': _seq,
        'last_written_at_ms': _lastWrittenAtMs,
        'snapshot_bytes':
            _snapshotFile.existsSync() ? _snapshotFile.lengthSync() : 0,
        'journal_bytes':
            _journalFile.existsSync() ? _journalFile.lengthSync() : 0,
        'enabled': _enabled,
      };

  /// Load the latest state: snapshot first, then newer journal records.
  SessionMemory? load() {
    if (!_enabled) return null;
    try {
      _ensureDirectory();

      SessionMemory? state;
      int snapshotSeq = 0;
      final snapshot = _readEnvelope(_snapshotFile);
      if (snapshot != null) {
        snapshotSeq = _int(snapshot['seq']) ?? 0;
        final raw = snapshot['state'];
        if (raw is Map) {
          state = SessionMemory.fromJson(_stringMap(raw));
        }
      }

      _seq = snapshotSeq;
      _entries = 0;
      if (_journalFile.existsSync()) {
        for (final line in _journalFile.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          _entries++;
          final envelope = _decodeEnvelope(line);
          if (envelope == null) continue;
          final seq = _int(envelope['seq']) ?? 0;
          if (seq <= _seq) continue; // already covered by the snapshot
          final raw = envelope['state'];
          if (raw is! Map) continue;
          state = SessionMemory.fromJson(_stringMap(raw));
          _seq = seq;
        }
      }

      _lastWrittenAtMs = state?.writtenAtMs ?? 0;
      return state;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  /// Append one transition. Calls [checkpoint] once the journal is long
  /// enough to be worth compacting.
  void append(SessionMemory state) {
    if (!_enabled) return;
    try {
      _ensureDirectory();
      final seq = ++_seq;
      final line = jsonEncode(<String, Object?>{
        'v': SessionMemory.schemaVersion,
        'seq': seq,
        'state': state.toJson(),
      });
      final file = _journalFile;
      final existed = file.existsSync();
      final raf = file.openSync(mode: FileMode.append);
      try {
        raf.writeStringSync('$line\n');
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      if (!existed) _secure(file);
      _entries++;
      _lastWrittenAtMs = state.writtenAtMs;

      if (_entries >= compactAfter) {
        checkpoint(state);
      }
    } catch (e) {
      _fail(e);
    }
  }

  /// Write a compact snapshot and truncate the journal.
  ///
  /// The snapshot is written to a temporary file, flushed, and renamed, so a
  /// crash leaves either the old snapshot or the new one — never a half-written
  /// file. The journal is truncated only after the rename succeeds; if that
  /// truncate is interrupted, the `seq` check on load discards stale records.
  void checkpoint(SessionMemory state) {
    if (!_enabled) return;
    try {
      _ensureDirectory();
      final seq = ++_seq;
      final payload = jsonEncode(<String, Object?>{
        'v': SessionMemory.schemaVersion,
        'seq': seq,
        'state': state.toJson(),
      });

      final tmp = File('${_snapshotFile.path}.tmp');
      final raf = tmp.openSync(mode: FileMode.write);
      try {
        raf.writeStringSync(payload);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      _secure(tmp);
      tmp.renameSync(_snapshotFile.path);
      _secure(_snapshotFile);

      final journal = _journalFile;
      final existed = journal.existsSync();
      final truncate = journal.openSync(mode: FileMode.write);
      try {
        truncate.truncateSync(0);
        truncate.flushSync();
      } finally {
        truncate.closeSync();
      }
      if (!existed) _secure(journal);

      _entries = 0;
      _lastWrittenAtMs = state.writtenAtMs;
    } catch (e) {
      _fail(e);
    }
  }

  /// Compact whatever is currently on disk. Returns the state that was kept.
  SessionMemory? compact({SessionMemory? state}) {
    final latest = state ?? load();
    if (latest == null) {
      _truncateJournal();
      return null;
    }
    checkpoint(latest);
    return latest;
  }

  void clear() {
    try {
      if (_snapshotFile.existsSync()) _snapshotFile.deleteSync();
      if (_journalFile.existsSync()) _journalFile.deleteSync();
      final tmp = File('${_snapshotFile.path}.tmp');
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // Best effort: a leftover file is harmless.
    }
    _seq = 0;
    _entries = 0;
    _lastWrittenAtMs = 0;
  }

  void _truncateJournal() {
    try {
      if (_journalFile.existsSync()) {
        final raf = _journalFile.openSync(mode: FileMode.write);
        try {
          raf.truncateSync(0);
          raf.flushSync();
        } finally {
          raf.closeSync();
        }
      }
      _entries = 0;
    } catch (e) {
      _fail(e);
    }
  }

  void _ensureDirectory() {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    if (_secured.add(directory)) _chmod(directory, '700');
  }

  Map<String, Object?>? _readEnvelope(File file) {
    if (!file.existsSync()) return null;
    try {
      final text = file.readAsStringSync().trim();
      if (text.isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      return _stringMap(decoded);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? _decodeEnvelope(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      return _stringMap(decoded);
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?> _stringMap(Map<dynamic, dynamic> raw) =>
      raw.map((key, value) => MapEntry(key.toString(), value));

  static int? _int(Object? value) => value is num ? value.toInt() : null;

  static void _secure(File file) {
    _chmod(file.path, '600');
  }

  static void _chmod(String path, String mode) {
    try {
      Process.runSync('chmod', <String>[mode, path]);
    } catch (_) {
      // chmod is defence in depth; the 0700 runtime directory is the control.
    }
  }

  void _fail(Object error) {
    _enabled = false;
    stderr.writeln('[session-journal] disabled: $error');
  }
}
