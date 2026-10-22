import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:screenguard/services/app_version.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/notification_service.dart';

/// Lightweight auto-update checker for ScreenGuard.
///
/// - Checks GitHub Releases API for new versions (one GET per check, ~5 KB).
/// - Compares semantic versions, handles prerelease tags.
/// - Sends desktop notifications for available updates.
/// - Downloads release assets and triggers install.sh for self-update.
/// - All state persisted in SQLite via the existing settings table.
enum InstallKind {
  /// User-level tarball install (default install.sh target, ~/.local/...).
  userTarball,

  /// System-wide tarball install (--system, /usr/local/...).
  systemTarball,

  /// RPM package install (/opt/screenguard + /usr/bin, dnf/zypper).
  rpm,

  /// .deb package install (/opt/screenguard + /usr/bin, apt).
  deb,

  /// Unrecognized install location.
  unknown,
}

class UpdateChecker {
  static const String _repoOwner = 'adityakrishnan005-a11y';
  static const String _repoName = 'screenguard';
  static const String _apiBase = 'https://api.github.com/repos/$_repoOwner/$_repoName/releases';
  static const String _currentVersion = AppVersion.value;

  final DatabaseService db;
  Timer? _checkTimer;

  UpdateChecker({required this.db});

  // ── Settings keys ───────────────────────────────────────────────────────

  bool get checkUpdatesEnabled =>
      db.getSetting('update_check_enabled', defaultValue: '1') == '1';

  set checkUpdatesEnabled(bool val) =>
      db.setSetting('update_check_enabled', val ? '1' : '0');

  bool get includeBeta =>
      db.getSetting('update_include_beta', defaultValue: '0') == '1';

  set includeBeta(bool val) =>
      db.setSetting('update_include_beta', val ? '1' : '0');

  String get checkFrequency =>
      db.getSetting('update_check_frequency', defaultValue: 'daily');

  set checkFrequency(String val) =>
      db.setSetting('update_check_frequency', val);

  String get lastCheckTime =>
      db.getSetting('update_last_check_time', defaultValue: '');

  set lastCheckTime(String val) =>
      db.setSetting('update_last_check_time', val);

  String get lastKnownVersion =>
      db.getSetting('update_last_known_version', defaultValue: '');

  set lastKnownVersion(String val) =>
      db.setSetting('update_last_known_version', val);

  String get lastKnownVersionUrl =>
      db.getSetting('update_last_known_url', defaultValue: '');

  set lastKnownVersionUrl(String val) =>
      db.setSetting('update_last_known_url', val);

  String get dismissedVersion =>
      db.getSetting('update_dismissed_version', defaultValue: '');

  set dismissedVersion(String val) =>
      db.setSetting('update_dismissed_version', val);

  String get lastChangelog =>
      db.getSetting('update_last_changelog', defaultValue: '');

  set lastChangelog(String val) =>
      db.setSetting('update_last_changelog', val);

  bool get isPrerelease =>
      db.getSetting('update_last_is_prerelease', defaultValue: '0') == '1';

  set isPrerelease(bool val) =>
      db.setSetting('update_last_is_prerelease', val ? '1' : '0');

  /// The current app version.
  String get currentVersion => _currentVersion;

