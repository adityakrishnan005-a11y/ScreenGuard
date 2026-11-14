import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:screenguard/services/backend/window_backend.dart';
import 'package:screenguard/services/backend/x11_backend.dart';

/// Cinnamon (muffin) backend.
///
/// Cinnamon exposes its window list through muffin's debug D-Bus interface
/// (`org.cinnamon.Muffin.Debug.ListWindows`). Asking muffin is the only
/// reliable way to learn which window is *focused* there: reading the X
/// server's `_NET_ACTIVE_WINDOW` can return a hidden override-redirect actor
/// or a stale window instead of the one the user is looking at.
///
/// Only focus detection differs from X11. Idle time and the action verbs
/// (minimize / close / switch away) are ordinary X11 operations, so this class
/// extends [X11Backend] and overrides exactly one method.
class CinnamonBackend extends X11Backend {
  CinnamonBackend({this.helperPath});

  /// Override for tests and unusual installs.
  final String? helperPath;

  static const _timeout = Duration(seconds: 2);

  String? _resolveHelper() {
    if (helperPath != null && helperPath!.isNotEmpty) return helperPath;

    final candidates = <String>[];
    final env = Platform.environment['SCREENGUARD_CINNAMON_HELPER'];
    if (env != null && env.isNotEmpty) candidates.add(env);

    final home = Platform.environment['HOME'] ?? '';
    try {
      candidates.add('${File(Platform.resolvedExecutable).parent.path}/cinnamon_focus');
    } catch (_) {}
    candidates.addAll([
      // Release bundle / user-local install (install.sh default).
      '$home/.local/opt/screenguard/cinnamon_focus',
      '$home/.local/bin/cinnamon_focus',
      // Distro package.
      '/usr/lib/screenguard/cinnamon_focus',
      '/usr/libexec/screenguard/cinnamon_focus',
      '/opt/screenguard/cinnamon_focus',
      '/usr/local/bin/cinnamon_focus',
      '/usr/bin/cinnamon_focus',
    ]);

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  @override
  Future<WindowInfo> getActiveWindow() async {
    final helper = _resolveHelper();
    // No helper (or muffin's debug interface disabled): the X11 path is still
    // a reasonable fallback, so tracking does not stop.
    if (helper == null) return super.getActiveWindow();

    try {
      final r = await Process.run(helper, const []).timeout(_timeout);
      if (r.exitCode != 0) return await super.getActiveWindow();

      final text = (r.stdout as String).trim();
      if (text.isEmpty) return WindowInfo.unknown;

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        return await super.getActiveWindow();
      }

      final app = (decoded['app'] as String?)?.trim().toLowerCase() ?? '';
      if (app.isEmpty) return WindowInfo.unknown;

      final title = (decoded['title'] as String?)?.trim();
      final pid = (decoded['pid'] as num?)?.toInt();

      return WindowInfo(
        app: app,
        rawClass: app,
        title: title == null || title.isEmpty ? null : title,
        pid: pid == 0 ? null : pid,
      );
    } on TimeoutException {
      return super.getActiveWindow();
    } on ProcessException {
      return super.getActiveWindow();
    } on FormatException {
      // A malformed helper line should not take tracking down with it.
      return super.getActiveWindow();
    }
  }
}
