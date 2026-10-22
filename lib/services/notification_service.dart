import 'dart:io';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/sound_service.dart';

/// Centralized notification service for ScreenGuard.
///
/// Unifies desktop notifications and sound cues across all features:
/// - App limits and lockouts
/// - Daily goals and overtime milestones
/// - Focus mode and break timers
/// - Update checker
///
/// Uses the native compiled C helper `screenguard-notify` via D-Bus,
/// with a safe fallback to `notify-send` if the binary is absent.
class NotificationService {
  static String? _cachedNotifyBin;

  static String? _findNotifyBinary() {
    if (_cachedNotifyBin != null && File(_cachedNotifyBin!).existsSync()) {
      return _cachedNotifyBin;
    }

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      // Adjacent to currently running executable
      '${File(Platform.resolvedExecutable).parent.path}/screenguard-notify',
      // User-local installation (install.sh default)
      '$home/.local/opt/screenguard/screenguard-notify',
      '$home/.local/bin/screenguard-notify',
      // System installation
      '/opt/screenguard/screenguard-notify',
      '/usr/local/bin/screenguard-notify',
      '/usr/bin/screenguard-notify',
      // Repository bundle dev build
      'build/linux/x64/release/bundle/screenguard-notify',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        _cachedNotifyBin = path;
        return path;
      }
    }
    return null;
  }

  /// Sends a desktop notification and plays the associated audio cue
  /// according to user preferences stored in SQLite.
  static Future<void> show({
    required DatabaseService db,
    required String eventKey,
    required String title,
    required String body,
    String icon = 'screenguard',
    String urgency = 'normal',
    int timeoutMs = 5000,
    bool playSound = true,
  }) async {
    final notifyGlobal = db.isNotificationsGloballyEnabled();
    final notifyEvent = db.isEventNotificationEnabled(eventKey);

    // 1. Desktop Notification
    if (notifyGlobal && notifyEvent) {
      try {
        final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'] ??
            '/run/user/${Platform.environment['UID'] ?? '1000'}';
        final dbusBus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ??
            'unix:path=$runtimeDir/bus';

        final bin = _findNotifyBinary();
        if (bin != null) {
          Process.run(
            bin,
            [
              '-t', title,
              '-b', body,
              '-i', icon,
              '-u', urgency,
              '-e', timeoutMs.toString(),
            ],
            environment: {
              ...Platform.environment,
              'DBUS_SESSION_BUS_ADDRESS': dbusBus,
            },
          ).then((res) {
            if (res.exitCode != 0) {
              stderr.writeln('[notify] screenguard-notify exit=${res.exitCode} err=${res.stderr}');
            } else {
              stderr.writeln('[notify] notification sent: "$title"');
            }
          }).catchError((e) {
            stderr.writeln('[notify] screenguard-notify error: $e');
          });
        } else {
          // Safe fallback to notify-send without broken desktop-entry hint
          Process.run(
            'notify-send',
            [
              title,
              body,
              '-u', urgency,
              '-i', icon,
              '-a', 'ScreenGuard',
              '-t', timeoutMs.toString(),
            ],
            environment: {
              ...Platform.environment,
              'DBUS_SESSION_BUS_ADDRESS': dbusBus,
            },
          ).then((res) {
            if (res.exitCode != 0) {
              stderr.writeln('[notify] fallback notify-send exit=${res.exitCode} err=${res.stderr}');
            }
          }).catchError((_) {});
        }
      } catch (e) {
        stderr.writeln('[notify] error dispatching notification: $e');
      }
    }

    // 2. Sound Cue
    if (playSound &&
        db.isSoundGloballyEnabled() &&
        db.isEventSoundEnabled(eventKey)) {
      try {
        final soundTheme = db.getSoundTheme();
        final customPath = db.getCustomSoundPath();
        SoundService.playSound(soundId: soundTheme, customPath: customPath);
      } catch (e) {
        stderr.writeln('[notify] error playing sound: $e');
      }
    }
  }
}
