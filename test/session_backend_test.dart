import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/session_backend.dart';
import 'package:screenguard/services/session_memory.dart';

/// Integration coverage for the Dart side of the `digiwelld-session` wire
/// contract. The worker is compiled from `src/session.c` so this test cannot
/// drift from the C implementation it talks to.
void main() {
  final compiler = _findCompiler();

  late Directory tmp;
  late String runtimeDir;
  late String socketPath;
  late String binary;
  late Process worker;

  SessionMemory mem({
    int? id,
    String? app,
    String? title,
    int? startedAt,
    int? tick,
    int dayStart = 0,
    bool locked = false,
    bool suspended = false,
    int unknownTicks = 0,
  }) {
    return SessionMemory(
      writtenAtMs: tick ?? DateTime.now().millisecondsSinceEpoch,
      currentSessionId: id,
      currentApp: id == null ? null : (app ?? 'firefox'),
      currentTitle: id == null ? null : title,
      currentPid: id == null ? null : 4242,
      currentIdle: id == null ? null : false,
      sessionStartedAtMs: id == null ? null : startedAt,
      lastTickMs: tick,
      lastIdleReported: id == null ? null : false,
      sessionLocked: locked,
      suspended: suspended,
      dayStartMs: dayStart,
      consecutiveUnknownTicks: unknownTicks,
    );
  }

  Map<String, Object?> workerState(SessionWorkerBackend b) {
    final info = b.info();
    final status = (info['worker'] as Map).cast<String, Object?>();
    return (status['state'] as Map).cast<String, Object?>();
  }

  Future<void> startWorker() async {
    worker = await Process.start(binary, ['--runtime', runtimeDir]);
    // Keep the pipes drained; the worker only logs with --verbose, but a full
    // pipe must never be able to wedge the child.
    worker.stdout.drain<void>();
    worker.stderr.drain<void>();
  }

  group('SessionWorkerBackend', skip: compiler == null ? 'no C compiler' : null, () {
    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('sg_session_backend');
      runtimeDir = tmp.path;
      socketPath = '${tmp.path}/session.sock';
      binary = '${tmp.path}/digiwelld-session';
      final build = Process.runSync(compiler!, [
        '-O2',
        '-Wall',
        '-Wextra',
        '-std=c99',
        '-o',
        binary,
        '${Directory.current.path}/src/session.c',
      ]);
      expect(build.exitCode, 0,
          reason: 'cc failed:\n${build.stdout}\n${build.stderr}');
      await startWorker();
    });

    tearDownAll(() {
      worker.kill(ProcessSignal.sigterm);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a fresh worker reports no session', () {
      final backend = SessionWorkerBackend(
        socketPath: socketPath,
        startupGrace: const Duration(seconds: 5),
      );
      final state = backend.load();
      expect(state, isNotNull);
      expect(state!.currentSessionId, isNull);
      expect(backend.recovery!.restored, isFalse);
    });

    test('append begins, refreshes and closes a session', () {
      final backend = SessionWorkerBackend(
        socketPath: socketPath,
        startupGrace: const Duration(seconds: 5),
      );
      backend.load();
      final t0 = DateTime.now().millisecondsSinceEpoch - 5000;

      backend.append(mem(
        id: 41,
        app: 'firefox',
        title: 'One',
        startedAt: t0,
        tick: t0,
        unknownTicks: 2,
      ));
      var state = workerState(backend);
      expect(state['current_session_id'], 41);
      expect(state['current_app'], 'firefox');
      expect(state['current_title'], 'One');
      expect(state['session_started_at_ms'], t0);
      expect(state['last_tick_ms'], t0);

      final later = t0 + 1500;
      backend.append(mem(
        id: 41,
        app: 'firefox',
        title: 'Two',
        startedAt: t0,
        tick: later,
        unknownTicks: 2,
      ));
      state = workerState(backend);
      expect(state['current_title'], 'Two');
      expect(state['session_started_at_ms'], t0,
          reason: 'an idempotent begin must not move the start time');
      expect(state['last_tick_ms'], later);

      backend.checkpoint(mem(
        id: 41,
        app: 'firefox',
        title: 'Two',
        startedAt: t0,
        tick: later,
        unknownTicks: 2,
      ));
      expect((backend.info()['journal_entries'] as num).toInt(), 0);

      final closedAt = later + 700;
      backend.append(mem(tick: closedAt, unknownTicks: 2));
      state = workerState(backend);
      expect(state['current_session_id'], isNull);
      expect(state['last_tick_ms'], closedAt);
    });

    test('live flags are kept while the worker runs', () {
      final backend = SessionWorkerBackend(
        socketPath: socketPath,
        startupGrace: const Duration(seconds: 5),
      );
      backend.load();
      backend.append(mem(
        tick: DateTime.now().millisecondsSinceEpoch,
        locked: true,
        suspended: true,
        dayStart: 1234,
        unknownTicks: 4,
      ));
      var state = workerState(backend);
      expect(state['session_locked'], isTrue);
      expect(state['suspended'], isTrue);
      expect(state['day_start_ms'], 1234);
      expect(state['consecutive_unknown_ticks'], 4);

      backend.append(mem(
        tick: DateTime.now().millisecondsSinceEpoch,
        locked: false,
        suspended: false,
        dayStart: 1234,
        unknownTicks: 0,
      ));
      state = workerState(backend);
      expect(state['session_locked'], isFalse);
      expect(state['suspended'], isFalse);
    });

    test('a restarted worker reports a quick-resume decision', () async {
      final backend = SessionWorkerBackend(
        socketPath: socketPath,
        startupGrace: const Duration(seconds: 5),
      );
      backend.load();
      final t0 = DateTime.now().millisecondsSinceEpoch - 3000;
      backend.append(mem(id: 77, app: 'editor', startedAt: t0, tick: t0));
      backend.checkpoint(mem(id: 77, app: 'editor', startedAt: t0, tick: t0));

      worker.kill(ProcessSignal.sigkill);
      await worker.exitCode;
      await startWorker();

      final fresh = SessionWorkerBackend(
        socketPath: socketPath,
        startupGrace: const Duration(seconds: 5),
      );
      final state = fresh.load();
      expect(fresh.recovery!.resumedSessionId, 77);
      expect(state!.currentSessionId, 77);
      expect(state.currentApp, 'editor');
      expect(state.lastTickMs, t0);

      fresh.append(mem(tick: t0 + 1000));
      expect(workerState(fresh)['current_session_id'], isNull);
    });

    test('fallback journal takes over when the worker is unreachable', () {
      final dir = Directory.systemTemp.createTempSync('sg_session_fallback');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final local = LocalSessionMemoryBackend(
        SessionJournal(directory: dir.path),
      );
      final backend = FallbackSessionMemoryBackend(
        primary: SessionWorkerBackend(
          socketPath: '${dir.path}/missing.sock',
          startupGrace: Duration.zero,
        ),
        fallback: local,
      );

      expect(backend.load(), isNull);
      final now = DateTime.now().millisecondsSinceEpoch;
      backend.append(mem(id: 5, app: 'terminal', startedAt: now, tick: now));
      expect(backend.usingFallback, isTrue);
      expect(local.load()!.currentSessionId, 5);
    });
  });
}

String? _findCompiler() {
  for (final candidate in const ['cc', 'gcc']) {
    try {
      final r = Process.runSync('which', [candidate]);
      if (r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty) {
        return candidate;
      }
    } catch (_) {}
  }
  return null;
}
