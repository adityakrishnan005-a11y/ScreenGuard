import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/app_resolver.dart';

void main() {
  group('AppResolver', () {
    late Directory tempDir;
    late AppResolver resolver;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('screenguard_resolver_test_');
      resolver = AppResolver();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('ignores [Desktop Action] sections and preserves main [Desktop Entry] Name', () {
      final desktopFile = File('${tempDir.path}/org.mozilla.firefox.desktop');
      desktopFile.writeAsStringSync('''
[Desktop Entry]
Version=1.0
Name=Firefox
StartupWMClass=firefox
Exec=firefox %u
Actions=profile-manager-window;

[Desktop Action profile-manager-window]
Name=Open the Profile Manager
Exec=firefox --ProfileManager
''');

      resolver.scanDir(tempDir.path);

      final byClass = resolver.resolve('firefox');
      expect(byClass.name, 'Firefox');

      final byBase = resolver.resolve('org.mozilla.firefox');
      expect(byBase.name, 'Firefox');
    });

    test('correctly parses Chromium desktop actions without overwriting', () {
      final desktopFile = File('${tempDir.path}/chromium-browser.desktop');
      desktopFile.writeAsStringSync('''
[Desktop Entry]
Name=Chromium Web Browser
StartupWMClass=chromium-browser
Exec=chromium-browser %U
Actions=new-private-window;

[Desktop Action new-private-window]
Name=Open a New Private Window
Exec=chromium-browser --incognito
''');

      resolver.scanDir(tempDir.path);

      final byClass = resolver.resolve('chromium-browser');
      expect(byClass.name, 'Chromium Web Browser');
    });

    test('built-in Electron override maps to friendly name', () {
      final r = AppResolver();
      expect(r.resolve('code').name, 'VS Code');
      expect(r.resolve('code-insiders').name, 'VS Code Insiders');
      expect(r.resolve('slack').name, 'Slack');
      expect(r.resolve('discord').name, 'Discord');
      expect(r.resolve('steam').name, 'Steam');
      expect(r.resolve('telegram').name, 'Telegram');
      expect(r.resolve('spotify').name, 'Spotify');
    });

    test('fallback capitalizes the raw class', () {
      final r = AppResolver();
      expect(r.resolve('com.example.foo').name, 'Foo');
      expect(r.resolve('unknown').name, 'Unknown');
    });
  });
}
