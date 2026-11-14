import 'transport.dart';

/// **Policy** — intent, read/write.
///
/// Everything here expresses what the user decided *should* happen: limits,
/// focus sessions, goals, notification preferences. Policy is not observation;
/// nothing here reads the window or the clock.
class PolicyApi {
  PolicyApi(this._t);

  final Transport _t;

  /// Mirrors `DatabaseService.getAppLimit`.
  Map<String, dynamic>? getAppLimit(String app, {List<String>? aliases}) =>
      _t.call('policy', 'getAppLimit', {'app': app, 'aliases': aliases}) as Map<String,dynamic>?;

  /// Mirrors `DatabaseService.setAppLimit`.
  void setAppLimit(String app, int limitMs, {bool enabled = true}) =>
      _t.call('policy', 'setAppLimit', {'app': app, 'limitMs': limitMs, 'enabled': enabled});

  /// Mirrors `DatabaseService.addTempExtension`.
  void addTempExtension(String app, int extensionMs) =>
      _t.call('policy', 'addTempExtension', {'app': app, 'extensionMs': extensionMs});

  /// Mirrors `DatabaseService.deleteAppLimit`.
  void deleteAppLimit(String app) =>
      _t.call('policy', 'deleteAppLimit', {'app': app});

  /// Mirrors `DatabaseService.getDistractingApps`.
  Set<String> getDistractingApps() =>
      (_t.call('policy', 'getDistractingApps', const {}) as List).cast<String>().toSet();

  /// Mirrors `DatabaseService.toggleDistractingApp`.
  void toggleDistractingApp(String app) =>
      _t.call('policy', 'toggleDistractingApp', {'app': app});

  /// Mirrors `DatabaseService.isDistractingApp`.
  bool isDistractingApp(String app, {List<String>? aliases}) =>
      _t.call('policy', 'isDistractingApp', {'app': app, 'aliases': aliases}) as bool;

  /// Mirrors `DatabaseService.startFocusSession`.
  void startFocusSession(int durationMinutes, {int? totalCycles, int? breakMinutes}) =>
      _t.call('policy', 'startFocusSession', {'durationMinutes': durationMinutes, 'totalCycles': totalCycles, 'breakMinutes': breakMinutes});

  /// Mirrors `DatabaseService.pauseFocusSession`.
  void pauseFocusSession() =>
      _t.call('policy', 'pauseFocusSession', const {});

  /// Mirrors `DatabaseService.resumeFocusSession`.
  void resumeFocusSession() =>
      _t.call('policy', 'resumeFocusSession', const {});

  /// Mirrors `DatabaseService.getActiveFocusState`.
  Map<String, dynamic>? getActiveFocusState() =>
      _t.call('policy', 'getActiveFocusState', const {}) as Map<String,dynamic>?;

  /// Mirrors `DatabaseService.cancelFocusSession`.
  void cancelFocusSession() =>
      _t.call('policy', 'cancelFocusSession', const {});

  /// Mirrors `DatabaseService.getDailyGoalMs`.
  int getDailyGoalMs() =>
      _t.call('policy', 'getDailyGoalMs', const {}) as int;

  /// Mirrors `DatabaseService.setDailyGoalMs`.
  void setDailyGoalMs(int goalMs) =>
      _t.call('policy', 'setDailyGoalMs', {'goalMs': goalMs});

  /// Mirrors `DatabaseService.getSetting`.
  String getSetting(String key, {String defaultValue = ''}) =>
      _t.call('policy', 'getSetting', {'key': key, 'defaultValue': defaultValue}) as String;

  /// Mirrors `DatabaseService.setSetting`.
  void setSetting(String key, String value) =>
      _t.call('policy', 'setSetting', {'key': key, 'value': value});

  /// Mirrors `DatabaseService.isNotificationsGloballyEnabled`.
  bool isNotificationsGloballyEnabled() =>
      _t.call('policy', 'isNotificationsGloballyEnabled', const {}) as bool;

  /// Mirrors `DatabaseService.setNotificationsGloballyEnabled`.
  void setNotificationsGloballyEnabled(bool enabled) =>
      _t.call('policy', 'setNotificationsGloballyEnabled', {'enabled': enabled});

  /// Mirrors `DatabaseService.isSoundGloballyEnabled`.
  bool isSoundGloballyEnabled() =>
      _t.call('policy', 'isSoundGloballyEnabled', const {}) as bool;

  /// Mirrors `DatabaseService.setSoundGloballyEnabled`.
  void setSoundGloballyEnabled(bool enabled) =>
      _t.call('policy', 'setSoundGloballyEnabled', {'enabled': enabled});

  /// Mirrors `DatabaseService.getSoundTheme`.
  String getSoundTheme() =>
      _t.call('policy', 'getSoundTheme', const {}) as String;

  /// Mirrors `DatabaseService.setSoundTheme`.
  void setSoundTheme(String theme) =>
      _t.call('policy', 'setSoundTheme', {'theme': theme});

  /// Mirrors `DatabaseService.getCustomSoundPath`.
  String getCustomSoundPath() =>
      _t.call('policy', 'getCustomSoundPath', const {}) as String;

