import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Lightweight crash/error reporter and telemetry service for ScreenGuard.
///
/// - Writes structured JSON crash logs locally (~1-5 KB each) for user inspection.
/// - Reads and manages stored crash logs.
/// - Connects to Sentry for automatic crash analysis and active user counting (opt-in).
/// - Completely zero-dependency (pure dart:io + dart:convert).
/// - Anonymous: Uses a random local UUID (no IP, username, or screen time data transmitted).
class CrashReporter {
  static const int maxCrashLogs = 20;
  static const String _crashDir = 'crashes';
  static const String _repoUrl = 'https://github.com/adityakrishnan005-a11y/screenguard';

  // Sentry Configuration
  static const String _sentryKey = '4898f3d5a159e8a898b548c1ad262ca6';
  static const String _sentryHost = 'o4512252813115392.ingest.de.sentry.io';
  static const String _sentryProjectId = '4512252819996752';
  static const String _sentryEndpoint =
      'https://$_sentryHost/api/$_sentryProjectId/store/';

  final String _dataDir;

  CrashReporter({String? dataDir}) : _dataDir = dataDir ?? _resolveDataDir();

  static String _resolveDataDir() {
    final home = Platform.environment['HOME'];
    final xdg = Platform.environment['XDG_DATA_HOME'];
    final base = xdg != null
        ? '$xdg/screenguard'
        : '${home ?? '/tmp'}/.local/share/screenguard';
    return base;
  }

