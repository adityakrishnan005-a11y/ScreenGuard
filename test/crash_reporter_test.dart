import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/crash_reporter.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late List<Map<String, dynamic>> received;
  late List<int> statuses;
  late DateTime now;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sg_crash_reporter');
    received = <Map<String, dynamic>>[];
    statuses = <int>[];
    now = DateTime.utc(2026, 10, 24, 8, 30);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.add(jsonDecode(body) as Map<String, dynamic>);

      final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        status >= 200 && status < 300
            ? '{"id":"accepted"}'
            : '{"error":"nope"}',
      );
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CrashReporter reporter({String channel = 'stable'}) {
    return CrashReporter(
      dataDir: tmp.path,
      endpoint: 'http://127.0.0.1:${server.port}/api/0/store/',
      channel: channel,
      clock: () => now,
    );
  }

  Map<String, dynamic> readConfig() {
    return jsonDecode(
      File('${tmp.path}/telemetry.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  }

  void writeConfig(Map<String, dynamic> config) {
    File('${tmp.path}/telemetry.json').writeAsStringSync(jsonEncode(config));
  }

  test('sends one ping and commits only after a 2xx', () async {
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, hasLength(1));
    final event = received.single;
    expect(event['message'], {'message': 'ScreenGuard Daily Active Session'});
    expect(event['user']['id'], startsWith('usr_'));
    expect(event['tags']['source'], 'daemon');
    expect(event['tags']['ping_schema'], '2');
    expect(event['tags']['build_channel'], 'stable');
    expect(event['timestamp'], startsWith('2026-10-24'));

    final config = readConfig();
    expect(config['last_ping_success'], '2026-10-24');
    expect(config['ping_outbox'], isEmpty);

    // A second call on the same UTC day must not send again.
    await reporterUnderTest.maybeSendDailyActivePing();
    expect(received, hasLength(1));
  });

  test('keeps a failed day queued and retries with the same event id',
      () async {
    statuses = <int>[500, 200];
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();
    expect(received, hasLength(1));

    var config = readConfig();
    expect(config['last_ping_success'], isNull);
    expect(config['ping_outbox'], hasLength(1));
    expect(config['ping_outbox'][0]['attempts'], 1);
    expect(
      config['ping_outbox'][0]['next_attempt_at'],
      greaterThan(now.millisecondsSinceEpoch),
    );
    final firstEventId = received.single['event_id'];

    // Still inside the 5-minute backoff: no request.
    await reporterUnderTest.maybeSendDailyActivePing();
    expect(received, hasLength(1));

    now = now.add(const Duration(minutes: 6));
    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, hasLength(2));
    expect(received.last['event_id'], firstEventId);

    config = readConfig();
    expect(config['last_ping_success'], '2026-10-24');
    expect(config['ping_outbox'], isEmpty);
  });

  test('drains queued days in order and keeps their original dates', () async {
    writeConfig({
      'anonymous_id': 'usr_test',
      'enabled': true,
      'last_ping_success': '2026-10-21',
      'last_ping_date': '2026-10-21',
      'ping_outbox': [
        {
          'date': '2026-10-22',
          'event_id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'attempts': 1,
          'next_attempt_at': 0,
        },
        {
          'date': '2026-10-23',
          'event_id': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'attempts': 1,
          'next_attempt_at': 0,
        },
      ],
    });
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, hasLength(3));
    expect(
      received.map((event) => (event['timestamp'] as String).substring(0, 10)),
      ['2026-10-22', '2026-10-23', '2026-10-24'],
    );
    // Queued days are pinned to noon UTC; today keeps its send time.
    expect(received[0]['timestamp'], '2026-10-22T12:00:00.000Z');
    expect(received[1]['timestamp'], '2026-10-23T12:00:00.000Z');
    expect(readConfig()['last_ping_success'], '2026-10-24');
  });

  test('does not invent active days while the daemon was not running',
      () async {
    writeConfig({
      'anonymous_id': 'usr_test',
      'enabled': true,
      'last_ping_success': '2026-10-21',
      'last_ping_date': '2026-10-21',
    });
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, hasLength(1));
    expect(received.single['timestamp'], startsWith('2026-10-24'));
    expect(readConfig()['last_ping_success'], '2026-10-24');
  });

  test('does not send when reporting is disabled', () async {
    writeConfig({'anonymous_id': 'usr_test', 'enabled': false});
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, isEmpty);
    expect(readConfig()['last_ping_success'], isNull);
  });

  test('does not send the daily ping from a dev build', () async {
    final reporterUnderTest = reporter(channel: 'dev');

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, isEmpty);
  });

  test('trusts a legacy last_ping_date instead of double-sending today',
      () async {
    writeConfig({
      'anonymous_id': 'usr_legacy',
      'enabled': true,
      'last_ping_date': '2026-10-24',
    });
    final reporterUnderTest = reporter();

    await reporterUnderTest.maybeSendDailyActivePing();

    expect(received, isEmpty);
    expect(readConfig()['last_ping_success'], '2026-10-24');
  });

  test('disabling reporting clears queued days instead of back-filling them',
      () async {
    writeConfig({
      'anonymous_id': 'usr_test',
      'enabled': true,
      'last_ping_success': '2026-10-20',
      'ping_outbox': [
        {
          'date': '2026-10-21',
          'event_id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'attempts': 2,
          'next_attempt_at': 0,
        },
      ],
    });
    final reporterUnderTest = reporter();

    reporterUnderTest.setReportingEnabled(false);

    final config = readConfig();
    expect(config['ping_outbox'], isEmpty);
    expect(config['last_ping_success'], '2026-10-24');

    await reporterUnderTest.maybeSendDailyActivePing();
    expect(received, isEmpty);
  });
}
