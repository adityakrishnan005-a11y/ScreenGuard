import 'dart:async';
import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/tracker.dart';
import 'package:screenguard/services/crash_reporter.dart';
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
    db.init();  // Initialize once here; tracker.run() calls init() too — guard below

    final resolver = AppResolver();
    resolver.init();
    final tracker = Tracker(db: db, resolver: resolver);

    // Start periodic update checks (once per day, ~5 KB network)
    // db is already initialized above so settings can be read immediately.
    final updateChecker = UpdateChecker(db: db);
    updateChecker.startPeriodicChecks();

    // Heartbeat: write a timestamp every 5 minutes so the GUI can detect a dead daemon
    Timer.periodic(const Duration(minutes: 5), (_) {
      crashReporter.writeHeartbeat();
      crashReporter.maybeSendDailyActivePing();
    });
    crashReporter.writeHeartbeat(); // Write initial heartbeat immediately
    crashReporter.maybeSendDailyActivePing(); // Daily active user ping if not yet recorded today

    // Register clean shutdown handlers
    void onShutdown() {
      tracker.stop();
      crashReporter.markDaemonStopped();
      updateChecker.stopPeriodicChecks();
      try {
        _daemonLockFile?.unlockSync();
        _daemonLockFile?.closeSync();
      } catch (_) {}
      exit(0);
    }

    ProcessSignal.sigterm.watch().listen((_) => onShutdown());
    ProcessSignal.sigint.watch().listen((_) => onShutdown());


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