  /// Startup notice for the "Updated ✓" banner. Returns the version we just
  /// updated to when the persisted last-seen version precedes the running
  /// one — i.e. the binary was replaced outside this process (in-app update,
  /// rpm/deb install, manual reinstall). Re-arms the check so the next
  /// update announces again; null when unchanged, downgraded, or on any
  /// storage failure (the banner must never disturb startup).
  static String? updateNoticeOnStartup(DatabaseService db) {
    try {
      final known = db.getSetting('app_last_seen_version', defaultValue: '');
      db.setSetting('app_last_seen_version', _currentVersion);
      if (known.isNotEmpty && compareVersions(_currentVersion, known) > 0) {
        return _currentVersion;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whether an update is available (and not dismissed).
  bool get hasUpdate {
    final known = lastKnownVersion;
    if (known.isEmpty) return false;
    if (known == dismissedVersion) return false;
    return compareVersions(known, _currentVersion) > 0;
  }

  // ── Periodic checking ──────────────────────────────────────────────────

  /// Start the periodic check timer.  Call from the daemon's main loop.
  void startPeriodicChecks() {
    if (!checkUpdatesEnabled) return;

    // Check on startup if enough time has passed
    _checkIfDue();

    // Then set a timer to check periodically
    final interval = checkFrequency == 'weekly'
        ? const Duration(hours: 24)  // check daily; _checkIfDue gates the actual API call
        : const Duration(hours: 12);

    _checkTimer = Timer.periodic(interval, (_) => _checkIfDue());
  }

  /// Stop periodic checks.
  void stopPeriodicChecks() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  void _checkIfDue() {
    if (!checkUpdatesEnabled) return;

    final last = lastCheckTime;
    if (last.isNotEmpty) {
      final lastTime = DateTime.tryParse(last);
      if (lastTime != null) {
        final freq = checkFrequency;
        final threshold = freq == 'weekly'
            ? const Duration(days: 7)
            : const Duration(days: 1);
        if (DateTime.now().difference(lastTime) < threshold) return;
      }
    }

    // Fire and forget — don't block the daemon
    checkForUpdates();
  }

  // ── Core check logic ──────────────────────────────────────────────────

  /// Check GitHub Releases API for a newer version.
  /// Returns the version string if an update is found, or null.
  Future<String?> checkForUpdates() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.getUrl(Uri.parse(_apiBase));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'ScreenGuard/$_currentVersion');

      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        client.close(force: true);
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      final releases = jsonDecode(body) as List<dynamic>;
      if (releases.isEmpty) return null;

      lastCheckTime = DateTime.now().toIso8601String();

      // Find the best candidate release
      String? bestVersion;
      String? bestUrl;
      String? bestChangelog;
      bool bestIsPrerelease = false;

      for (final release in releases) {
        final tagName = (release['tag_name'] as String? ?? '').replaceFirst('v', '');
        final prerelease = release['prerelease'] as bool? ?? false;
        final draft = release['draft'] as bool? ?? false;
        final htmlUrl = release['html_url'] as String? ?? '';
        final body = release['body'] as String? ?? '';

        if (draft) continue;
        if (prerelease && !includeBeta) continue;

        // Is this newer than current?
        if (compareVersions(tagName, _currentVersion) > 0) {
          // Is this the best we've found so far?
          if (bestVersion == null || compareVersions(tagName, bestVersion) > 0) {
            bestVersion = tagName;
            bestUrl = htmlUrl;
            bestChangelog = body.length > 500 ? '${body.substring(0, 500)}...' : body;
            bestIsPrerelease = prerelease;
          }
        }
      }

      if (bestVersion != null) {
        lastKnownVersion = bestVersion;
        lastKnownVersionUrl = bestUrl ?? '';
        lastChangelog = bestChangelog ?? '';
        isPrerelease = bestIsPrerelease;

        // Send notification if this is a new discovery (not already dismissed)
        if (bestVersion != dismissedVersion) {
          _sendUpdateNotification(bestVersion, bestIsPrerelease);
        }

        return bestVersion;
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// Download a release asset for the detected install kind and install it.
  ///
  /// Medium-aware, so every install type updates correctly:
  /// - RPM / .deb (the RPM and .deb share the `/opt/screenguard` layout —
  ///   asked dpkg first, then rpm): download the matching package asset,
  ///   then install through `pkexec` (polkit password dialog — works on
  ///   GNOME without a terminal). If pkexec is refused or fails, the
  ///   returned `note` carries the copyable manual command.
  /// - User tarball (`~/.local/...`): self-update, extract + install.sh.
  /// - System tarball (`/usr/local/...`): extract, then `pkexec` runs
  ///   install.sh --system.
  ///
  /// Returns (success, note); on failure `note` holds a manual command the
  /// user can run instead (empty note = generic failure, no command known).
  Future<({bool success, String note})> downloadAndInstall(
      String version) async {
    Directory? tmpDir;
    try {
      // Fetch the release to find the right asset.
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final tagUrl = '$_apiBase/tags/v$version';
      final request = await client.getUrl(Uri.parse(tagUrl));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'ScreenGuard/$_currentVersion');

      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        client.close(force: true);
        return (success: false, note: '');
      }
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      final release = jsonDecode(body) as Map<String, dynamic>;
      final assets = release['assets'] as List<dynamic>? ?? [];

      final kind = await detectInstall();

      // Pick the asset that matches the install medium.
      final bool Function(String name) matcher;
      switch (kind) {
        case InstallKind.deb:
          matcher = (name) => name.endsWith('_amd64.deb');
        case InstallKind.rpm:
          matcher = (name) => name.endsWith('.x86_64.rpm') && !name.contains('.src.');
        case InstallKind.systemTarball:
        case InstallKind.userTarball:
        case InstallKind.unknown:
          matcher = (name) => name.contains('x86_64') && name.endsWith('.tar.gz');
      }
      String? assetUrl;
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (matcher(name)) {
          assetUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      if (assetUrl == null) return (success: false, note: '');

      // Download to cache directory (avoids noexec on /tmp).
      final cacheBase = Platform.environment['XDG_CACHE_HOME'] ??
          (Platform.environment['HOME'] != null
              ? '${Platform.environment['HOME']}/.cache'
              : '/tmp');
      tmpDir = Directory('$cacheBase/screenguard/update');
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      tmpDir.createSync(recursive: true);

      final fileName = assetUrl.split('/').last;
      if (!await _downloadTo(assetUrl, '$tmpDir/$fileName')) {
        return (success: false, note: 'Could not download the update.');
      }

      // ── Package installs: elevate via pkexec ────────────────────────────
      if (kind == InstallKind.rpm || kind == InstallKind.deb) {
        final pkgPath = '${tmpDir.path}/$fileName';
        List<String> args;
        String manual;
        if (kind == InstallKind.rpm) {
          final tool = await _firstOnPath(['dnf', 'zypper']) ?? 'dnf';
          args = tool == 'dnf'
              ? ['dnf', 'install', '-y', pkgPath]
              : ['zypper', '--non-interactive', 'install', '-y', pkgPath];
          manual = 'sudo $tool install -y $assetUrl';
        } else {
          final tool = await _firstOnPath(['apt-get', 'apt']) ?? 'apt';
          args = [tool, 'install', '-y', pkgPath];
          manual = 'Download the .deb from $assetUrl, then:\n'
              'sudo $tool install -y ./path/to/$fileName';
        }
        var ok = false;
        try {
          final r = await Process.run('pkexec', args)
              .timeout(const Duration(minutes: 10));
          ok = r.exitCode == 0;
        } catch (_) {}
        if (ok) {
          return (success: true, note: 'Installed via $args[0] —');
        }
        return (success: false, note: manual);
      }

      // ── Tarball installs: extract + install.sh ─────────────────────────
      final extractResult = await Process.run(
        'tar', ['-xzf', '$tmpDir/$fileName', '-C', tmpDir.path],
      );
      if (extractResult.exitCode != 0) {
        return (success: false, note: 'Could not extract the update.');
      }
      final installSh = File('${tmpDir.path}/install.sh');
      if (!installSh.existsSync()) return (success: false, note: '');

      final elevated = kind == InstallKind.systemTarball;
      final runArgs = elevated
          ? ['pkexec', 'bash', installSh.path, '--system', '--yes']
          : ['bash', installSh.path, '--yes'];
      final installResult = await Process.run(runArgs.first, runArgs.sublist(1))
          .timeout(const Duration(minutes: 5));

      final ok = installResult.exitCode == 0;
      return (
        success: ok,
        note: ok
            ? ''
            : elevated
                ? 'sudo bash install.sh --system --yes from the updated tarball'
                : ''
      );
    } catch (_) {
      return (success: false, note: '');
    } finally {
      if (tmpDir != null) {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Downloads [url] into [destPath]. Pure-Dart first (no external tools —
  /// minimal Debian and similar installs ship no `curl`/`wget`, and the old
  /// updater hard-failed the whole update on that), then curl, then wget.
  static Future<bool> _downloadTo(String url, String destPath) async {
    // 1) Pure Dart stream. Follows redirects; keeps everything in-process
    //    so there is no tool dependency and no missing-password/no-tty
    //    surface.
    var dartOk = false;
    final client = HttpClient();
    try {
      client.userAgent = 'ScreenGuard/$_currentVersion';
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(minutes: 10));
      if (res.statusCode == 200) {
        final sink = File(destPath).openWrite();
        try {
          await for (final chunk in res) {
            sink.add(chunk);
          }
          await sink.flush();
          dartOk = true;
        } finally {
          await sink.close();
        }
      }
    } catch (_) {
      dartOk = false;
    } finally {
      client.close(force: true);
    }
    if (dartOk && File(destPath).lengthSync() > 1024) return true;

    // 2) & 3) Tool fallbacks (in case dart's stack is blocked by a proxy).
    for (final tool in [
      ['curl', '-fsSL', '-o'],
      ['wget', '-q', '-O'],
    ]) {
      try {
        final r = await Process.run(tool[0], [...tool.skip(1), destPath, url])
            .timeout(const Duration(minutes: 10));
        if (r.exitCode == 0 && File(destPath).lengthSync() > 1024) return true;
      } catch (_) {}
    }

    // Leave no partial file behind for postinstall/all later phases.
    try {
      final f = File(destPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    return false;
  }

  // ── Install environment detection ───────────────────────────────────────

  /// How would [exePath] (default: the running executable) have been
  /// installed? No cache — this only runs when the user chooses to install
  /// an update, so a short package-manager probe is free.
  static Future<InstallKind> detectInstall({String? exePath}) =>
      _detectInstallUncached(exePath: exePath);

  static Future<InstallKind> _detectInstallUncached({String? exePath}) async {
    try {
      final exe = exePath ?? Platform.resolvedExecutable;
      final real = await File(exe).resolveSymbolicLinks();
      // The RPM and .deb share the /opt layout.
      if (real.startsWith('/opt/screenguard')) {
        try {
          final dpkg = await Process.run('dpkg-query', ['-s', 'screenguard'])
              .timeout(const Duration(seconds: 3));
          if (dpkg.exitCode == 0) return InstallKind.deb;
        } catch (_) {}
        try {
          final rpm = await Process.run('rpm', ['-q', 'screenguard'])
              .timeout(const Duration(seconds: 3));
          if (rpm.exitCode == 0) return InstallKind.rpm;
        } catch (_) {}
        return InstallKind.rpm;
      }
      if (real.startsWith('/usr/local/')) return InstallKind.systemTarball;
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty && real.startsWith('$home/')) {
        return InstallKind.userTarball;
      }
      return InstallKind.unknown;
    } catch (_) {
      return InstallKind.unknown;
    }
  }

  static Future<String?> _firstOnPath(List<String> names) async {
    for (final n in names) {
      try {
        final r =
            await Process.run('which', [n]).timeout(const Duration(seconds: 3));
        if (r.exitCode == 0) return n;
      } catch (_) {}
    }
    return null;
  }

  // ── Notification ───────────────────────────────────────────────────────

  void _sendUpdateNotification(String version, bool isBeta) {
    final label = isBeta ? 'Beta Update' : 'Update Available';
    NotificationService.show(
      db: db,
      eventKey: 'update',
      title: 'ScreenGuard — $label',
      body: 'Version $version is available. Open Settings → Updates to install.',
      icon: 'software-update-available',
    );
  }

  // ── Semantic version comparison ────────────────────────────────────────

  /// Compare two semver strings.  Returns:
  ///   >0 if a > b, <0 if a < b, 0 if equal.
  ///
  /// Handles prerelease tags:  1.0.0-beta.4 < 1.0.0 < 1.0.1
  /// Prerelease comparison:    1.0.0-beta.3 < 1.0.0-beta.4
  static int compareVersions(String a, String b) {
    final aParsed = _parseVersion(a);
    final bParsed = _parseVersion(b);

    // Compare major.minor.patch
    for (int i = 0; i < 3; i++) {
      final diff = aParsed.numbers[i] - bParsed.numbers[i];
      if (diff != 0) return diff;
    }

    // Both have no prerelease = equal
    if (aParsed.prerelease.isEmpty && bParsed.prerelease.isEmpty) return 0;

    // Release (no prerelease) > prerelease
    if (aParsed.prerelease.isEmpty) return 1;   // a is release, b is prerelease
    if (bParsed.prerelease.isEmpty) return -1;  // a is prerelease, b is release

    // Both have prerelease — compare alphabetically then numerically
    final aParts = aParsed.prerelease.split('.');
    final bParts = bParsed.prerelease.split('.');

    for (int i = 0; i < aParts.length && i < bParts.length; i++) {
      final aNum = int.tryParse(aParts[i]);
      final bNum = int.tryParse(bParts[i]);

      if (aNum != null && bNum != null) {
        if (aNum != bNum) return aNum - bNum;
      } else {
        final cmp = aParts[i].compareTo(bParts[i]);
        if (cmp != 0) return cmp;
      }
    }

    return aParts.length - bParts.length;
  }

  static _SemVer _parseVersion(String v) {
    // Remove leading 'v'
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);

    // Split on '-' to separate version from prerelease
    String versionPart;
    String prerelease = '';
    final dashIndex = v.indexOf('-');
    if (dashIndex >= 0) {
      versionPart = v.substring(0, dashIndex);
      prerelease = v.substring(dashIndex + 1);
    } else {
      // Handle tilde (Debian-style) as prerelease separator
      final tildeIndex = v.indexOf('~');
      if (tildeIndex >= 0) {
        versionPart = v.substring(0, tildeIndex);
        prerelease = v.substring(tildeIndex + 1);
      } else {
        versionPart = v;
      }
    }

    final parts = versionPart.split('.');
    final numbers = <int>[
      parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0,
      parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
      parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0,
    ];

    return _SemVer(numbers, prerelease);
  }
}

class _SemVer {
  final List<int> numbers;  // [major, minor, patch]
  final String prerelease;  // e.g. 'beta.4' or ''

  _SemVer(this.numbers, this.prerelease);
}
