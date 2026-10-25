import 'dart:io';

import 'package:screenguard/services/app_resolver.dart';

/// Resolves a `.desktop` `Icon=` spec (or bare app id) to an image file
/// following the active icon theme, so every app can show its themed icon.
///
/// Search order per name (first hit wins):
///   1. Absolute `Icon=` path (app-bundled icons).
///   2. Raster formats (PNG/JPG/…) across all theme dirs + pixmaps.
///   3. SVG anywhere (many themes, e.g. Colloid, ship SVG only),
///      rendered via `flutter_svg`.
///
/// Both freedesktop layouts are covered (`<theme>/<size>/apps` and the
/// inverted `<theme>/apps/<size>` some themes use), custom themes are picked
/// up by enumerating icon roots, and monochrome `symbolic` variants are
/// skipped. Results (including misses) are cached. Callers show the letter
/// avatar when this returns null.
class AppIconService {
  static const _rasterExts = ['.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp'];
  static const _svgExt = '.svg';

  static AppResolver? _resolver;
  static final Map<String, String?> _pathCache = {};
  static List<String>? _dirs;

  static bool isSvg(String path) => path.toLowerCase().endsWith(_svgExt);

  /// Returns an absolute image path for [app] (lowercase id), or null.
  static String? resolve(String app) {
    if (_pathCache.containsKey(app)) return _pathCache[app];
    String? path;
    try {
      _resolver ??= AppResolver()..init();
      final spec = _resolver!.resolve(app).icon;
      if (spec != null && spec.isNotEmpty) {
        path = findIconFile(spec);
      }
      // Fallback: a theme icon matching the app id itself (covers entries
      // whose .desktop file lacks Icon=, e.g. resolver overrides)…
      path ??= findIconFile(app);
      // …plus names the app is known by (spotify ↔ com.spotify.client, …).
      if (path == null) {
        for (final alias in _resolver!.getAliases(app)) {
          if (alias == app) continue;
          path = findIconFile(alias);
          if (path != null) break;
        }
      }
    } catch (_) {
      path = null;
    }
    _pathCache[app] = path;
    return path;
  }

  static String? findIconFile(String spec) {
    return _findWithExts(spec, _rasterExts) ?? _findWithExts(spec, [_svgExt]);
  }

  static String? _findWithExts(String spec, List<String> exts) {
    if (spec.startsWith('/')) {
      final lower = spec.toLowerCase();
      if (exts.any(lower.endsWith) && _exists(spec)) return spec;
      final stem = _stripImageExt(spec);
      if (stem != spec) {
        for (final ext in exts) {
          final sibling = stem + ext;
          if (_exists(sibling)) return sibling;
        }
      }
      return null;
    }
    // NOTE: only a real image extension is stripped here. Icon names are
    // often reverse-DNS (org.gnome.Ptyxis, ai.opencode.desktop) where the
    // trailing dot-part is part of the NAME, not an extension.
    var base = _stripImageExt(spec.split('/').last);
    if (base.isEmpty || base.endsWith('-symbolic')) return null;
    for (final dir in _searchDirs()) {
      for (final ext in exts) {
        final p = '$dir/$base$ext';
        if (_exists(p)) return p;
      }
    }
    return null;
  }

  static bool _exists(String p) {
    try {
      return File(p).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Strips a trailing image extension (`.png`, `.svg`, …) if present,
  /// otherwise returns the name untouched.
  static String _stripImageExt(String name) {
    final lower = name.toLowerCase();
    const all = [
      '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp', '.svg',
      '.xpm', '.ico',
    ];
    for (final ext in all) {
      if (lower.endsWith(ext) && name.length > ext.length) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return name;
  }

  static List<String> _searchDirs() {
    if (_dirs != null) return _dirs!;
    final home = Platform.environment['HOME'] ?? '';
    const sizes = [
      '16x16', '22x22', '24x24', '32x32', '48x48', '64x64',
      '128x128', '256x256', 'scalable',
      // Bare sizes used by some themes (e.g. Colloid) for fixed icons.
      '16', '22', '24', '32', '48',
    ];
    const knownThemes = ['hicolor', 'Adwaita', 'gnome', 'breeze', 'Papirus', 'Yaru'];
    final roots = [
      if (home.isNotEmpty) '$home/.local/share/icons',
      if (home.isNotEmpty) '$home/.icons',
      '/usr/share/icons',
    ];
    final candidates = <String>[
      // Portable app-owned fallbacks (no theme involved).
      if (home.isNotEmpty) '$home/.local/share/pixmaps',
      '/usr/share/pixmaps',
    ];
    final themes = <String>{...knownThemes};
    // Custom themes (Colloid, …): any subdir of an icon root.
    for (final root in roots) {
      try {
        final d = Directory(root);
        if (!d.existsSync()) continue;
        var count = 0;
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory && count < 16) {
            themes.add(
                e.uri.pathSegments.where((s) => s.isNotEmpty).last);
            count++;
          }
        }
      } catch (_) {}
    }
    for (final root in roots) {
      for (final theme in themes) {
        for (final size in sizes) {
          // Standard: <theme>/<size>/apps — plus Colloid-style inversion.
          candidates.add('$root/$theme/$size/apps');
          candidates.add('$root/$theme/apps/$size');
        }
      }
    }
    _dirs = candidates.where((d) {
      try {
        return Directory(d).existsSync();
      } catch (_) {
        return false;
      }
    }).toList();
    return _dirs!;
  }
}
