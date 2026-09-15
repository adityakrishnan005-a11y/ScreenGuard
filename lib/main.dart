import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/screens/main_shell.dart';
import 'package:screenguard/screens/times_up_screen.dart';

/// Resolve the tracker daemon binary: first next to the running GUI binary
/// (tarball installs), then the packaged location, then PATH.
String _resolveDaemonPath() {
  try {
    final guiDir = File(Platform.resolvedExecutable).parent;
    final sibling = File(
        '${guiDir.path}${Platform.pathSeparator}screenguard-daemon');
    if (sibling.existsSync()) return sibling.path;
  } catch (_) {}
  if (File('/usr/bin/screenguard-daemon').existsSync()) {
    return '/usr/bin/screenguard-daemon';
  }
  return 'screenguard-daemon';
}

void _ensureDaemonRunning() {
  try {
    final res = Process.runSync('systemctl', ['--user', 'is-active', 'screenguard.service']);
    if (res.exitCode == 0 && (res.stdout as String).trim() == 'active') {
      return;
    }
    final startRes = Process.runSync('systemctl', ['--user', 'start', 'screenguard.service']);
    if (startRes.exitCode == 0) return;
  } catch (_) {}

  try {
    final pgrepRes = Process.runSync('pgrep', ['-f', 'screenguard-daemon']);
    if (pgrepRes.exitCode == 0 && (pgrepRes.stdout as String).trim().isNotEmpty) {
      return;
    }
    Process.start(_resolveDaemonPath(), [], mode: ProcessStartMode.detached);
  } catch (_) {}
}

void main(List<String> args) {
  _ensureDaemonRunning();
  final db = DatabaseService();
  db.init();
  final resolver = AppResolver();
  resolver.init();

  String? timesUpApp;
  for (final arg in args) {
    if (arg.startsWith('--times-up=')) {
      timesUpApp = arg.substring(11).trim();
    }
  }

  runApp(
    Provider<DatabaseService>.value(
      value: db,
      child: MyApp(timesUpApp: timesUpApp, resolver: resolver),
    ),
  );
}

class MyApp extends StatelessWidget {
  final String? timesUpApp;
  final AppResolver resolver;

  const MyApp({
    super.key,
    this.timesUpApp,
    required this.resolver,
  });

  @override
  Widget build(BuildContext context) {
    Widget homeWidget = const MainShell();

    if (timesUpApp != null && timesUpApp!.isNotEmpty) {
      final meta = resolver.resolve(timesUpApp!);
      homeWidget = TimesUpScreen(
        app: timesUpApp!,
        appName: meta.name,
      );
    }

    return MaterialApp(
      title: 'ScreenGuard — Digital Wellbeing for Linux',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
      ),
      home: homeWidget,
    );
  }
}
