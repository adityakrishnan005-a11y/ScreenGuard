import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/tracker.dart';

// Top-level reference prevents Garbage Collection from releasing the OS file lock
RandomAccessFile? _daemonLockFile;

void main() async {
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
    exit(0);
  }

  final db = DatabaseService();
  final resolver = AppResolver();
  final tracker = Tracker(db: db, resolver: resolver);
  await tracker.run();
}