  /// Mirrors `DatabaseService.setCustomSoundPath`.
  void setCustomSoundPath(String path) =>
      _t.call('policy', 'setCustomSoundPath', {'path': path});

  /// Mirrors `DatabaseService.isEventNotificationEnabled`.
  bool isEventNotificationEnabled(String eventKey) =>
      _t.call('policy', 'isEventNotificationEnabled', {'eventKey': eventKey}) as bool;

  /// Mirrors `DatabaseService.setEventNotificationEnabled`.
  void setEventNotificationEnabled(String eventKey, bool enabled) =>
      _t.call('policy', 'setEventNotificationEnabled', {'eventKey': eventKey, 'enabled': enabled});

  /// Mirrors `DatabaseService.isEventSoundEnabled`.
  bool isEventSoundEnabled(String eventKey) =>
      _t.call('policy', 'isEventSoundEnabled', {'eventKey': eventKey}) as bool;

  /// Mirrors `DatabaseService.setEventSoundEnabled`.
  void setEventSoundEnabled(String eventKey, bool enabled) =>
      _t.call('policy', 'setEventSoundEnabled', {'eventKey': eventKey, 'enabled': enabled});

  /// Mirrors `DatabaseService.isPomodoroLoopEnabled`.
  bool isPomodoroLoopEnabled() =>
      _t.call('policy', 'isPomodoroLoopEnabled', const {}) as bool;

  /// Mirrors `DatabaseService.setPomodoroLoopEnabled`.
  void setPomodoroLoopEnabled(bool enabled) =>
      _t.call('policy', 'setPomodoroLoopEnabled', {'enabled': enabled});

  /// Mirrors `DatabaseService.isFocusStrictAutoclose`.
  bool isFocusStrictAutoclose() =>
      _t.call('policy', 'isFocusStrictAutoclose', const {}) as bool;

  /// Mirrors `DatabaseService.setFocusStrictAutoclose`.
  void setFocusStrictAutoclose(bool enabled) =>
      _t.call('policy', 'setFocusStrictAutoclose', {'enabled': enabled});

  /// Mirrors `DatabaseService.isFocusAppGridLayout`.
  bool isFocusAppGridLayout() =>
      _t.call('policy', 'isFocusAppGridLayout', const {}) as bool;

  /// Mirrors `DatabaseService.setFocusAppGridLayout`.
  void setFocusAppGridLayout(bool grid) =>
      _t.call('policy', 'setFocusAppGridLayout', {'grid': grid});

  /// Mirrors `DatabaseService.getFocusGraceUntilMs`.
  int getFocusGraceUntilMs(String app) =>
      _t.call('policy', 'getFocusGraceUntilMs', {'app': app}) as int;

  /// Mirrors `DatabaseService.setFocusGraceMinutes`.
  void setFocusGraceMinutes(String app, int minutes) =>
      _t.call('policy', 'setFocusGraceMinutes', {'app': app, 'minutes': minutes});

  /// Mirrors `DatabaseService.isFocusGraceActive`.
  bool isFocusGraceActive(String app) =>
      _t.call('policy', 'isFocusGraceActive', {'app': app}) as bool;

  /// Mirrors `DatabaseService.getPomodoroCyclesCount`.
  int getPomodoroCyclesCount() =>
      _t.call('policy', 'getPomodoroCyclesCount', const {}) as int;

  /// Mirrors `DatabaseService.setPomodoroCyclesCount`.
  void setPomodoroCyclesCount(int count) =>
      _t.call('policy', 'setPomodoroCyclesCount', {'count': count});

  /// Mirrors `DatabaseService.getPomodoroBreakMinutes`.
  int getPomodoroBreakMinutes() =>
      _t.call('policy', 'getPomodoroBreakMinutes', const {}) as int;

  /// Mirrors `DatabaseService.setPomodoroBreakMinutes`.
  void setPomodoroBreakMinutes(int minutes) =>
      _t.call('policy', 'setPomodoroBreakMinutes', {'minutes': minutes});

  /// Mirrors `DatabaseService.hasNotifiedDailyMilestone`.
  bool hasNotifiedDailyMilestone(String milestoneKey, String dateKey) =>
      _t.call('policy', 'hasNotifiedDailyMilestone', {'milestoneKey': milestoneKey, 'dateKey': dateKey}) as bool;

  /// Mirrors `DatabaseService.markDailyMilestoneNotified`.
  void markDailyMilestoneNotified(String milestoneKey, String dateKey) =>
      _t.call('policy', 'markDailyMilestoneNotified', {'milestoneKey': milestoneKey, 'dateKey': dateKey});

  /// Mirrors `DatabaseService.getOvertimeMilestoneIndex`.
  int getOvertimeMilestoneIndex(String dateKey) =>
      _t.call('policy', 'getOvertimeMilestoneIndex', {'dateKey': dateKey}) as int;

  /// Mirrors `DatabaseService.setOvertimeMilestoneIndex`.
  void setOvertimeMilestoneIndex(String dateKey, int index) =>
      _t.call('policy', 'setOvertimeMilestoneIndex', {'dateKey': dateKey, 'index': index});
}
