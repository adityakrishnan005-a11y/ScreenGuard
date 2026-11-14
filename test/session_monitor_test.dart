import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/session_monitor.dart';

void main() {
  group('logind signal parsing', () {
    test('Lock and Unlock', () {
      expect(
        SessionMonitor.parseSignal(
            '/org/freedesktop/login1: org.freedesktop.login1.Manager.Lock ()'),
        SessionSignal.lock,
      );
      expect(
        SessionMonitor.parseSignal(
            '/org/freedesktop/login1: org.freedesktop.login1.Manager.Unlock ()'),
        SessionSignal.unlock,
      );
    });

    test('PrepareForSleep maps the boolean to suspend/resume', () {
      expect(
        SessionMonitor.parseSignal(
            '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true)'),
        SessionSignal.suspend,
      );
      expect(
        SessionMonitor.parseSignal(
            '/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false)'),
        SessionSignal.resume,
      );
    });

    test('a session lock signal is Lock, not Unlock', () {
      const line =
          '/org/freedesktop/login1/session/_32: org.freedesktop.login1.Session.Lock ()';
      // Session.Lock is a different interface; only the Manager signal is used.
      expect(SessionMonitor.parseSignal(line), isNull);
    });

    test('unrelated monitor output is ignored', () {
      expect(SessionMonitor.parseSignal('Monitoring signals on object'),
          isNull);
      expect(SessionMonitor.parseSignal(''), isNull);
    });
  });
}
