import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Watches the session's power/lock state through systemd-logind.
///
/// The tracker polls the focused window every few seconds, but two things are
/// invisible to that poll:
///
///   * the screen locking (the lock screen may report an app id, not `unknown`)
///   * suspend/resume (`PrepareForSleep`), where wall-clock time jumps
///
/// Both matter for honest totals: time while locked or suspended is not use.
/// logind publishes them as D-Bus signals, so this class subscribes with a
/// long-lived `gdbus monitor` child and reports the transitions. If logind or
/// `gdbus` is unavailable, it stays quiet and tracking continues unchanged.
/// A session transition published by logind.
enum SessionSignal { lock, unlock, suspend, resume }

class SessionMonitor {
  SessionMonitor({
    required this.onLock,
    required this.onUnlock,
    required this.onSuspend,
    required this.onResume,
  });

  final void Function() onLock;
  final void Function() onUnlock;
  final void Function() onSuspend;
  final void Function() onResume;

  Process? _proc;
  StreamSubscription<String>? _out;
  Timer? _restart;
  bool _stopped = false;

  Future<void> start() async {
    _stopped = false;
    await _spawn();
  }

  Future<void> _spawn() async {
    if (_stopped) return;
    try {
      final proc = await Process.start('gdbus', const [
        'monitor',
        '--system',
        '--dest',
        'org.freedesktop.login1',
        '--object-path',
        '/org/freedesktop/login1',
      ]);
      _proc = proc;
      _out = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onDone: _scheduleRestart, onError: (_) {});
      // stderr carries "name is not owned" and similar; drop it.
      proc.stderr.drain<void>().catchError((Object _) {});
      unawaited(proc.exitCode.then((_) => _scheduleRestart()));
    } catch (_) {
      // No system bus / no gdbus: keep running without lock awareness.
      _scheduleRestart(short: false);
    }
  }

  void _handleLine(String line) {
    switch (parseSignal(line)) {
      case SessionSignal.lock:
        onLock();
        break;
      case SessionSignal.unlock:
        onUnlock();
        break;
      case SessionSignal.suspend:
        onSuspend();
        break;
      case SessionSignal.resume:
        onResume();
        break;
      case null:
        break;
    }
  }

  /// Classify one line of `gdbus monitor` output:
  ///
  ///   /org/freedesktop/login1: org.freedesktop.login1.Manager.Lock ()
  ///   /org/freedesktop/login1: org.freedesktop.login1.Manager.Unlock ()
  ///   /org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true)
  ///
  /// The boolean argument of `PrepareForSleep` is "entering sleep": true means
  /// suspend, false means resume.
  static SessionSignal? parseSignal(String line) {
    if (line.contains('Manager.Lock (')) return SessionSignal.lock;
    if (line.contains('Manager.Unlock (')) return SessionSignal.unlock;
    if (line.contains('Manager.PrepareForSleep (')) {
      if (line.contains('(true)')) return SessionSignal.suspend;
      if (line.contains('(false)')) return SessionSignal.resume;
    }
    return null;
  }

  void _scheduleRestart({bool short = true}) {
    if (_stopped) return;
    _restart?.cancel();
    _restart = Timer(Duration(seconds: short ? 10 : 60), _spawn);
  }

  void stop() {
    _stopped = true;
    _restart?.cancel();
    _restart = null;
    _out?.cancel();
    _out = null;
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }
}
