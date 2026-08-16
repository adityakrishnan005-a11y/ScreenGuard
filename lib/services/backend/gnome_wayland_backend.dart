import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:screenguard/services/backend/window_backend.dart';

class GnomeWaylandBackend implements WindowBackend {
  String _helperPath() {
    final candidates = <String>[];
    final env = Platform.environment['SCREENGUARD_HELPER'];
    if (env != null && env.isNotEmpty) candidates.add(env);
    try {
      final scriptDir = File(Platform.script.toFilePath()).parent.path;
      candidates.add('$scriptDir/active_window_helper.py');
      candidates.add('${Directory(scriptDir).parent.path}/bin/active_window_helper.py');
    } catch (_) {}
    try {
      final cwd = Directory.current.path;
      candidates.add('$cwd/bin/active_window_helper.py');
      candidates.add('$cwd/active_window_helper.py');
    } catch (_) {}
    candidates.addAll([
      '/usr/share/screenguard/active_window_helper.py',
      '/usr/lib/screenguard/active_window_helper.py',
    ]);
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return 'active_window_helper.py';
  }

  Future<String> _runHelper() async {
    Process p;
    try {
      p = await Process.start('python3', [_helperPath()]);
    } on ProcessException {
      return '';
    }
    try {
      final out = await p.stdout
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final exitCode = await p.exitCode.timeout(const Duration(seconds: 2));
      if (exitCode != 0) return '';
      return out.trim();
    } on TimeoutException {
      p.kill();
      return '';
    }
  }

  Future<WindowInfo?> _getFromExtension() async {
    try {
      final r = await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.gnome.Shell',
        '--object-path',
        '/org/gnome/Shell/Extensions/ScreenGuard',
        '--method',
        'org.gnome.Shell.Extensions.ScreenGuard.GetActiveWindow',
      ]).timeout(const Duration(seconds: 2));

      if (r.exitCode == 0) {
        final stdout = (r.stdout as String).trim();
        final match = RegExp(r"\('([^']*)',\s*'([^']*)',\s*(\d+)\)").firstMatch(stdout);
        if (match != null) {
          final app = match.group(1)!.trim().toLowerCase();
          final title = match.group(2)!.trim();
          final pid = int.tryParse(match.group(3)!);
          if (app.isNotEmpty && app != 'unknown') {
            return WindowInfo(
              app: app,
              rawClass: app,
              title: title.isEmpty ? null : title,
              pid: pid == 0 ? null : pid,
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  bool _extensionAttempted = false;

  Future<void> _ensureExtensionInstalledAndEnabled() async {
    if (_extensionAttempted) return;
    _extensionAttempted = true;
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;
      final targetDir = Directory('$home/.local/share/gnome-shell/extensions/screenguard@screenguard.app');
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
        final candidates = <String>[
          '/usr/share/gnome-shell/extensions/screenguard@screenguard.app',
          '${Directory.current.path}/extension',
          '/opt/screenguard/extension',
        ];
        try {
          final scriptDir = File(Platform.script.toFilePath()).parent.path;
          candidates.add('$scriptDir/extension');
          candidates.add('${Directory(scriptDir).parent.path}/extension');
        } catch (_) {}

        for (final c in candidates) {
          final d = Directory(c);
          if (d.existsSync()) {
            for (final entity in d.listSync()) {
              if (entity is File) {
                entity.copySync('${targetDir.path}/${entity.uri.pathSegments.last}');
              }
            }
            break;
          }
        }
      }
      await Process.run('gnome-extensions', ['enable', 'screenguard@screenguard.app']);
      await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.gnome.Shell',
        '--object-path',
        '/org/gnome/Shell',
        '--method',
        'org.gnome.Shell.Extensions.EnableExtension',
        'screenguard@screenguard.app',
      ]);
    } catch (_) {}
  }

  @override
  Future<WindowInfo> getActiveWindow() async {
    final extWindow = await _getFromExtension();
    if (extWindow != null) return extWindow;

    await _ensureExtensionInstalledAndEnabled();

    final out = await _runHelper();
    if (out.isEmpty) return WindowInfo.unknown;
    try {
      final json = jsonDecode(out) as Map<String, dynamic>;
      final app = (json['app'] as String? ?? 'unknown').toLowerCase();
      if (app == 'unknown') return WindowInfo.unknown;
      return WindowInfo(
        app: app,
        rawClass: app,
        title: json['title'] as String?,
        pid: json['pid'] as int?,
      );
    } catch (_) {
      return WindowInfo.unknown;
    }
  }

  @override
  Future<int> getIdleMs() async {
    try {
      final r = await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.gnome.Mutter.IdleMonitor',
        '--object-path',
        '/org/gnome/Mutter/IdleMonitor/Core',
        '--method',
        'org.gnome.Mutter.IdleMonitor.GetIdletime',
      ]).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return 0;
      final m = RegExp(r'uint64\s+(\d+)').firstMatch(r.stdout as String);
      return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    } on ProcessException {
      return 0;
    } on TimeoutException {
      return 0;
    }
  }

  @override
  Future<bool> minimizeActiveWindow() async {
    try {
      final r = await Process.run('gdbus', [
        'call',
        '--session',
        '--dest',
        'org.gnome.Shell',
        '--object-path',
        '/org/gnome/Shell/Extensions/ScreenGuard',
        '--method',
        'org.gnome.Shell.Extensions.ScreenGuard.MinimizeActiveWindow',
      ]).timeout(const Duration(seconds: 2));
      if (r.exitCode == 0 && r.stdout.toString().contains('true')) {
        return true;
      }
    } catch (_) {}
    return false;
  }
}
