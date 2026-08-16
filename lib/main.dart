import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/screens/main_shell.dart';
import 'package:screenguard/screens/times_up_screen.dart';

void main(List<String> args) {
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
