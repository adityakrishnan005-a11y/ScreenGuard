import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/feedback_service.dart';

/// One-time dialog that shows a feedback request published by the
/// maintainer.
///
/// Mirrors [DaemonPromptDialog]: the dialog never blocks the app, it just
/// waits for the user to act on it.  Choosing an action marks the request
/// as handled, "Maybe later" postpones it by a week.
class FeedbackDialog extends StatelessWidget {
  final Map<String, dynamic> prompt;
  final FeedbackService service;

  const FeedbackDialog({
    super.key,
    required this.prompt,
    required this.service,
  });

  /// Outcome of the dialog.
  static const String resultSnooze = 'snooze';
  static const String resultDismiss = 'dismiss';

  /// Show the pending request, if there is one.
  static Future<void> showIfNeeded(
    BuildContext context,
    DatabaseService db,
  ) async {
    final service = FeedbackService(db: db);
    final prompt = service.activePrompt;
    if (prompt == null) return;

    // Give the dashboard a moment to settle before covering it.
    await Future.delayed(const Duration(milliseconds: 350));
    if (!context.mounted) return;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => FeedbackDialog(prompt: prompt, service: service),
    );
    if (!context.mounted) return;

    if (result == null) {
      // Dismissed by tapping outside — ask again later instead of nagging.
      service.snooze();
      return;
    }
    if (result.startsWith('url:')) {
      final url = result.substring(4);
      await openUrl(url);
      service.dismiss();
      return;
    }
    if (result == resultDismiss) {
      service.dismiss();
    }
  }

  /// Open [url] in the user's browser.
  static Future<void> openUrl(String url) async {
    try {
      await Process.run('xdg-open', [url]);
    } catch (_) {
      // Nothing we can do — the dialog simply stays usable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = (prompt['title'] as String?)?.trim() ?? 'Feedback';
    final body = (prompt['body'] as String?)?.trim() ?? '';
    final actions = FeedbackService.actionsOf(prompt);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              color: Colors.teal,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (body.isNotEmpty)
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                for (final action in actions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop('url:${action.url}'),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(action.label),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(resultSnooze),
                    child: const Text('Maybe later'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(resultDismiss),
                    child: const Text("Don't ask again"),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
