import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/session_memory.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sg_session_memory');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  SessionMemory memory(int at, {int? id = 7, String app = 'firefox'}) {
    return SessionMemory(
      writtenAtMs: at,
      currentSessionId: id,
      currentApp: id == null ? null : app,
      currentTitle: id == null ? null : 'Example',
      currentPid: id == null ? null : 4242,
      currentIdle: id == null ? null : false,
      sessionStartedAtMs: id == null ? null : 1000,
      lastTickMs: at,
      lastIdleReported: false,
      sessionLocked: false,
      suspended: false,
      dayStartMs: 500,
      consecutiveUnknownTicks: 2,
    );
  }

  group('SessionJournal', () {
    test('empty directory loads as null', () {
      final journal = SessionJournal(directory: tmp.path);
      expect(journal.load(), isNull);
      expect(journal.info()['enabled'], isTrue);
    });

    test('append is replayed on load', () {
      final journal = SessionJournal(directory: tmp.path);
      journal.append(memory(2000));
      journal.append(memory(3000, app: 'terminal'));

      final loaded = journal.load();
      expect(loaded, isNotNull);
      expect(loaded!.writtenAtMs, 3000);
      expect(loaded.currentApp, 'terminal');
      expect(loaded.lastTickMs, 3000);
      expect(loaded.sessionStartedAtMs, 1000);
      expect(loaded.currentPid, 4242);
      expect(loaded.consecutiveUnknownTicks, 2);
    });

    test('checkpoint writes a snapshot and truncates the journal', () {
      final journal = SessionJournal(directory: tmp.path);
      journal.append(memory(2000));
      journal.checkpoint(memory(4000, app: 'editor'));

      final journalFile = File('${tmp.path}/session-journal.jsonl');
      final snapshotFile = File('${tmp.path}/session-state.json');
      expect(snapshotFile.existsSync(), isTrue);
      expect(journalFile.lengthSync(), 0);

      final loaded = journal.load();
      expect(loaded!.writtenAtMs, 4000);
      expect(loaded.currentApp, 'editor');
    });

    test('a corrupt final journal line is ignored', () {
      final journal = SessionJournal(directory: tmp.path);
      journal.append(memory(2000));
      File('${tmp.path}/session-journal.jsonl').writeAsStringSync(
          '{"v":1,"seq":999,"state":',
          mode: FileMode.append);

      final loaded = journal.load();
      expect(loaded, isNotNull);
      expect(loaded!.writtenAtMs, 2000);
    });

    test('stale records older than the snapshot are ignored', () {
      final journal = SessionJournal(directory: tmp.path);
      journal.checkpoint(memory(5000, app: 'new'));

      // Simulate a crash between the snapshot rename and journal truncate:
      // an older record survives with a lower sequence number.
      final stale = jsonEncode(<String, Object?>{
        'v': SessionMemory.schemaVersion,
        'seq': 1,
        'state': memory(1000, app: 'stale').toJson(),
      });
      File('${tmp.path}/session-journal.jsonl')
          .writeAsStringSync('$stale\n', mode: FileMode.append);

      final loaded = journal.load();
      expect(loaded!.currentApp, 'new');
      expect(loaded.writtenAtMs, 5000);
    });

    test('append compacts automatically at the threshold', () {
      final journal = SessionJournal(directory: tmp.path, compactAfter: 3);
      journal.append(memory(1000));
      journal.append(memory(2000));
      journal.append(memory(3000, app: 'third'));

      expect(journal.entries, 0);
      expect(File('${tmp.path}/session-state.json').existsSync(), isTrue);
      expect(File('${tmp.path}/session-journal.jsonl').lengthSync(), 0);

      final loaded = journal.load();
      expect(loaded!.currentApp, 'third');
      expect(loaded.writtenAtMs, 3000);
    });

    test('explicit compact keeps the latest state', () {
      final journal = SessionJournal(directory: tmp.path);
      journal.append(memory(1000));
      journal.append(memory(2000, app: 'latest'));

      final kept = journal.compact();
      expect(kept!.currentApp, 'latest');
      expect(journal.entries, 0);
      expect(journal.load()!.writtenAtMs, 2000);
    });
  });

  group('DatabaseService session recovery hooks', () {
    test('getSession returns the row', () {
      final db = DatabaseService();
      addTearDown(() => db.db.dispose());
      db.init(path: '${tmp.path}/usage.db');

      final id = db.openSession(
        app: 'firefox',
        appName: 'Firefox',
        startedAt: 1000,
        idle: false,
      );

      final row = db.getSession(id);
      expect(row, isNotNull);
      expect(row!['app'], 'firefox');
      expect(row['started_at'], 1000);
      expect(row['ended_at'], isNull);
    });

    test('orphan repair can preserve a resumed session', () {
      final db = DatabaseService();
      addTearDown(() => db.db.dispose());
      db.init(path: '${tmp.path}/usage.db');

      final resumed = db.openSession(
        app: 'firefox',
        startedAt: 1000,
        idle: false,
      );
      final orphan = db.openSession(
        app: 'terminal',
        startedAt: 2000,
        idle: false,
      );

      final repaired = db.closeOrphanedSessions(preserveId: resumed);

      expect(repaired, 1);
      expect(db.getSession(resumed)!['ended_at'], isNull);
      expect(db.getSession(orphan)!['ended_at'], isNotNull);
    });

    test('closeSession is idempotent', () {
      final db = DatabaseService();
      addTearDown(() => db.db.dispose());
      db.init(path: '${tmp.path}/usage.db');

      final id = db.openSession(app: 'firefox', startedAt: 1000, idle: false);
      db.closeSession(id, 5000);
      final first = db.getSession(id)!;
      db.closeSession(id, 9000);
      final second = db.getSession(id)!;

      expect(first['ended_at'], 5000);
      expect(second['ended_at'], 5000,
          reason: 'a repeated close must not move the end time forward');
      expect(second['duration_ms'], 4000);
    });
  });
}