  Directory get _crashDirectory {
    final dir = Directory('$_dataDir/$_crashDir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  File get _telemetryConfigFile => File('$_dataDir/telemetry.json');

  // ── Telemetry & Opt-in Config ─────────────────────────────────────────────

  Map<String, dynamic> _readTelemetryConfig() {
    try {
      if (_telemetryConfigFile.existsSync()) {
        final content = _telemetryConfigFile.readAsStringSync();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  void _writeTelemetryConfig(Map<String, dynamic> config) {
    try {
      _telemetryConfigFile.writeAsStringSync(jsonEncode(config));
    } catch (_) {}
  }

  /// Whether automatic crash and issue reporting is enabled.
  /// Default: true (opt-in / opt-out enabled by default for beta feedback).
  bool isReportingEnabled() {
    final config = _readTelemetryConfig();
    return (config['enabled'] as bool?) ?? true;
  }

  /// Update user preference for automatic crash reporting.
  void setReportingEnabled(bool enabled) {
    final config = _readTelemetryConfig();
    config['enabled'] = enabled;
    _writeTelemetryConfig(config);
  }

  /// Retrieves or generates a persistent anonymous user identifier.
  /// Purely random — contains zero machine or personal data.
  String getAnonymousId() {
    final config = _readTelemetryConfig();
    if (config['anonymous_id'] is String && (config['anonymous_id'] as String).isNotEmpty) {
      return config['anonymous_id'] as String;
    }

    // Generate random 16-hex character id
    final random = Random.secure();
    final values = List<int>.generate(8, (_) => random.nextInt(256));
    final id = 'usr_${values.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    config['anonymous_id'] = id;
    _writeTelemetryConfig(config);
    return id;
  }

  // ── Sentry Transmission ───────────────────────────────────────────────────

  /// Generates a valid 32-character hexadecimal event ID for Sentry.
  static String _generateEventId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Asynchronously sends an event directly to Sentry via HTTP.
  Future<bool> sendToSentry({
    required String level, // 'error', 'fatal', 'info', 'warning'
    required String message,
    String? source,
    String? stackTrace,
    Map<String, dynamic>? extra,
  }) async {
    if (!isReportingEnabled()) return false;

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);

      final eventId = _generateEventId();
      final nowUtc = DateTime.now().toUtc().toIso8601String();
      final version = _getAppVersion();
      final env = _getEnvironment();
      final anonId = getAnonymousId();

      final payload = <String, dynamic>{
        'event_id': eventId,
        'timestamp': nowUtc,
        'platform': 'other',
        'level': level,
        'logger': 'screenguard',
        'release': 'screenguard@$version',
        'environment': 'production',
        'message': {'message': message},
        'tags': {
          'source': source ?? 'app',
          'de': env['de'] ?? 'unknown',
          'display_server': env['displayServer'] ?? 'unknown',
          'os': env['os'] ?? 'unknown',
        },
        'user': {
          'id': anonId,
        },
        'contexts': {
          'os': {
            'name': env['os'] ?? 'Linux',
            'version': Platform.operatingSystemVersion,
          },
          'runtime': {
            'name': 'Dart',
            'version': env['dartVersion'] ?? Platform.version,
          },
        },
      };

      if (stackTrace != null && stackTrace.isNotEmpty) {
        payload['extra'] = {
          'stacktrace_raw': stackTrace,
          if (extra != null) ...extra,
        };
      } else if (extra != null) {
        payload['extra'] = extra;
      }

      final request = await client.postUrl(Uri.parse(_sentryEndpoint));
      request.headers.set('Content-Type', 'application/json');
      request.headers.set(
        'X-Sentry-Auth',
        'Sentry sentry_version=7, sentry_client=screenguard/$version, sentry_key=$_sentryKey',
      );

      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(const Duration(seconds: 10));
      client.close(force: true);

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Sends a daily heartbeat ping to register active user count on Sentry.
  /// Only runs once per day, non-blocking.
  Future<void> maybeSendDailyActivePing() async {
    if (!isReportingEnabled()) return;

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final config = _readTelemetryConfig();
    final lastPing = config['last_ping_date'] as String?;

    if (lastPing == today) return; // Already pinged today

    config['last_ping_date'] = today;
    _writeTelemetryConfig(config);

    await sendToSentry(
      level: 'info',
      source: 'daemon',
      message: 'ScreenGuard Daily Active Session',
    );
  }

  // ── Crash Recording ───────────────────────────────────────────────────────

  /// Record a crash/error event.
  ///
  /// [source] identifies where the crash happened: 'daemon', 'gui', or 'watchdog'.
  /// [error] is the error message or exception.toString().
  /// [stackTrace] is the stack trace string (truncated to 50 lines).
  /// [extra] is optional additional context.
  /// [reportToSentry]: real crashes default to true. Routine lifecycle noise
  /// (e.g. unclean shutdown after logout/reboot) must pass false, or every
  /// user logout floods Sentry with non-actionable error events.
  void recordCrash({
    required String source,
    required String error,
    String? stackTrace,
    Map<String, dynamic>? extra,
    bool reportToSentry = true,
  }) {
    try {
      final now = DateTime.now();
      final timestamp = now.toIso8601String();
      final epochMs = now.millisecondsSinceEpoch;

      // Truncate stack trace to avoid huge local files
      String? truncatedStack;
      if (stackTrace != null) {
        final lines = stackTrace.split('\n');
        if (lines.length > 50) {
          truncatedStack =
              '${lines.take(50).join('\n')}\n... (${lines.length - 50} more lines)';
        } else {
          truncatedStack = stackTrace;
        }
      }

      final crashData = <String, dynamic>{
        'version': _getAppVersion(),
        'timestamp': timestamp,
        'source': source,
        'error': error,
        if (truncatedStack != null) 'stackTrace': truncatedStack,
        'environment': _getEnvironment(),
        if (extra != null) ...extra,
      };

      final filename = 'crash_$epochMs.json';
      final file = File('${_crashDirectory.path}/$filename');
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(crashData),
      );

      // Auto-cleanup old logs
      _cleanupOldLogs();

      // Automatically send real crashes to Sentry in background if enabled.
      // Lifecycle noise (reportToSentry: false) stays local-only.
      if (reportToSentry && isReportingEnabled()) {
        sendToSentry(
          level: 'error',
          source: source,
          message: '[$source] $error',
          stackTrace: stackTrace,
          extra: extra,
        );
      }
    } catch (_) {
      // The crash reporter itself must never crash
    }
  }

  /// Record an unclean shutdown (daemon didn't exit cleanly).
  /// Local log only — logout/reboot kills routinely cause these and must
  /// never reach Sentry, or normal user behavior floods the error stream.
  void recordUncleanShutdown() {
    recordCrash(
      source: 'daemon',
      error: 'Unclean shutdown detected — daemon did not exit gracefully on previous run.',
      extra: {'type': 'unclean_shutdown'},
      reportToSentry: false,
    );
  }

  /// Get all crash logs, sorted newest first.
  List<Map<String, dynamic>> getCrashLogs() {
    try {
      final dir = _crashDirectory;
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));

      return files.map((f) {
        try {
          final content = f.readAsStringSync();
          final data = jsonDecode(content) as Map<String, dynamic>;
          data['_filename'] = f.uri.pathSegments.last;
          return data;
        } catch (_) {
          return <String, dynamic>{
            '_filename': f.uri.pathSegments.last,
            'error': 'Could not parse crash log',
          };
        }
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Get the count of crash logs.
  int getCrashCount() {
    try {
      return _crashDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// Delete a specific crash log by filename.
  void deleteCrashLog(String filename) {
    try {
      final file = File('${_crashDirectory.path}/$filename');
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Delete all crash logs.
  void clearAllCrashLogs() {
    try {
      for (final file in _crashDirectory.listSync().whereType<File>()) {
        if (file.path.endsWith('.json')) file.deleteSync();
      }
    } catch (_) {}
  }

  /// Build a GitHub Issue URL pre-filled with crash data.
  String buildGitHubIssueUrl(Map<String, dynamic> crashData) {
    final source = crashData['source'] ?? 'unknown';
    final error = crashData['error'] ?? 'Unknown error';
    final timestamp = crashData['timestamp'] ?? '';
    final version = crashData['version'] ?? 'unknown';
    final stack = crashData['stackTrace'] ?? 'N/A';
    final env = crashData['environment'] as Map<String, dynamic>?;

    final title = Uri.encodeComponent(
      'Crash Report [$source]: ${_truncate(error.toString(), 80)}',
    );

    final body = Uri.encodeComponent(
      '## Crash Report\n\n'
      '**Source:** $source\n'
      '**Version:** $version\n'
      '**Timestamp:** $timestamp\n\n'
      '### Environment\n'
      '- **Desktop Environment:** ${env?['de'] ?? 'unknown'}\n'
      '- **Display Server:** ${env?['displayServer'] ?? 'unknown'}\n'
      '- **OS:** ${env?['os'] ?? 'unknown'}\n'
      '- **Dart Version:** ${env?['dartVersion'] ?? 'unknown'}\n\n'
      '### Error\n'
      '```\n$error\n```\n\n'
      '### Stack Trace\n'
      '```\n$stack\n```\n\n'
      '### Additional Context\n'
      '_Please describe what you were doing when the crash occurred:_\n\n',
    );

    return '$_repoUrl/issues/new?title=$title&body=$body&labels=bug,crash-report';
  }

  /// Open a crash report in the user's default browser.
  void openGitHubIssue(Map<String, dynamic> crashData) {
    final url = buildGitHubIssueUrl(crashData);
    try {
      Process.run('xdg-open', [url]);
    } catch (_) {}
  }

  // ── Daemon health tracking ──────────────────────────────────────────────

  /// Write a "running" sentinel file. Call on daemon start.
  void markDaemonStarted() {
    try {
      final file = File('$_dataDir/daemon_running');
      file.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// Remove the "running" sentinel. Call on clean daemon exit.
  void markDaemonStopped() {
    try {
      final file = File('$_dataDir/daemon_running');
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Check if the daemon's last run ended uncleanly (sentinel still exists).
  bool wasLastShutdownUnclean() {
    try {
      return File('$_dataDir/daemon_running').existsSync();
    } catch (_) {
      return false;
    }
  }

  // ── Heartbeat ───────────────────────────────────────────────────────────

  /// Write a heartbeat timestamp. Call periodically from the daemon.
  void writeHeartbeat() {
    try {
      final file = File('$_dataDir/daemon_heartbeat');
      file.writeAsStringSync(
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
    } catch (_) {}
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  void _cleanupOldLogs() {
    try {
      final files = _crashDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));

      while (files.length > maxCrashLogs) {
        files.removeLast().deleteSync();
      }
    } catch (_) {}
  }

  Map<String, dynamic> _getEnvironment() {
    return {
      'de': Platform.environment['XDG_CURRENT_DESKTOP'] ?? 'unknown',
      'displayServer': Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown',
      'os': _getOsInfo(),
      'dartVersion': Platform.version.split(' ').first,
    };
  }

  String _getOsInfo() {
    try {
      final file = File('/etc/os-release');
      if (file.existsSync()) {
        final lines = file.readAsLinesSync();
        String? name, version;
        for (final line in lines) {
          if (line.startsWith('NAME=')) {
            name = line.substring(5).replaceAll('"', '');
          } else if (line.startsWith('VERSION_ID=')) {
            version = line.substring(11).replaceAll('"', '');
          }
        }
        if (name != null) return version != null ? '$name $version' : name;
      }
    } catch (_) {}
    return Platform.operatingSystemVersion;
  }

  String _getAppVersion() {
    return const String.fromEnvironment('APP_VERSION', defaultValue: '0.1.1-beta.6');
  }

  static String _truncate(String s, int maxLen) {
    return s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';
  }
}
