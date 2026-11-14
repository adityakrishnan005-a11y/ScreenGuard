import 'dart:async';
import 'dart:io';
import 'package:screenguard/api/daemon_server.dart';
import 'package:screenguard/api/screenguard_api.dart';
import 'package:screenguard/api/transport.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/session_backend.dart';
import 'package:screenguard/services/store_backend.dart';
import 'package:screenguard/services/tracker.dart';
import 'package:screenguard/services/crash_reporter.dart';
import 'package:screenguard/services/feedback_service.dart';
import 'package:screenguard/services/update_checker.dart';

// Top-level reference prevents Garbage Collection from releasing the OS file lock
RandomAccessFile? _daemonLockFile;

void main() async {
  final crashReporter = CrashReporter();

  // Check for unclean shutdown from previous run
  if (crashReporter.wasLastShutdownUnclean()) {
    crashReporter.recordUncleanShutdown();
  }
  crashReporter.markDaemonStarted();

  // Wrap everything in a Zone to catch unhandled errors
  runZonedGuarded(() async {
    // Enforce single-instance lock to prevent duplicate daemons
    final home = Platform.environment['HOME'];
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final baseDir = xdg != null
        ? '$xdg/screenguard'
        : '${home ?? '/tmp'}/.local/share/screenguard';
    Directory(baseDir).createSync(recursive: true);

    final lockFile = File('$baseDir/daemon.lock');
    try {
      _daemonLockFile = lockFile.openSync(mode: FileMode.write);
      _daemonLockFile!.lockSync(FileLock.exclusive);
      _daemonLockFile!.writeStringSync('$pid\n');
      _daemonLockFile!.flushSync();
    } catch (_) {
      stderr.writeln('[screenguard-daemon] Another daemon instance is already running. Exiting.');
      crashReporter.markDaemonStopped();
      exit(0);
    }

    final db = DatabaseService();
    // digiwelld sets this when it supervises digiwelld-store. The store owns
    // every session/event write from that point; this process keeps its
    // connection for reads. Without it (older install, direct run) DatabaseService
    // writes locally exactly as before.
    final storeSocket = Platform.environment['SCREENGUARD_STORE_SOCKET'];
    if (storeSocket != null && storeSocket.isNotEmpty) {
      db.writeSink = StoreWriteSink(BrokerTransport(socketPath: storeSocket));
      stderr.writeln('[screenguard-daemon] storage writer: digiwelld-store');
    }
    db.init();  // Initialize once here; tracker.run() calls init() too — guard below
    // Start of a daemon lifetime is a real transition: pair it with
    // daemon.stop so a crash can be told apart from a clean restart.
    db.recordEvent(DatabaseService.evDaemonStart);

    final resolver = AppResolver();
    resolver.init();
    // The broker sets SCREENGUARD_SESSION_SOCKET when it supervises the C
    // session worker. Without it the tracker uses the local Dart journal, so
    // an older install keeps working unchanged.
    final sessionMemory =
        buildSessionMemoryBackend(runtimeDir: runtimeDirectory());
    stderr.writeln(
        '[screenguard-daemon] session backend: ${sessionMemory.name}');
    final tracker = Tracker(
      db: db,
      resolver: resolver,
      sessionMemory: sessionMemory,
    );

    // The broker's backend. The broker owns the world-facing socket, the uid
    // check, the routing table and the storage lock; this server only answers
    // on the private path inside the runtime directory.
    final api = ScreenGuardApi.forDaemon(db: db, tracker: tracker);
    final server = DaemonServer(dispatch: api.dispatch!);

    // Start periodic update checks (once per day, ~5 KB network)
    // db is already initialized above so settings can be read immediately.
    final updateChecker = UpdateChecker(policy: api.policy);
    updateChecker.startPeriodicChecks();

    // Look for a feedback request from the maintainer (once per day).
    // Read-only fetch of a static JSON file — no user data is sent.
    final feedbackService = FeedbackService(policy: api.policy);
    feedbackService.startPeriodicChecks();

    // Heartbeat: write a timestamp every 5 minutes so the GUI can detect a dead daemon
    Timer.periodic(const Duration(minutes: 5), (_) {
      crashReporter.writeHeartbeat();
      crashReporter.maybeSendDailyActivePing();
    });
    crashReporter.writeHeartbeat(); // Write initial heartbeat immediately
    crashReporter.maybeSendDailyActivePing(); // Daily active user ping if not yet recorded today

    // Register clean shutdown handlers
    void onShutdown() {
      unawaited(server.stop());
      tracker.stop();
      db.recordEvent(DatabaseService.evDaemonStop);
      crashReporter.markDaemonStopped();
      updateChecker.stopPeriodicChecks();
      feedbackService.stopPeriodicChecks();
      try {
        _daemonLockFile?.unlockSync();
        _daemonLockFile?.closeSync();
      } catch (_) {}
      exit(0);
    }

    ProcessSignal.sigterm.watch().listen((_) => onShutdown());
    ProcessSignal.sigint.watch().listen((_) => onShutdown());
    // SIGHUP: session logout kills detached (non-systemd) daemons via hangup.
    // Without this, every logout looks like a crash.
    try {
      ProcessSignal.sighup.watch().listen((_) => onShutdown());
    } catch (_) {}


    try {
      await server.start();
    } catch (e) {
      // Tracking must keep working even if the control socket cannot be
      // created (read-only runtime dir, socket owned by a dead pid, ...).
      stderr.writeln('[screenguard-daemon] control socket unavailable: $e');
    }

    await tracker.run();
  }, (error, stackTrace) {
    // Zone error handler — catches unhandled Dart exceptions
    stderr.writeln('[screenguard-daemon] FATAL: $error');
    stderr.writeln(stackTrace);

    crashReporter.recordCrash(
      source: 'daemon',
      error: error.toString(),
      stackTrace: stackTrace.toString(),
    );

    // Don't mark as cleanly stopped — the watchdog will detect the crash
    // and restart us. Exit with non-zero so the watchdog knows it's a crash.
    exit(1);
  });
}
