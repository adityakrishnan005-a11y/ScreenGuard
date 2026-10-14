import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:screenguard/services/db.dart';

/// Lightweight auto-update checker for ScreenGuard.
///
/// - Checks GitHub Releases API for new versions (one GET per check, ~5 KB).
/// - Compares semantic versions, handles prerelease tags.
/// - Sends desktop notifications for available updates.
/// - Downloads release assets and triggers install.sh for self-update.
/// - All state persisted in SQLite via the existing settings table.
class UpdateChecker {
  static const String _repoOwner = 'adityakrishnan005-a11y';
  static const String _repoName = 'screenguard';
  static const String _apiBase = 'https://api.github.com/repos/$_repoOwner/$_repoName/releases';
  static const String _currentVersion = '0.1.1-beta.5';

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

  /// Download a release tarball and install it.
  /// Returns true on success.
  Future<bool> downloadAndInstall(String version) async {
    try {
      // Fetch the release to find the tarball asset
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final tagUrl = '$_apiBase/tags/v$version';
      final request = await client.getUrl(Uri.parse(tagUrl));
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'ScreenGuard/$_currentVersion');

      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        client.close(force: true);
        return false;
      }

      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);

      final release = jsonDecode(body) as Map<String, dynamic>;
      final assets = release['assets'] as List<dynamic>? ?? [];

      // Find the tarball asset
      String? tarballUrl;
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.contains('x86_64') && name.endsWith('.tar.gz')) {
          tarballUrl = asset['browser_download_url'] as String?;
          break;
        }
      }

      if (tarballUrl == null) return false;

      // Download to cache directory (avoids noexec on /tmp)
      final cacheBase = Platform.environment['XDG_CACHE_HOME'] ??
          (Platform.environment['HOME'] != null
              ? '${Platform.environment['HOME']}/.cache'
              : '/tmp');
      final tmpDir = Directory('$cacheBase/screenguard/update');
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      tmpDir.createSync(recursive: true);

      final tarPath = '${tmpDir.path}/screenguard-update.tar.gz';

      // Download using curl (more reliable than dart HttpClient for large files)
      final dlResult = await Process.run(
        'curl', ['-fSL', '-o', tarPath, tarballUrl],
      ).timeout(const Duration(minutes: 5));

      if (dlResult.exitCode != 0) return false;

      // Extract
      final extractResult = await Process.run(
        'tar', ['-xzf', tarPath, '-C', tmpDir.path],
      );
      if (extractResult.exitCode != 0) return false;

      // Find and run install.sh
      final installSh = File('${tmpDir.path}/install.sh');
      if (!installSh.existsSync()) return false;

      final installResult = await Process.run(
        'bash', [installSh.path, '--yes'],
      ).timeout(const Duration(minutes: 2));

      // Cleanup
      try { tmpDir.deleteSync(recursive: true); } catch (_) {}

      return installResult.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ── Notification ───────────────────────────────────────────────────────

  void _sendUpdateNotification(String version, bool isBeta) {
    try {
      final label = isBeta ? 'Beta Update' : 'Update Available';
      Process.run('notify-send', [
        'ScreenGuard — $label',
        'Version $version is available. Open Settings → Updates to install.',
        '-i', 'software-update-available',
        '-a', 'ScreenGuard',
        '-h', 'string:x-canonical-private-synchronous:screenguard-update',
        '-h', 'string:desktop-entry:screenguard',
      ]);
    } catch (_) {}
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
