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

  String? _parseWindowId(String out) {
    final m = RegExp(r'0x[0-9a-fA-F]+').firstMatch(out);
    return m?.group(0);
  }

  String? _parseClass(String out) {
    final matches = RegExp(r'"([^"]*)"').allMatches(out).toList();
    if (matches.isEmpty) return null;
    return matches.last.group(1)?.toLowerCase();
  }

  String? _parseTitle(String out) {
    final m = RegExp(r'"([^"]*)"').firstMatch(out);
    return m?.group(1);
  }

  int? _parsePid(String out) {
    final m = RegExp(r'= (\d+)').firstMatch(out);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  @override
  Future<WindowInfo> getActiveWindow() async {
    final root = await _run('xprop', ['-root', '_NET_ACTIVE_WINDOW']);
    final wid = _parseWindowId(root);
    if (wid == null) return WindowInfo.unknown;

    final raw = await _run('xprop', ['-id', wid, 'WM_CLASS']);
    final className = _parseClass(raw);
    if (className == null || className.isEmpty) return WindowInfo.unknown;

    final title = await _run('xprop', ['-id', wid, '_NET_WM_NAME']);
    final titleClean = _parseTitle(title);
    final pidStr = await _run('xprop', ['-id', wid, '_NET_WM_PID']);
    final pid = _parsePid(pidStr);

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
      final res = await _run('xdotool', ['windowminimize', wid]);
      return res.isNotEmpty || true;
    }
    return false;
  }
}
