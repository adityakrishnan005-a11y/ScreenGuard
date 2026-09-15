import 'dart:io';

class SoundOption {
  final String id;
  final String label;
  final String systemSoundName;

  const SoundOption({
    required this.id,
    required this.label,
    required this.systemSoundName,
  });
}

class SoundService {
  static const List<SoundOption> presets = [
    SoundOption(
      id: 'chime',
      label: 'Gentle Chime',
      systemSoundName: 'message-new-instant',
    ),
    SoundOption(
      id: 'bell',
      label: 'Classic Bell',
      systemSoundName: 'bell',
    ),
    SoundOption(
      id: 'alert',
      label: 'Digital Alert',
      systemSoundName: 'dialog-warning',
    ),
  ];

  static const List<String> supportedExtensions = ['.ogg', '.oga', '.wav', '.mp3'];

  static Future<void> playSound({
    required String soundId,
    String? customPath,
  }) async {
    try {
      if (soundId == 'custom' && customPath != null && customPath.isNotEmpty) {
        final file = File(customPath);
        if (await file.exists()) {
          final ext = customPath.toLowerCase();
          if (supportedExtensions.any((e) => ext.endsWith(e))) {
            // Try paplay first (routes through PulseAudio / PipeWire Pulse, matching preset behavior)
            var res = await Process.run('paplay', [customPath]);
            if (res.exitCode == 0) return;

            // Try ffplay (very robust across audio formats)
            res = await Process.run('ffplay', ['-nodisp', '-autoexit', '-loglevel', 'quiet', customPath]);
            if (res.exitCode == 0) return;

            // Fallback to pw-play
            res = await Process.run('pw-play', [customPath]);
            if (res.exitCode == 0) return;

            // Fallback to canberra / aplay
            res = await Process.run('canberra-gtk-play', ['-f', customPath]);
            if (res.exitCode == 0) return;

            await Process.run('aplay', [customPath]);
            return;
          }
        }
      }

      // Built-in presets
      final preset = presets.firstWhere(
        (p) => p.id == soundId,
        orElse: () => presets.first,
      );

      final soundPaths = [
        '/usr/share/sounds/freedesktop/stereo/${preset.systemSoundName}.oga',
        '/usr/share/sounds/gnome/default/alerts/${preset.systemSoundName}.ogg',
        '/usr/share/sounds/freedesktop/stereo/complete.oga',
        '/usr/share/sounds/freedesktop/stereo/bell.oga',
      ];

      for (final sp in soundPaths) {
        if (File(sp).existsSync()) {
          final paRes = await Process.run('paplay', [sp]);
          if (paRes.exitCode == 0) return;

          final pwRes = await Process.run('pw-play', [sp]);
          if (pwRes.exitCode == 0) return;
        }
      }

      // Fallback to canberra-gtk-play
      await Process.run('canberra-gtk-play', ['-i', preset.systemSoundName]);
    } catch (_) {
      // Audio execution failure is handled gracefully
    }
  }

  static Future<String?> pickAudioFile() async {
    try {
      final res = await Process.run('zenity', [
        '--file-selection',
        '--title=Select Notification Sound',
        '--file-filter=Audio files (*.ogg, *.wav, *.mp3) | *.ogg *.oga *.wav *.mp3 *.OGG *.OGA *.WAV *.MP3',
      ]);
      if (res.exitCode == 0) {
        final path = res.stdout.toString().trim();
        if (path.isNotEmpty && File(path).existsSync()) {
          final lower = path.toLowerCase();
          if (supportedExtensions.any((e) => lower.endsWith(e))) {
            return path;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
