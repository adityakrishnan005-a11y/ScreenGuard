import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenguard/services/app_resolver.dart';

void main() {
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

  test('resolves .desktop Name via StartupWMClass', () {
    final dir = Directory.systemTemp.createTempSync();
    File('${dir.path}/myapp.desktop').writeAsStringSync('''
[Desktop Entry]
Name=My Cool App
StartupWMClass=myapp
Icon=myapp
''');
    final r = AppResolver();
    r.scanDir(dir.path);
    expect(r.resolve('myapp').name, 'My Cool App');
    dir.deleteSync(recursive: true);
  });

  test('falls back to desktop filename when no StartupWMClass', () {
    final dir = Directory.systemTemp.createTempSync();
    File('${dir.path}/firefox.desktop').writeAsStringSync('''
[Desktop Entry]
Name=Firefox Web Browser
''');
    final r = AppResolver();
    r.scanDir(dir.path);
    expect(r.resolve('firefox').name, 'Firefox Web Browser');
    dir.deleteSync(recursive: true);
  });

  test('fallback capitalizes the raw class', () {
    final r = AppResolver();
    expect(r.resolve('com.example.foo').name, 'Foo');
    expect(r.resolve('unknown').name, 'Unknown');
  });
}
