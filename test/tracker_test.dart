import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/tracker.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/backend/window_backend.dart';

DatabaseService _tempDb() {
  final dir = Directory.systemTemp.createTempSync();
  final db = DatabaseService();
  db.init(path: '${dir.path}/usage.db');
  return db;
}

class FakeBackend implements WindowBackend {
  @override
  Future<WindowInfo> getActiveWindow() async =>
      const WindowInfo(app: 'fake', rawClass: 'fake', title: null, pid: 1);

  @override
  Future<int> getIdleMs() async => 0;

  @override
  Future<bool> minimizeActiveWindow() async => true;
}

void main() {
  test('app change closes previous session and opens a new one', () {
    final db = _tempDb();
    final t = Tracker(db: db, resolver: AppResolver());
    t.handle('a', 'ta', 1, false);
    t.handle('b', 'tb', 2, false);
    final rows = db.db.select('SELECT app, ended_at FROM sessions ORDER BY id');
    expect(rows.length, 2);
    expect(rows[0]['app'], 'a');
    expect(rows[0]['ended_at'] != null, isTrue);
    expect(rows[1]['app'], 'b');
    expect(rows[1]['ended_at'] == null, isTrue);
    db.close();
  });

  test('idle flip closes and reopens with idle flag set', () {
    final db = _tempDb();
    final t = Tracker(db: db, resolver: AppResolver());
    t.handle('a', null, 1, false);
    t.handle('a', null, 1, true);
    final rows =
        db.db.select('SELECT app, idle, ended_at FROM sessions ORDER BY id');
    expect(rows.length, 2);
    expect(rows[0]['idle'], 0);
    expect(rows[0]['ended_at'] != null, isTrue);
    expect(rows[1]['idle'], 1);
    expect(rows[1]['ended_at'] == null, isTrue);
    db.close();
  });

  test('no change keeps a single open session', () {
    final db = _tempDb();
    final t = Tracker(db: db, resolver: AppResolver());
    t.handle('a', null, 1, false);
    t.handle('a', null, 1, false);
    final rows = db.db.select('SELECT * FROM sessions');
    expect(rows.length, 1);
    expect(rows.first['ended_at'] == null, isTrue);
    db.close();
  });

  test('backend can be injected', () {
    final db = _tempDb();
    final fake = FakeBackend();
    final t = Tracker(db: db, resolver: AppResolver(), backend: fake);
    expect(t.backend, fake);
    db.close();
  });
}
