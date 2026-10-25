import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:screenguard/services/app_version.dart';

/// Lightweight crash/error reporter and telemetry service for ScreenGuard.
///
/// - Writes structured JSON crash logs locally (~1-5 KB each) for user inspection.
/// - Reads and manages stored crash logs.
/// - Connects to Sentry for automatic crash analysis and active user counting (opt-out).
/// - Completely zero-dependency (pure dart:io + dart:convert).
/// - Anonymous: Uses a random local UUID (no IP, username, or screen time data transmitted).
class CrashReporter {
  static const int maxCrashLogs = 20;
  static const String _crashDir = 'crashes';
  static const String _repoUrl =
      'https://github.com/adityakrishnan005-a11y/screenguard';
  static const int _maxQueuedDays = 7;

  // Sentry Configuration
  static const String _sentryKey = '4898f3d5a159e8a898b548c1ad262ca6';
  static const String _sentryHost = 'o4512252813115392.ingest.de.sentry.io';
  static const String _sentryProjectId = '4512252819996752';
  static const String _sentryEndpoint =
      'https://$_sentryHost/api/$_sentryProjectId/store/';

  final String _dataDir;
  final String? _endpoint;
  final String? _channelOverride;
  final DateTime Function() _clock;
  bool _pingInFlight = false;

  CrashReporter({
    String? dataDir,
    String? endpoint,
    String? channel,
    DateTime Function()? clock,
  })  : _dataDir = dataDir ?? _resolveDataDir(),
        _endpoint = endpoint,
        _channelOverride = channel,
        _clock = clock ?? DateTime.now;

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

  /// Read-modify-write helper so concurrent callers cannot overwrite each
  /// other's keys with a stale copy of the config.
  void _updateTelemetryConfig(
      void Function(Map<String, dynamic> config) mutate) {
    final config = _readTelemetryConfig();
    mutate(config);
    _writeTelemetryConfig(config);
  }

  /// Whether anonymous diagnostics (crash reports and the daily
  /// active-install ping) are enabled. Default: true (opt-out).
  bool isReportingEnabled() {
    final config = _readTelemetryConfig();
    return (config['enabled'] as bool?) ?? true;
  }

  /// Update user preference for anonymous diagnostics.
  void setReportingEnabled(bool enabled) {
    _updateTelemetryConfig((config) {
      config['enabled'] = enabled;
      if (!enabled) {
        // Nothing may be queued while reporting is off. When the user opts
        // back in, start from that day instead of back-filling the opt-out
        // window they explicitly refused to share.
        config['ping_outbox'] = <Map<String, dynamic>>[];
        final today = _utcDate(_clock().toUtc());
        config['last_ping_success'] = today;
        config['last_ping_date'] = today;
      }
    });
  }

