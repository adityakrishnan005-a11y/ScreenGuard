import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DaemonService extends ChangeNotifier {
  bool _isRunning = false;
  bool _isAutostartEnabled = false;
  bool _isLoading = false;
  Timer? _pollTimer;

  bool get isRunning => _isRunning;
  bool get isAutostartEnabled => _isAutostartEnabled;
  bool get isLoading => _isLoading;

  DaemonService() {
    init();
  }

  void init() {
    checkStatus();
    checkAutostart();
    // Poll every 3 seconds to reflect background changes in real time
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      checkStatus();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  static String resolveDaemonPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling = File('${guiDir.path}${Platform.pathSeparator}screenguard-daemon');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/screenguard-daemon').existsSync()) {
      return '/usr/bin/screenguard-daemon';
    }
    return 'screenguard-daemon';
  }

  Future<bool> checkStatus() async {
    bool running = false;
    try {
      final res = await Process.run('systemctl', ['--user', 'is-active', 'screenguard.service'])
          .timeout(const Duration(seconds: 2));
      if (res.exitCode == 0 && res.stdout.toString().trim() == 'active') {
        running = true;
      }
    } catch (_) {}

    if (!running) {
      try {
        final pgrepRes = await Process.run('pgrep', ['-f', 'screenguard-daemon'])
            .timeout(const Duration(seconds: 2));
        if (pgrepRes.exitCode == 0 && pgrepRes.stdout.toString().trim().isNotEmpty) {
          running = true;
        }
      } catch (_) {}
    }

    if (_isRunning != running) {
      _isRunning = running;
      notifyListeners();
    }
    return _isRunning;
  }

  static String _xdgAutostartFile() {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/.config/autostart/screenguard-daemon.desktop';
  }

  static Future<bool> _hasSystemdUser() async {
    try {
      final res = await Process.run('systemctl', ['--user', 'show-environment'])
          .timeout(const Duration(seconds: 2));
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> checkAutostart() async {
    bool enabled = false;
    try {
      final res = await Process.run('systemctl', ['--user', 'is-enabled', 'screenguard.service'])
          .timeout(const Duration(seconds: 2));
      final out = res.stdout.toString().trim();
      if (out.contains('enabled')) {
        enabled = true;
      } else if (out.contains('disabled') || out.contains('masked')) {
        enabled = false;
      }
    } catch (_) {}

    // Fallback installs (no systemd user session) autostart via XDG entry.
    if (!enabled) {
      try {
        enabled = File(_xdgAutostartFile()).existsSync();
      } catch (_) {}
    }

    if (_isAutostartEnabled != enabled) {
      _isAutostartEnabled = enabled;
      notifyListeners();
    }
    return _isAutostartEnabled;
  }

  Future<void> startDaemon({bool enableAutostart = false}) async {
    _isLoading = true;
    notifyListeners();

    try {
      if (enableAutostart) {
        await Process.run('systemctl', ['--user', 'unmask', 'screenguard.service'])
            .timeout(const Duration(seconds: 2));
        await Process.run('systemctl', ['--user', 'enable', '--now', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
      } else {
        final res = await Process.run('systemctl', ['--user', 'start', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
        if (res.exitCode != 0) {
          // Fallback to detached process
          Process.start(resolveDaemonPath(), [], mode: ProcessStartMode.detached);
        }
      }
    } catch (_) {
      try {
        Process.start(resolveDaemonPath(), [], mode: ProcessStartMode.detached);
      } catch (_) {}
    }

    await Future.delayed(const Duration(milliseconds: 600));
    await checkStatus();
    await checkAutostart();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> stopDaemon() async {
    _isLoading = true;
    notifyListeners();

    try {
      await Process.run('systemctl', ['--user', 'stop', 'screenguard.service'])
          .timeout(const Duration(seconds: 4));
    } catch (_) {}

    try {
      await Process.run('pkill', ['-f', 'screenguard-daemon'])
          .timeout(const Duration(seconds: 2));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 600));
    await checkStatus();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> restartDaemon() async {
    _isLoading = true;
    notifyListeners();

    try {
      await Process.run('systemctl', ['--user', 'restart', 'screenguard.service'])
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      await stopDaemon();
      await startDaemon(enableAutostart: _isAutostartEnabled);
    }

    await Future.delayed(const Duration(milliseconds: 600));
    await checkStatus();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> setAutostart(bool enable) async {
    _isLoading = true;
    notifyListeners();

    try {
      if (enable) {
        await Process.run('systemctl', ['--user', 'unmask', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
        final enableRes = await Process.run('systemctl', ['--user', 'enable', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
        // No systemd user session (or unit missing): fall back to XDG entry,
        // mirroring install.sh, so the switch still does what it claims.
        if (enableRes.exitCode != 0 && !await _hasSystemdUser()) {
          final f = File(_xdgAutostartFile());
          f.parent.createSync(recursive: true);
          f.writeAsStringSync(
            '[Desktop Entry]\n'
            'Type=Application\n'
            'Name=ScreenGuard Daemon\n'
            'Comment=ScreenGuard background screen time tracker\n'
            'Exec=${resolveDaemonPath()}\n'
            'Terminal=false\n'
            'Hidden=false\n'
            'NoDisplay=true\n'
            'X-GNOME-Autostart-enabled=true\n',
          );
        }
      } else {
        await Process.run('systemctl', ['--user', 'disable', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
        await Process.run('systemctl', ['--user', 'mask', 'screenguard.service'])
            .timeout(const Duration(seconds: 4));
        // Also remove the XDG fallback entry, or the daemon keeps autostarting.
        try {
          final f = File(_xdgAutostartFile());
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 500));
    await checkAutostart();

    _isLoading = false;
    notifyListeners();
  }
}
