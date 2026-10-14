import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/crash_reporter.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/theme_service.dart';
import 'package:screenguard/screens/main_shell.dart';
import 'package:screenguard/screens/times_up_screen.dart';

void main(List<String> args) {
  final crashReporter = CrashReporter();

  // Catch Flutter framework errors (layout, rendering, etc.)
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    crashReporter.recordCrash(
      source: 'gui',
      error: details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
    );
  };

  // Catch all other unhandled Dart async errors
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    final db = DatabaseService();
    db.init();
    final resolver = AppResolver();
    resolver.init();
    final daemonService = DaemonService();
    final themeService = ThemeService(db);

    String? timesUpApp;
    for (final arg in args) {
      if (arg.startsWith('--times-up=')) {
        timesUpApp = arg.substring(11).trim();
      }
    }

    runApp(
      MultiProvider(
        providers: [
          Provider<DatabaseService>.value(value: db),
          Provider<CrashReporter>.value(value: crashReporter),
          ChangeNotifierProvider<DaemonService>.value(value: daemonService),
          ChangeNotifierProvider<ThemeService>.value(value: themeService),
        ],
        child: MyApp(timesUpApp: timesUpApp, resolver: resolver),
      ),
    );
  }, (error, stackTrace) {
    crashReporter.recordCrash(
      source: 'gui',
      error: error.toString(),
      stackTrace: stackTrace.toString(),
    );
  });
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
    final themeService = Provider.of<ThemeService>(context);
    Widget homeWidget = const MainShell();

    if (timesUpApp != null && timesUpApp!.isNotEmpty) {
      final meta = resolver.resolve(timesUpApp!);
      homeWidget = TimesUpScreen(
        app: timesUpApp!,
        appName: meta.name,
      );
    }

    return MaterialApp(
      title: 'ScreenGuard',
      debugShowCheckedModeBanner: false,
      themeMode: themeService.themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: homeWidget,
    );
  }
}
