import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:screenguard/services/app_version.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/notification_service.dart';
import 'package:screenguard/services/update_checker.dart';

/// Remote feedback-request channel for ScreenGuard.
///
/// The maintainer publishes a small JSON document (`feedback.json`) on the
/// project's gh-pages site.  The daemon fetches it once a day, keeps the
/// request that matches the running version, and the GUI shows it once as a
/// dialog.
///
/// Guarantees:
/// - Read-only GET of a static file.  The only thing that leaves the
///   machine is the app version in the `User-Agent` header — no
///   identifiers, no usage data, nothing to correlate.  Same stance as the
///   update checker.
/// - Every failure is swallowed.  A missing, malformed or unreachable
///   document must never disturb tracking or take the daemon down.
/// - The request is version-gated, so one file can target a single cohort
///   (e.g. "only users on 0.1.1-beta.4 or newer").
class FeedbackService {
  /// Default location of the feedback document.
  static const String defaultEndpoint =
      'https://adityakrishnan005-a11y.github.io/ScreenGuard/feedback.json';

  /// The feedback hub — a pinned discussion that explains what to report.
  static const String feedbackHubUrl =
      'https://github.com/adityakrishnan005-a11y/ScreenGuard/discussions/5';

  /// Where a brand new discussion is started.
  static const String discussionsUrl =
      'https://github.com/adityakrishnan005-a11y/ScreenGuard/discussions/new';

  // ── Settings keys ───────────────────────────────────────────────────────

  static const String keyLastCheck = 'feedback_last_check_time';
  static const String keyPromptJson = 'feedback_prompt_json';
  static const String keyPromptId = 'feedback_prompt_id';
  static const String keyDismissedId = 'feedback_dismissed_id';
  static const String keySnoozeUntil = 'feedback_snooze_until';

  /// How often the daemon looks for a new request.
  static const Duration checkInterval = Duration(hours: 12);

  /// Minimum delay between two network checks.
  static const Duration minimumGap = Duration(days: 1);

  /// How long "Maybe later" postpones a request.
  static const Duration snoozeDuration = Duration(days: 7);

  final DatabaseService db;

  /// Override for the document location (used by tests).
  final String endpoint;

  Timer? _timer;

  FeedbackService({required this.db, this.endpoint = defaultEndpoint});

  // ── Settings accessors ──────────────────────────────────────────────────

  /// ISO timestamp of the last network check (empty when never checked).
  String get lastCheckTime => db.getSetting(keyLastCheck, defaultValue: '');

  /// Id of the request currently stored (empty when none).
  String get storedPromptId => db.getSetting(keyPromptId, defaultValue: '');

  /// Id of the request the user already handled.
  String get dismissedPromptId =>
      db.getSetting(keyDismissedId, defaultValue: '');

