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
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      for (final f in d.listSync()) {
        if (f is! File || !f.path.endsWith('.desktop')) continue;
        _parseDesktop(f, addToCache: true);
      }
    } catch (_) {}
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
      try {
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
      } catch (_) {}
    }
    result.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
    return result;
  }

  AppMeta? _parseDesktop(File f, {required bool addToCache}) {
    String content;
    try {
      content = f.readAsStringSync();
    } catch (_) {
      return null;
    }
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

      final lower = line.toLowerCase();
      if (lower.startsWith('startupwmclass=')) {
        wmClass = line.substring(15).trim().toLowerCase();
      } else if (line.startsWith('Name=') && name == null) {
        name = line.substring(5).trim();
      } else if (line.startsWith('Icon=')) {
        icon = line.substring(5).trim();
      } else if (lower == 'nodisplay=true' || lower == 'hidden=true') {
        skip = true;
        break;
      } else if (lower.startsWith('type=') && lower != 'type=application') {
        skip = true;
        break;
      }
    }

    if (skip || name == null) return null;
    final meta = AppMeta(name, icon);
    if (addToCache) {
      if (wmClass != null && wmClass.isNotEmpty) {
        _cache[wmClass] = meta;
        _addAlias(wmClass, base);
      }
      _cache[base] = meta;
    }
    return meta;
  }

  final Map<String, Set<String>> _aliasMap = {};

  void _addAlias(String a, String b) {
    if (a.isEmpty || b.isEmpty || a == b) return;
    _aliasMap.putIfAbsent(a, () => {}).add(b);
    _aliasMap.putIfAbsent(b, () => {}).add(a);
  }

  List<String> getAliases(String app) {
    final key = app.toLowerCase();
    final result = <String>{key};
    if (_aliasMap.containsKey(key)) {
      result.addAll(_aliasMap[key]!);
    }
    const staticAliases = {
      'spotify': ['com.spotify.client', 'spotify-adblock'],
      'com.spotify.client': ['spotify', 'spotify-adblock'],
      'code': ['com.visualstudio.code'],
      'com.visualstudio.code': ['code'],
      'discord': ['com.discordapp.discord'],
      'com.discordapp.discord': ['discord'],
      'slack': ['com.slack.slack'],
      'com.slack.slack': ['slack'],
      'steam': ['com.valvesoftware.steam'],
      'com.valvesoftware.steam': ['steam'],
      'telegram': ['org.telegram.desktop'],
      'org.telegram.desktop': ['telegram'],
      'firefox': ['org.mozilla.firefox'],
      'org.mozilla.firefox': ['firefox'],
      'chromium': ['org.chromium.chromium', 'chromium-browser'],
      'chromium-browser': ['chromium', 'org.chromium.chromium'],
      'org.chromium.chromium': ['chromium', 'chromium-browser'],
      'signal': ['org.signal.signal'],
      'org.signal.signal': ['signal'],
    };
    if (staticAliases.containsKey(key)) {
      result.addAll(staticAliases[key]!);
    }
    return result.toList();
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

