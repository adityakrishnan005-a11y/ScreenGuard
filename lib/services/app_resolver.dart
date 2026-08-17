import 'dart:io';

class AppMeta {
  final String name;
  final String? icon;
  const AppMeta(this.name, this.icon);
}

class AppResolver {
  final Map<String, AppMeta> _cache = {};
  final Map<String, AppMeta> _overrides = const {
    'code': AppMeta('VS Code', null),
    'code-insiders': AppMeta('VS Code Insiders', null),
    'slack': AppMeta('Slack', null),
    'discord': AppMeta('Discord', null),
    'steam': AppMeta('Steam', null),
    'telegram': AppMeta('Telegram', null),
    'spotify': AppMeta('Spotify', null),
    'com.spotify.client': AppMeta('Spotify', null),
    'signal': AppMeta('Signal', null),
    'delta': AppMeta('Delta Chat', null),
    'planify': AppMeta('Planify', null),
    'missioncenter': AppMeta('Mission Center', null),
    'extensionmanager': AppMeta('Extension Manager', null),
    'apostrophe': AppMeta('Apostrophe', null),
  };

  void init() {
    scanDir('/usr/share/applications');
    final home = Platform.environment['HOME'];
    if (home != null) {
      scanDir('$home/.local/share/applications');
      // Flatpak app .desktop files live in the exports hierarchy, not the
      // standard application dirs. Without scanning these, sandboxed apps
      // resolve to ugly reverse-domain ids (e.g. com.spotify.Client).
      scanDir('$home/.local/share/flatpak/exports/share/applications');
    }
    scanDir('/var/lib/flatpak/exports/share/applications');
  }

  void scanDir(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return;
    for (final f in d.listSync()) {
      if (f is! File || !f.path.endsWith('.desktop')) continue;
      _parseDesktop(f, addToCache: true);
    }
  }

  /// Returns all user-visible installed applications from .desktop dirs.
  /// Each entry has keys: 'app' (lowercase desktop id), 'name', 'icon'.
  List<Map<String, String>> listAllApps() {
    final dirs = [
      '/usr/share/applications',
      '${Platform.environment['HOME'] ?? ''}/.local/share/applications',
      '${Platform.environment['HOME'] ?? ''}/.local/share/flatpak/exports/share/applications',
      '/var/lib/flatpak/exports/share/applications',
    ];
    final seen = <String>{};
    final result = <Map<String, String>>[];
    for (final dirPath in dirs) {
      final d = Directory(dirPath);
      if (!d.existsSync()) continue;
      for (final f in d.listSync()) {
        if (f is! File || !f.path.endsWith('.desktop')) continue;
        final base = f.uri.pathSegments.last.replaceAll('.desktop', '').toLowerCase();
        if (seen.contains(base)) continue;
        final entry = _parseDesktop(f, addToCache: false);
        if (entry == null) continue;
        seen.add(base);
        result.add({'app': base, 'name': entry.name, 'icon': entry.icon ?? ''});
      }
    }
    result.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
    return result;
  }

  AppMeta? _parseDesktop(File f, {required bool addToCache}) {
    final content = f.readAsStringSync();
    String? wmClass, name, icon;
    final base = f.uri.pathSegments.last.replaceAll('.desktop', '').toLowerCase();
    bool inMainSection = false;
    bool skip = false;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('[')) {
        if (line == '[Desktop Entry]') {
          inMainSection = true;
        } else {
          // Once we leave [Desktop Entry] (e.g. entering [Desktop Action ...]), stop parsing.
          inMainSection = false;
        }
        continue;
      }

      if (!inMainSection) continue;

      if (line.startsWith('StartupWMClass=')) {
        wmClass = line.substring(15).trim().toLowerCase();
      } else if (line.startsWith('Name=') && name == null) {
        name = line.substring(5).trim();
      } else if (line.startsWith('Icon=')) {
        icon = line.substring(5).trim();
      } else if (line == 'NoDisplay=true' || line == 'Hidden=true') {
        skip = true;
        break;
      } else if (line.startsWith('Type=') && line != 'Type=Application') {
        skip = true;
        break;
      }
    }

    if (skip || name == null) return null;
    final meta = AppMeta(name, icon);
    if (addToCache) {
      if (wmClass != null && wmClass.isNotEmpty) {
        _cache[wmClass] = meta;
      }
      _cache[base] = meta;
    }
    return meta;
  }

  AppMeta resolve(String rawClass) {
    final key = rawClass.toLowerCase();
    if (_overrides.containsKey(key)) return _overrides[key]!;
    if (_cache.containsKey(key)) return _cache[key]!;
    final parts = key.split('.');
    String pick = parts.last;
    // Reverse-domain ids like com.spotify.Client have a generic trailing
    // segment; fall back to the previous segment in that case.
    const generic = {'client', 'desktop', 'app', 'main', 'window', 'gui'};
    if (parts.length >= 3 && generic.contains(pick)) {
      pick = parts[parts.length - 2];
    }
    final name = pick.isEmpty ? key : pick[0].toUpperCase() + pick.substring(1);
    return AppMeta(name, null);
  }
}
