import 'dart:io';

import 'package:screenguard/services/backend/window_backend.dart';

/// Ordered close escalation shared by the daemon (strict mode) and the
/// warning screens' Close buttons.
///
/// The heavy lifting lives in the native `screenguard-killer` helper
/// (`src/killer.c`, libc only): direct kill(2), /proc tree scan, zombie
/// detection, Proton-native `wineserver -k`, guarded pattern-kill. This class
/// keeps only the polite window-close stage (needs the Shell/backend) and
/// delegates the rest to the helper by exit code (0 = target gone).
///
/// [politeClose]: when true (daemon/strict path) stage 1 asks the focused
/// window to close first. Warning screens must pass false: at that moment
/// the *focused* window is the popup itself, so WM_DELETE would close
/// ScreenGuard instead of the offending game.
class AppKiller {
  static String? _cachedKillerBin;

  static String? _findKillerBinary() {
    if (_cachedKillerBin != null && File(_cachedKillerBin!).existsSync()) {
      return _cachedKillerBin;
    }
    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      // Adjacent to currently running executable
      '${File(Platform.resolvedExecutable).parent.path}/screenguard-killer',
      // User-local installation (install.sh default)
      '$home/.local/opt/screenguard/screenguard-killer',
      '$home/.local/bin/screenguard-killer',
      // System installation
      '/opt/screenguard/screenguard-killer',
      '/usr/local/bin/screenguard-killer',
      '/usr/bin/screenguard-killer',
      // Repository bundle dev build
      'build/linux/x64/release/bundle/screenguard-killer',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        _cachedKillerBin = path;
        return path;
      }
    }
    return null;
  }

  static Future<bool> close({
    String? app,
    int? pid,
    WindowBackend? backend,
    bool politeClose = true,
  }) async {
    // Stage 1: polite window close (needs the compositor/backend — stays here).
    if (politeClose) {
      try {
        if (backend != null) {
          await backend.closeActiveWindow().timeout(const Duration(seconds: 2));
        } else {
          final r = await Process.run('gdbus', [
            'call', '--session',
            '--dest', 'org.gnome.Shell',
            '--object-path', '/org/gnome/Shell/Extensions/ScreenGuard',
            '--method',
                'org.gnome.Shell.Extensions.ScreenGuard.CloseActiveWindow',
          ]).timeout(const Duration(seconds: 2));
          if (r.exitCode == 0 && r.stdout.toString().contains('true')) {
            await Future.delayed(const Duration(seconds: 2));
            if (pid != null && pid > 1000 && !await _alive(pid)) return true;
          }
        }
      } catch (_) {}
    }

    // Stages 2+: native helper (TERM → tree KILL → wineserver -k → patterns).
    final bin = _findKillerBinary();
    if (bin == null) return _degradedClose(pid);
    try {
      final args = <String>[];
      if (pid != null && pid > 0) args.addAll(['--pid', '$pid']);
      if (app != null && app.isNotEmpty) args.addAll(['--app', app]);
      final r = await Process.run(bin, args)
          .timeout(const Duration(seconds: 30));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _alive(int pid) async {
    try {
      final r = await Process.run('kill', ['-0', '$pid'])
          .timeout(const Duration(seconds: 2));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Degraded fallback when the native helper is missing (e.g. running from
  /// source before a full build): bare TERM → KILL on the PID only. Honest
  /// false when there is nothing verifiable to kill.
  static Future<bool> _degradedClose(int? pid) async {
    if (pid == null || pid <= 1000) return false;
    try {
      await Process.run('kill', ['-TERM', '$pid']);
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 2));
    if (!await _alive(pid)) return true;
    try {
      await Process.run('kill', ['-KILL', '$pid']);
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    return !(await _alive(pid));
  }
}
