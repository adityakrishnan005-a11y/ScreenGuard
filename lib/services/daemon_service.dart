import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DaemonService extends ChangeNotifier {
  static const _supervisorUnit = 'digiwelld.service';
  static const _fallbackUnit = 'screenguard.service';

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

  /// The supervisor that owns the socket and restarts the daemon. Null on
  /// installs that predate digiwelld (or when only the bare daemon exists).
  static String? resolveSupervisorPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling = File('${guiDir.path}${Platform.pathSeparator}digiwelld');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/digiwelld').existsSync()) return '/usr/bin/digiwelld';
    return null;
  }

  static String? resolveSessionWorkerPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling =
          File('${guiDir.path}${Platform.pathSeparator}digiwelld-session');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/digiwelld-session').existsSync()) {
      return '/usr/bin/digiwelld-session';
    }
    return null;
  }

  /// Read-only usage worker. When present, digiwelld routes the `usage`
  /// domain to it instead of the daemon.
  static String? resolveUsageWorkerPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling =
          File('${guiDir.path}${Platform.pathSeparator}digiwelld-usage');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/digiwelld-usage').existsSync()) {
      return '/usr/bin/digiwelld-usage';
    }
    return null;
  }

  /// Policy worker. When present, digiwelld routes the `policy` domain to it
  /// and it becomes the only process that advances the focus state machine.
  static String? resolvePolicyWorkerPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling =
          File('${guiDir.path}${Platform.pathSeparator}digiwelld-policy');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/digiwelld-policy').existsSync()) {
      return '/usr/bin/digiwelld-policy';
    }
    return null;
  }

  /// Store worker. When present, digiwelld routes the `storage` domain to it
  /// and it becomes the single SQLite writer for sessions and events.
  static String? resolveStoreWorkerPath() {
    try {
      final guiDir = File(Platform.resolvedExecutable).parent;
      final sibling =
          File('${guiDir.path}${Platform.pathSeparator}digiwelld-store');
      if (sibling.existsSync()) return sibling.path;
    } catch (_) {}
    if (File('/usr/bin/digiwelld-store').existsSync()) {
      return '/usr/bin/digiwelld-store';
    }
    return null;
  }

  /// Starting the supervisor (not the daemon directly) keeps auth, routing
  /// and the crash budget in place on installs without a systemd user session.
  static Future<void> _startDetached() async {
    final daemon = resolveDaemonPath();
    final supervisor = resolveSupervisorPath();
    if (supervisor == null) {
      await Process.start(daemon, [], mode: ProcessStartMode.detached);
      return;
    }
    final worker = resolveSessionWorkerPath();
    final usage = resolveUsageWorkerPath();
    final policy = resolvePolicyWorkerPath();
    final store = resolveStoreWorkerPath();
    await Process.start(
      supervisor,
      [
        '--daemon', daemon,
        if (worker != null) ...['--session-worker', worker],
        if (usage != null) ...['--usage-worker', usage],
        if (policy != null) ...['--policy-worker', policy],
        if (store != null) ...['--store-worker', store],
      ],
      mode: ProcessStartMode.detached,
    );
  }

  static String _autostartExec() {
    final daemon = resolveDaemonPath();
    final supervisor = resolveSupervisorPath();
    if (supervisor == null) return daemon;
    final worker = resolveSessionWorkerPath();
    final usage = resolveUsageWorkerPath();
    final policy = resolvePolicyWorkerPath();
    final store = resolveStoreWorkerPath();
    return [
      supervisor,
      '--daemon', daemon,
      if (worker != null) ...['--session-worker', worker],
      if (usage != null) ...['--usage-worker', usage],
      if (policy != null) ...['--policy-worker', policy],
      if (store != null) ...['--store-worker', store],
    ].join(' ');
  }

  Future<bool> checkStatus() async {
    bool running = false;
    for (final unit in const [_supervisorUnit, _fallbackUnit]) {
      try {
        final res = await Process.run('systemctl', ['--user', 'is-active', unit])
            .timeout(const Duration(seconds: 2));
        if (res.exitCode == 0 && res.stdout.toString().trim() == 'active') {
          running = true;
          break;
        }
      } catch (_) {}
    }

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
    for (final unit in const [_supervisorUnit, _fallbackUnit]) {
      try {
        final res = await Process.run('systemctl', ['--user', 'is-enabled', unit])
            .timeout(const Duration(seconds: 2));
        final out = res.stdout.toString().trim();
        if (out.contains('enabled')) {
          enabled = true;
          break;
        }
      } catch (_) {}
    }

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
      var started = false;
      for (final unit in const [_supervisorUnit, _fallbackUnit]) {
        if (enableAutostart) {
          await Process.run('systemctl', ['--user', 'unmask', unit])
              .timeout(const Duration(seconds: 2));
          final res = await Process.run(
                  'systemctl', ['--user', 'enable', '--now', unit])
              .timeout(const Duration(seconds: 4));
          if (res.exitCode == 0) {
            started = true;
            break;
          }
        } else {
          final res = await Process.run(
                  'systemctl', ['--user', 'start', unit])
              .timeout(const Duration(seconds: 4));
          if (res.exitCode == 0) {
            started = true;
            break;
          }
        }
      }
      if (!started) {
        // No usable unit (e.g. XDG-only install): start the supervisor so
        // the daemon still gets auth, routing and crash supervision.
        await _startDetached();
      }
    } catch (_) {
      try {
        await _startDetached();
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

    for (final unit in const [_supervisorUnit, _fallbackUnit]) {
      try {
        await Process.run('systemctl', ['--user', 'stop', unit])
            .timeout(const Duration(seconds: 4));
      } catch (_) {}
    }

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

    var restarted = false;
    for (final unit in const [_supervisorUnit, _fallbackUnit]) {
      try {
        final res = await Process.run(
                'systemctl', ['--user', 'restart', unit])
            .timeout(const Duration(seconds: 4));
        if (res.exitCode == 0) {
          restarted = true;
          break;
        }
      } catch (_) {}
    }
    if (!restarted) {
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
        var enabled = false;
        for (final unit in const [_supervisorUnit, _fallbackUnit]) {
          await Process.run('systemctl', ['--user', 'unmask', unit])
              .timeout(const Duration(seconds: 4));
          final enableRes = await Process.run(
                  'systemctl', ['--user', 'enable', unit])
              .timeout(const Duration(seconds: 4));
          if (enableRes.exitCode == 0) {
            enabled = true;
            break;
          }
        }
        // No systemd user session (or unit missing): fall back to the XDG
        // entry, mirroring install.sh, so the switch still does what it says.
        if (!enabled && !await _hasSystemdUser()) {
          final f = File(_xdgAutostartFile());
          f.parent.createSync(recursive: true);
          f.writeAsStringSync(
            '[Desktop Entry]\n'
            'Type=Application\n'
            'Name=ScreenGuard Daemon\n'
            'Comment=ScreenGuard background screen time tracker\n'
            'Exec=${_autostartExec()}\n'
            'Terminal=false\n'
            'Hidden=false\n'
            'NoDisplay=true\n'
            'X-GNOME-Autostart-enabled=true\n',
          );
        }
      } else {
        for (final unit in const [_supervisorUnit, _fallbackUnit]) {
          await Process.run('systemctl', ['--user', 'disable', unit])
              .timeout(const Duration(seconds: 4));
          // Mask only units that actually exist: masking an absent unit
          // would create a /dev/null shadow that blocks a future install.
          try {
            final cat = await Process.run(
                    'systemctl', ['--user', 'cat', unit])
                .timeout(const Duration(seconds: 2));
            if (cat.exitCode == 0) {
              await Process.run('systemctl', ['--user', 'mask', unit])
                  .timeout(const Duration(seconds: 4));
            }
          } catch (_) {}
        }
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