  /// Retrieves or generates a persistent anonymous user identifier.
  /// Purely random — contains zero machine or personal data.
  String getAnonymousId() {
    final config = _readTelemetryConfig();
    final existing = config['anonymous_id'];
    if (existing is String && existing.isNotEmpty) {
      return existing;
    }

    // Generate random 16-hex character id
    final random = Random.secure();
    final values = List<int>.generate(8, (_) => random.nextInt(256));
    final id =
        'usr_${values.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    _updateTelemetryConfig((config) => config['anonymous_id'] = id);
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
    String? eventId,
    DateTime? timestamp,
    Map<String, String>? extraTags,
  }) async {
    if (!isReportingEnabled()) return false;

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);

      try {
        final id = eventId ?? _generateEventId();
        final sentAt = (timestamp ?? _clock()).toUtc().toIso8601String();
        final version = _getAppVersion();
        final env = _getEnvironment();
        final anonId = getAnonymousId();
        final channel = _buildChannel();

        final payload = <String, dynamic>{
          'event_id': id,
          'timestamp': sentAt,
          'platform': 'other',
          'level': level,
          'logger': 'screenguard',
          'release': 'screenguard@$version',
          'environment': channel == 'dev' ? 'development' : 'production',
          'message': {'message': message},
          'tags': {
            'source': source ?? 'app',
            'de': env['de'] ?? 'unknown',
            'display_server': env['displayServer'] ?? 'unknown',
            'os': env['os'] ?? 'unknown',
            'build_channel': channel,
            if (extraTags != null) ...extraTags,
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

        final endpoint = _endpoint ?? _sentryEndpoint;
        final request = await client.postUrl(Uri.parse(endpoint));
        request.headers.set('Content-Type', 'application/json');
        request.headers.set(
          'X-Sentry-Auth',
          'Sentry sentry_version=7, sentry_client=screenguard/$version, sentry_key=$_sentryKey',
        );

        request.add(utf8.encode(jsonEncode(payload)));
        final response =
            await request.close().timeout(const Duration(seconds: 10));

        // Drain the body so the connection is not torn down before Sentry has
        // finished accepting the event.
        await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));

        return response.statusCode >= 200 && response.statusCode < 300;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
    }
  }

  /// Sends a daily heartbeat ping to register active user count on Sentry.
  ///
  /// Delivery is best-effort but never silently abandoned: each UTC day is
  /// queued locally, retried with backoff, and only marked sent after Sentry
  /// accepts it. Up to seven days of queued failures are retried, so a flaky
  /// network no longer erases a day on which the daemon was actually running.
  Future<void> maybeSendDailyActivePing() async {
    if (_pingInFlight) return;
    if (!isReportingEnabled()) return;
    if (_buildChannel() == 'dev') return;
    if (_isCi()) return;
    if (Platform.environment['SCREENGUARD_NO_TELEMETRY'] == '1') return;

    _pingInFlight = true;
    try {
      // Persist the anonymous id before touching the config, otherwise a
      // later read-modify-write could overwrite the freshly generated id.
      getAnonymousId();

      final nowUtc = _clock().toUtc();
      final today = _utcDate(nowUtc);

      _updateTelemetryConfig((config) => _ensureOutbox(config, nowUtc));

      final config = _readTelemetryConfig();
      final pending = _outbox(config)
        ..sort((a, b) {
          final aDate = a['date'] as String? ?? '';
          final bDate = b['date'] as String? ?? '';
          return aDate.compareTo(bDate);
        });

      for (final entry in pending) {
        final date = entry['date'];
        final eventId = entry['event_id'];
        if (date is! String || eventId is! String) continue;

        final nextAttempt = entry['next_attempt_at'];
        if (nextAttempt is int && nextAttempt > nowUtc.millisecondsSinceEpoch) {
          continue; // Still backing off from a previous failure.
        }

        // Back-filled days use noon UTC so they cannot drift across the day
        // boundary; today's ping keeps its real send time.
        final sentAt =
            date == today ? nowUtc : DateTime.parse('${date}T12:00:00Z');

        final delivered = await sendToSentry(
          level: 'info',
          source: 'daemon',
          message: 'ScreenGuard Daily Active Session',
          eventId: eventId,
          timestamp: sentAt,
          extraTags: const {'ping_schema': '2'},
        );

        if (delivered) {
          _updateTelemetryConfig((config) {
            final remaining = _outbox(config)
              ..removeWhere((e) => e['date'] == date);
            config['ping_outbox'] = remaining;

            final previous = config['last_ping_success'] as String?;
            if (previous == null || date.compareTo(previous) > 0) {
              config['last_ping_success'] = date;
              config['last_ping_date'] = date;
            }
          });
        } else {
          _updateTelemetryConfig((config) {
            final queued = _outbox(config);
            for (final e in queued) {
              if (e['date'] != date) continue;
              final attempts = (e['attempts'] as int? ?? 0) + 1;
              e['attempts'] = attempts;
              e['next_attempt_at'] =
                  nowUtc.add(_retryDelay(attempts)).millisecondsSinceEpoch;
            }
            config['ping_outbox'] = queued;
            config['last_ping_attempt'] = nowUtc.toIso8601String();
          });

          // Sentry is likely unreachable; do not hammer the rest of the
          // queue on the same tick.
          break;
        }
      }
    } catch (_) {
      // Telemetry must never take the daemon down.
    } finally {
      _pingInFlight = false;
    }
  }

  /// Builds the local queue of days that still need a heartbeat.
  void _ensureOutbox(Map<String, dynamic> config, DateTime nowUtc) {
    final today = _utcDate(nowUtc);
    final todayDate = DateTime.parse('${today}T00:00:00Z');
    final earliest =
        todayDate.subtract(const Duration(days: _maxQueuedDays - 1));

    // Migration from beta.6 and older: last_ping_date was written *before*
    // the network call, so it is only evidence of an attempt. Trust it rather
    // than double-counting an install on upgrade day.
    if (config['last_ping_success'] == null) {
      final legacy = config['last_ping_date'];
      if (legacy is String && _dateOnly(legacy) != null) {
        config['last_ping_success'] = legacy;
      }
    }

    final successRaw = config['last_ping_success'];
    final successDate = successRaw is String ? _dateOnly(successRaw) : null;
    if (successRaw != null && successDate == null) {
      // Old/corrupt value: drop it rather than trusting an invalid date.
      config.remove('last_ping_success');
    }
    final success = successDate == null ? null : _utcDate(successDate);

    final queued = _outbox(config)
      ..removeWhere((entry) {
        final date = entry['date'];
        if (date is! String) return true;
        final parsed = _dateOnly(date);
        if (parsed == null) return true;
        if (parsed.isBefore(earliest) || parsed.isAfter(todayDate)) return true;
        if (success != null && date.compareTo(success) <= 0) return true;
        return false;
      });

    // Only enqueue *today*. Missing days are not invented: if the daemon was
    // not running, the install was not active and must not be counted. Queued
    // failures from previous days (created while the daemon was running) are
    // already in the list and will be retried on this tick.
    if (success != today && !queued.any((entry) => entry['date'] == today)) {
      queued.add(<String, dynamic>{
        'date': today,
        'event_id': _generateEventId(),
        'attempts': 0,
        'next_attempt_at': 0,
      });
    }

    config['ping_outbox'] = queued;
  }

  List<Map<String, dynamic>> _outbox(Map<String, dynamic> config) {
    final raw = config['ping_outbox'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Duration _retryDelay(int attempts) {
    if (attempts <= 1) return const Duration(minutes: 5);
    if (attempts == 2) return const Duration(minutes: 15);
    if (attempts == 3) return const Duration(hours: 1);
    return const Duration(hours: 6);
  }

  String _buildChannel() {
    const define = String.fromEnvironment('SCREENGUARD_CHANNEL');
    final env = Platform.environment['SCREENGUARD_CHANNEL'];
    final raw =
        (_channelOverride ?? (env != null && env.isNotEmpty ? env : define))
            .trim()
            .toLowerCase();

    if (raw == 'dev' || raw == 'local' || raw == 'development') return 'dev';
    if (raw == 'beta' || raw == 'prerelease') return 'beta';
    if (raw == 'stable' || raw == 'release' || raw == 'production') {
      return 'stable';
    }
    return AppVersion.current.contains('-beta') ? 'beta' : 'stable';
  }

  bool _isCi() {
    final ci = Platform.environment['CI'];
    return ci == 'true' || ci == '1';
  }

  static DateTime? _dateOnly(String value) {
    if (value.length != 10) return null;
    final parsed = DateTime.tryParse('${value}T00:00:00Z');
    if (parsed == null) return null;
    // Reject dates that parse but normalize (e.g. 2026-02-30).
    return _utcDate(parsed) == value ? parsed : null;
  }

  static String _utcDate(DateTime dateTime) {
    final utc = dateTime.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-$month-$day';
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
      error:
          'Unclean shutdown detected — daemon did not exit gracefully on previous run.',
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
    return AppVersion.current;
  }

  static String _truncate(String s, int maxLen) {
    return s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';
  }
}
