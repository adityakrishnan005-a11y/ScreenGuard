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
      final content = f.readAsStringSync();
      String? wmClass, name, icon;
      final base = f.uri.pathSegments.last.replaceAll('.desktop', '').toLowerCase();
      for (final line in content.split('\n')) {
        if (line.startsWith('StartupWMClass=')) {
          wmClass = line.substring(15).trim().toLowerCase();
        } else if (line.startsWith('Name=')) {
          name = line.substring(5).trim();
        } else if (line.startsWith('Icon=')) {
          icon = line.substring(5).trim();
        }
      }
      if (name != null) {
        if (wmClass != null && wmClass.isNotEmpty) {
          _cache[wmClass] = AppMeta(name, icon);
        }
        _cache[base] = AppMeta(name, icon);
      }
    }
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
