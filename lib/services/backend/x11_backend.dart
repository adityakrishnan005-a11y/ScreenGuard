import 'dart:io';
import 'dart:async';
import 'package:screenguard/services/backend/window_backend.dart';

class X11Backend implements WindowBackend {
  Future<String> _run(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args)
          .timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return '';
      return (r.stdout as String).trim();
    } on ProcessException {
      return '';
    } on TimeoutException {
      return '';
    }
  }

  Future<bool> _runExitCode(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args).timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String? _parseWindowId(String out) {
    final m = RegExp(r'0x[0-9a-fA-F]+').firstMatch(out);
    return m?.group(0);
  }

  String? _parseClass(String out) {
    final m = RegExp(r'WM_CLASS\([^)]*\)\s*=\s*(.*?)(?=\n[A-Z_]|\Z)', dotAll: true).firstMatch(out);
    final target = m != null ? m.group(1)! : out;
    final matches = RegExp(r'"([^"]*)"').allMatches(target).toList();
    if (matches.isEmpty) return null;
    return matches.last.group(1)?.toLowerCase();
  }

  String? _parseTitle(String out) {
    final m = RegExp(r'_NET_WM_NAME\([^)]*\)\s*=\s*"([^"]*)"').firstMatch(out);
    return m?.group(1);
  }

  int? _parsePid(String out) {
    final m = RegExp(r'_NET_WM_PID\([^)]*\)\s*=\s*(\d+)').firstMatch(out);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  @override
  Future<WindowInfo> getActiveWindow() async {
    final root = await _run('xprop', ['-root', '_NET_ACTIVE_WINDOW']);
    final wid = _parseWindowId(root);
    if (wid == null) return WindowInfo.unknown;

    // INEFF-6 fix: query WM_CLASS, _NET_WM_NAME, and _NET_WM_PID in a single xprop invocation
    final props = await _run('xprop', ['-id', wid, 'WM_CLASS', '_NET_WM_NAME', '_NET_WM_PID']);
    final className = _parseClass(props);
    if (className == null || className.isEmpty) return WindowInfo.unknown;

    final titleClean = _parseTitle(props);
    final pid = _parsePid(props);

    return WindowInfo(
      app: className,
      rawClass: className,
      title: titleClean,
      pid: pid,
    );
  }

  @override
  Future<int> getIdleMs() async {
    final out = await _run('xprintidle', []);
    return int.tryParse(out) ?? 0;
  }

  @override
  Future<bool> minimizeActiveWindow() async {
    final wid = _parseWindowId(await _run('xprop', ['-root', '_NET_ACTIVE_WINDOW']));
    if (wid != null && wid.isNotEmpty) {
      return await _runExitCode('xdotool', ['windowminimize', wid]);
    }
    return false;
  }

  @override
  Future<bool> closeActiveWindow() async {
    final wid = _parseWindowId(await _run('xprop', ['-root', '_NET_ACTIVE_WINDOW']));
    if (wid != null && wid.isNotEmpty) {
      return await _runExitCode('xdotool', ['windowclose', wid]);
    }
    return false;
  }
}