  /// Moment until which the current request is postponed.
  DateTime? get snoozeUntil {
    final raw = db.getSetting(keySnoozeUntil, defaultValue: '');
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  // ── Request lifecycle ───────────────────────────────────────────────────

  /// The request that should be shown right now, or `null`.
  ///
  /// A request qualifies when it targets the running version, has not
  /// expired, was not dismissed and is not snoozed.
  Map<String, dynamic>? get activePrompt {
    final raw = db.getSetting(keyPromptJson, defaultValue: '');
    if (raw.isEmpty) return null;

    final prompt = _decodePrompt(raw);
    if (prompt == null) return null;

    final id = (prompt['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;

    if (!matchesVersion(prompt)) return null;
    if (dismissedPromptId == id) return null;

    final snoozedUntil = snoozeUntil;
    if (snoozedUntil != null && DateTime.now().isBefore(snoozedUntil)) {
      return null;
    }

    final expires = _parseDate(prompt['expires']);
    if (expires != null && DateTime.now().isAfter(expires)) return null;

    return prompt;
  }

  /// Whether [prompt] targets [version] (the running version by default).
  bool matchesVersion(Map<String, dynamic> prompt, {String? version}) {
    final min = (prompt['min_version'] as String?)?.trim() ?? '';
    final max = (prompt['max_version'] as String?)?.trim() ?? '';
    return isVersionInRange(
      version ?? AppVersion.current,
      min: min,
      max: max,
    );
  }

  /// Whether [version] falls inside the inclusive range `min`..`max`.
  ///
  /// An empty bound means "unbounded" on that side.
  static bool isVersionInRange(
    String version, {
    String min = '',
    String max = '',
  }) {
    if (min.isNotEmpty && UpdateChecker.compareVersions(version, min) < 0) {
      return false;
    }
    if (max.isNotEmpty && UpdateChecker.compareVersions(version, max) > 0) {
      return false;
    }
    return true;
  }

  /// Mark the stored request as handled — it will not be shown again.
  void dismiss([String? id]) {
    final target = id ?? storedPromptId;
    if (target.isEmpty) return;
    db.setSetting(keyDismissedId, target);
    db.setSetting(keySnoozeUntil, '');
  }

  /// Postpone the stored request; it reappears after [duration].
  void snooze({Duration? duration, String? id}) {
    final target = id ?? storedPromptId;
    if (target.isEmpty) return;
    final until = DateTime.now().add(duration ?? snoozeDuration);
    db.setSetting(keySnoozeUntil, until.toIso8601String());
  }

  /// Forget the stored request entirely.
  void clearStoredPrompt() {
    db.setSetting(keyPromptJson, '');
    db.setSetting(keyPromptId, '');
  }

  /// The action buttons of [prompt] as label/url pairs.
  ///
  /// Non-HTTP(S) URLs are dropped — the document is remote input and must
  /// not be able to point the app at local files or custom schemes.
  static List<({String label, String url})> actionsOf(
    Map<String, dynamic> prompt,
  ) {
    final raw = prompt['actions'];
    if (raw is! List) return const [];
    final actions = <({String label, String url})>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final label = (item['label'] as String?)?.trim() ?? '';
      final url = (item['url'] as String?)?.trim() ?? '';
      if (label.isEmpty || url.isEmpty) continue;
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        continue;
      }
      actions.add((label: label, url: url));
    }
    return actions;
  }

  // ── Periodic checking (daemon) ──────────────────────────────────────────

  /// Start the periodic check.  Called by the daemon.
  void startPeriodicChecks() {
    checkIfDue();
    _timer = Timer.periodic(checkInterval, (_) => checkIfDue());
  }

  /// Stop the periodic check.
  void stopPeriodicChecks() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetch the document only when the minimum gap since the last check has
  /// passed.  Returns `true` when a new request was stored.
  Future<bool> checkIfDue() async {
    final last = DateTime.tryParse(lastCheckTime);
    if (last != null && DateTime.now().difference(last) < minimumGap) {
      return false;
    }
    return checkNow();
  }

  /// Fetch the document right now, ignoring the minimum gap, and notify the
  /// user when a new request shows up.  Returns `true` when a new request
  /// was stored.  Never throws.
  Future<bool> checkNow() async {
    final changed = await fetchAndStore();
    if (changed) {
      await notifyIfNew();
    }
    return changed;
  }

  /// Fetch the document and store the request matching this version.
  ///
  /// Returns `true` when a *new* request was stored — the caller may then
  /// notify the user.  Never throws.
  Future<bool> fetchAndStore() async {
    final body = await _fetchDocument();
    db.setSetting(keyLastCheck, DateTime.now().toIso8601String());
    if (body == null) return false;

    final prompt = _selectPrompt(body);
    if (prompt == null) return false;

    final id = (prompt['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return false;

    final changed = id != storedPromptId;
    db.setSetting(keyPromptJson, jsonEncode(prompt));
    db.setSetting(keyPromptId, id);
    return changed;
  }

  /// Tell the user a request is waiting.  Called by the daemon.
  Future<void> notifyIfNew() async {
    final prompt = activePrompt;
    if (prompt == null) return;
    final title = (prompt['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return;
    await NotificationService.show(
      db: db,
      eventKey: 'feedback',
      title: 'ScreenGuard — $title',
      body: 'Open ScreenGuard to see the request.',
      icon: 'screenguard',
      playSound: false,
    );
  }

  // ── Internals ───────────────────────────────────────────────────────────

  Future<String?> _fetchDocument() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      // Cache-bust: the document is served as a static file and may be
      // cached aggressively by the CDN.
      final url = Uri.parse(
        '$endpoint?t=${DateTime.now().millisecondsSinceEpoch}',
      );
      final request = await client.getUrl(url);
      request.headers.set('User-Agent', 'ScreenGuard/${AppVersion.current}');

      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        client.close(force: true);
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      return body;
    } catch (_) {
      return null;
    }
  }

  /// Pick the first request in [body] that targets this version.
  ///
  /// The document may be a single request object or a list of them.
  Map<String, dynamic>? _selectPrompt(String body) {
    for (final prompt in parseDocument(body)) {
      if (matchesVersion(prompt)) return prompt;
    }
    return null;
  }

  /// Parse the remote document into a list of requests.
  ///
  /// The document may hold a single request object or a list of them.
  /// Malformed input yields an empty list — never an exception.
  static List<Map<String, dynamic>> parseDocument(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((entry) => entry.cast<String, dynamic>())
            .toList();
      }
      if (decoded is Map) {
        return [decoded.cast<String, dynamic>()];
      }
    } catch (_) {}
    return const [];
  }

  Map<String, dynamic>? _decodePrompt(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim());
  }
}
