import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/db.dart';

DatabaseService _tempDb() {
  final dir = Directory.systemTemp.createTempSync();
  final db = DatabaseService();
  db.init(path: '${dir.path}/usage.db');
  return db;
}

void main() {
  test('openSession + closeSession computes duration', () {
    final db = _tempDb();
    final id = db.openSession(
      app: 'a', appName: 'A', startedAt: 1000, idle: false);
    db.closeSession(id, 5000);
    final rows = db.db.select('SELECT * FROM sessions WHERE id = ?', [id]);
    expect(rows.length, 1);
    expect(rows.first['duration_ms'], 4000);
    expect(rows.first['ended_at'], 5000);
    expect(rows.first['idle'], 0);
    db.close();
  });

  test('todayTotalMs sums only active (idle=0) sessions for today', () {
    final db = _tempDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.openSession(app: 'a', appName: 'A', startedAt: now - 1000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    db.openSession(app: 'b', appName: 'B', startedAt: now - 2000, idle: true);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    db.openSession(app: 'c', appName: 'C', startedAt: now - 3000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    final total = db.todayTotalMs();
    // a=1000ms + c=3000ms active; b is idle and excluded
    expect(total, 4000);
    db.close();
  });

  test('perAppToday groups by app and orders by time desc', () {
    final db = _tempDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.openSession(app: 'a', appName: 'A', startedAt: now - 1000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    db.openSession(app: 'b', appName: 'B', startedAt: now - 5000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    final rows = db.perAppToday();
    expect(rows.length, 2);
    expect(rows.first['app'], 'b');
    expect(rows.first['t'], 5000);
    expect(rows.last['app'], 'a');
    expect(rows.last['t'], 1000);
    db.close();
  });

  test('yesterdayTotalMs is 0 for sessions created today', () {
    final db = _tempDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.openSession(app: 'a', appName: 'A', startedAt: now - 1000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    expect(db.yesterdayTotalMs(), 0);
    db.close();
  });

  test('last7Days and appHistory aggregate by day', () {
    final db = _tempDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    db.openSession(app: 'a', appName: 'A', startedAt: now - 1000, idle: false);
    db.closeSession(db.db.select('SELECT last_insert_rowid() AS i').first['i'] as int, now);
    final week = db.last7Days();
    expect(week.length, 7);
    final hist = db.appHistory('a');
    expect(hist.length, 1);
    db.close();
  });

  test('getDailyGoalMs defaults to 0 and persists custom goal', () {
    final db = _tempDb();
    expect(db.getDailyGoalMs(), 0);
    db.setDailyGoalMs(4 * 3600 * 1000);
    expect(db.getDailyGoalMs(), 4 * 3600 * 1000);
    db.setDailyGoalMs(0);
    expect(db.getDailyGoalMs(), 0);
    db.close();
  });

  test('notification and sound settings persistence', () {
    final db = _tempDb();
    // Default values
    expect(db.isNotificationsGloballyEnabled(), true);
    expect(db.isSoundGloballyEnabled(), true);
    expect(db.getSoundTheme(), 'chime');
    expect(db.getCustomSoundPath(), '');
    expect(db.isEventNotificationEnabled('daily_goal_50'), true);
    expect(db.isEventSoundEnabled('daily_goal_50'), true);

    // Modify settings
    db.setNotificationsGloballyEnabled(false);
    expect(db.isNotificationsGloballyEnabled(), false);

    db.setSoundGloballyEnabled(false);
    expect(db.isSoundGloballyEnabled(), false);

    db.setSoundTheme('custom');
    expect(db.getSoundTheme(), 'custom');

    db.setCustomSoundPath('/home/user/sound.ogg');
    expect(db.getCustomSoundPath(), '/home/user/sound.ogg');

    db.setEventNotificationEnabled('daily_goal_50', false);
    expect(db.isEventNotificationEnabled('daily_goal_50'), false);

    db.setEventSoundEnabled('daily_goal_50', false);
    expect(db.isEventSoundEnabled('daily_goal_50'), false);

    db.close();
  });
}
