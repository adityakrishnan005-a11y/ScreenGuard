import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/feedback_service.dart';

void main() {
  group('version gating', () {
    test('accepts a version inside the range', () {
      expect(
        FeedbackService.isVersionInRange(
          '0.1.1-beta.6',
          min: '0.1.1-beta.4',
          max: '0.1.1-beta.99',
        ),
        isTrue,
      );
    });

    test('accepts the lower bound itself', () {
      expect(
        FeedbackService.isVersionInRange(
          '0.1.1-beta.4',
          min: '0.1.1-beta.4',
          max: '0.1.1-beta.99',
        ),
        isTrue,
      );
    });

    test('rejects a version below the range', () {
      expect(
        FeedbackService.isVersionInRange(
          '0.1.1-beta.3',
          min: '0.1.1-beta.4',
          max: '0.1.1-beta.99',
        ),
        isFalse,
      );
    });

    test('rejects a version above the range', () {
      expect(
        FeedbackService.isVersionInRange(
          '0.1.1-beta.100',
          min: '0.1.1-beta.4',
          max: '0.1.1-beta.99',
        ),
        isFalse,
      );
    });

    test('treats a stable release as newer than any beta of it', () {
      expect(
        FeedbackService.isVersionInRange(
          '0.1.1',
          min: '0.1.1-beta.4',
          max: '0.1.1-beta.99',
        ),
        isFalse,
      );
    });

    test('an empty bound is unbounded', () {
      expect(
        FeedbackService.isVersionInRange('0.1.1-beta.6'),
        isTrue,
      );
      expect(
        FeedbackService.isVersionInRange('9.9.9', min: '0.1.1-beta.4'),
        isTrue,
      );
    });
  });

  group('document parsing', () {
    test('parses a single request object', () {
      final prompts = FeedbackService.parseDocument(
        '{"id": "a", "title": "Hello"}',
      );
      expect(prompts.length, 1);
      expect(prompts.first['id'], 'a');
    });

    test('parses a list of requests', () {
      final prompts = FeedbackService.parseDocument(
        '[{"id": "a"}, {"id": "b"}]',
      );
      expect(prompts.length, 2);
      expect(prompts.last['id'], 'b');
    });

    test('survives malformed input', () {
      expect(FeedbackService.parseDocument('not json'), isEmpty);
      expect(FeedbackService.parseDocument(''), isEmpty);
      expect(FeedbackService.parseDocument('42'), isEmpty);
    });
  });

  group('action list', () {
    test('keeps http(s) actions only', () {
      final actions = FeedbackService.actionsOf({
        'actions': [
          {'label': 'Good', 'url': 'https://example.com'},
          {'label': 'Local', 'url': 'file:///etc/passwd'},
          {'label': 'Custom scheme', 'url': 'mailto:a@b.c'},
          {'label': '', 'url': 'https://example.com'},
        ],
      });
      expect(actions.length, 1);
      expect(actions.first.label, 'Good');
      expect(actions.first.url, 'https://example.com');
    });

    test('tolerates a missing action list', () {
      expect(FeedbackService.actionsOf({}), isEmpty);
    });
  });
}
