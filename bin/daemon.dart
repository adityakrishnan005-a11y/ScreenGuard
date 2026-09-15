import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/tracker.dart';

void main() async {
  // Enforce single-instance lock to prevent duplicate daemons
  final home = Platform.environment['HOME'];
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final baseDir = xdg != null
      ? '$xdg/screenguard'
      : '${home ?? '/tmp'}/.local/share/screenguard';
  Directory(baseDir).createSync(recursive: true);

  final lockFile = File('$baseDir/daemon.lock');
  RandomAccessFile? lockRaf;
  try {
    lockRaf = lockFile.openSync(mode: FileMode.write);
    lockRaf.lockSync(FileLock.exclusive);
  } catch (_) {
    stderr.writeln('[screenguard-daemon] Another daemon instance is already running. Exiting.');
    exit(0);
  }

  final db = DatabaseService();
  final resolver = AppResolver();
  final tracker = Tracker(db: db, resolver: resolver);
  await tracker.run();
}
