import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/db.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  DatabaseService openDb() {
    final service = DatabaseService();
    service.init(path: dbPath);
    return service;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('screenguard_profiles_');
    dbPath = '${tempDir.path}/usage.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('fresh database seeds the two default focus modes', () {
    final db = openDb();
    addTearDown(db.db.dispose);

    final profiles = db.getFocusProfiles();
    expect(profiles.length, 2);
    expect(profiles[0]['name'], 'Me time');
    expect(profiles[1]['name'], 'Work time');
    expect(profiles[0]['is_default'], 1);
    expect(profiles[1]['is_default'], 1);
    expect(db.getActiveFocusProfileId(), profiles[0]['id']);
  });

  test('legacy blocklist is copied into Me time on migration', () {
    final first = openDb();
    first.db.execute('DELETE FROM focus_profile_apps;');
    first.db.execute('DELETE FROM focus_profiles;');
    first.db.execute('DELETE FROM distracting_apps;');
    first.db.execute(
      "INSERT INTO distracting_apps (app) VALUES ('firefox'), ('steam');",
    );
    first.db.dispose();

    final migrated = openDb();
    addTearDown(migrated.db.dispose);

    final me = migrated.getFocusProfiles().first;
    expect(me['name'], 'Me time');
    expect(
      migrated.getFocusProfileApps(me['id'] as int),
      {'firefox', 'steam'},
    );
  });

  test('each focus mode keeps its own app list', () {
    final db = openDb();
    addTearDown(db.db.dispose);

    final profiles = db.getFocusProfiles();
    final meId = profiles[0]['id'] as int;
    final workId = profiles[1]['id'] as int;

    db.toggleFocusProfileApp(meId, 'spotify');
    db.toggleFocusProfileApp(workId, 'slack');
    db.toggleFocusProfileApp(workId, 'steam');

    expect(db.getFocusProfileApps(meId), {'spotify'});
    expect(db.getFocusProfileApps(workId), {'slack', 'steam'});

    db.toggleFocusProfileApp(workId, 'slack');
    expect(db.getFocusProfileApps(workId), {'steam'});
  });

  test('profile duration, cycles and break are persisted independently', () {
    final db = openDb();
    addTearDown(db.db.dispose);

    final profiles = db.getFocusProfiles();
    final meId = profiles[0]['id'] as int;
    final workId = profiles[1]['id'] as int;

    db.updateFocusProfile(
      meId,
      durationMinutes: 15,
      customDurationMinutes: 15,
      totalCycles: 2,
      breakMinutes: 3,
    );
    db.updateFocusProfile(
      workId,
      durationMinutes: 50,
      customDurationMinutes: 50,
      totalCycles: 5,
      breakMinutes: 10,
    );

    final me = db.getFocusProfile(meId)!;
    final work = db.getFocusProfile(workId)!;
    expect(me['duration_minutes'], 15);
    expect(me['total_cycles'], 2);
    expect(me['break_minutes'], 3);
    expect(work['duration_minutes'], 50);
    expect(work['total_cycles'], 5);
    expect(work['break_minutes'], 10);
  });

  test('custom modes can be added, renamed and deleted; defaults cannot', () {
    final db = openDb();
    addTearDown(db.db.dispose);

    final defaultId = db.getFocusProfiles().first['id'] as int;
    db.deleteFocusProfile(defaultId);
    expect(db.getFocusProfiles().length, 2);

    final id = db.addFocusProfile('Study', icon: 'school');
    expect(db.getFocusProfile(id)!['name'], 'Study');
    expect(db.getFocusProfile(id)!['icon'], 'school');
    expect(db.getFocusProfile(id)!['is_default'], 0);

    db.updateFocusProfile(id, name: 'Deep Study', icon: 'menu_book');
    expect(db.getFocusProfile(id)!['name'], 'Deep Study');
    expect(db.getFocusProfile(id)!['icon'], 'menu_book');

    db.deleteFocusProfile(id);
    expect(db.getFocusProfile(id), isNull);
  });

  test('starting a session syncs the mode blocklist and settings', () {
    final db = openDb();
    addTearDown(db.db.dispose);

    final workId = db.getFocusProfiles()[1]['id'] as int;
    db.setPomodoroLoopEnabled(true);
    db.updateFocusProfile(workId, totalCycles: 3, breakMinutes: 7);
    db.toggleFocusProfileApp(workId, 'steam');
    db.toggleFocusProfileApp(workId, 'discord');

    db.startFocusSession(45, profileId: workId);

    final state = db.getActiveFocusState();
    expect(state, isNotNull);
    expect(state!['profile_id'], workId);
    expect(state['duration_minutes'], 45);
    expect(state['total_cycles'], 3);
    expect(state['break_duration_minutes'], 7);
    expect(db.getDistractingApps(), {'steam', 'discord'});
    expect(db.getActiveFocusProfileId(), workId);
  });

  test('selecting a mode persists across service restarts', () {
    final first = openDb();
    final workId = first.getFocusProfiles()[1]['id'] as int;
    first.setActiveFocusProfile(workId);
    first.db.dispose();

    final second = openDb();
    addTearDown(second.db.dispose);
    expect(second.getActiveFocusProfileId(), workId);
  });
}
