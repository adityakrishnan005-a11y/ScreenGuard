import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:screenguard/api/screenguard_api.dart';
import 'package:screenguard/services/app_resolver.dart';
import 'package:screenguard/services/crash_reporter.dart';
import 'package:screenguard/services/daemon_service.dart';
import 'package:screenguard/services/theme_service.dart';
import 'package:screenguard/screens/main_shell.dart';
import 'package:screenguard/screens/times_up_screen.dart';
import 'package:screenguard/screens/focus_block_screen.dart';

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

    // No database handle here: every read and write leaves through the native
    // broker. The API opens SQLite itself only if no broker is running.
    final api = ScreenGuardApi.forGui();
    final resolver = AppResolver();
    resolver.init();
    final daemonService = DaemonService();
    final themeService = ThemeService(api.policy);

    String? timesUpApp;
    String? focusBlockApp;
    int? focusBlockPid;
    for (final arg in args) {
      if (arg.startsWith('--times-up=')) {
        timesUpApp = arg.substring(11).trim();
      } else if (arg.startsWith('--focus-block=')) {
        focusBlockApp = arg.substring(14).trim();
      } else if (arg.startsWith('--pid=')) {
        focusBlockPid = int.tryParse(arg.substring(6).trim());
      }
    }

    runApp(
      MultiProvider(
        providers: [
          Provider<ScreenGuardApi>.value(value: api),
          Provider<CrashReporter>.value(value: crashReporter),
          ChangeNotifierProvider<DaemonService>.value(value: daemonService),
          ChangeNotifierProvider<ThemeService>.value(value: themeService),
        ],
        child: MyApp(
          timesUpApp: timesUpApp,
          focusBlockApp: focusBlockApp,
          focusBlockPid: focusBlockPid,
          resolver: resolver,
        ),
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
  final String? focusBlockApp;
  final int? focusBlockPid;
  final AppResolver resolver;

  const MyApp({
    super.key,
    this.timesUpApp,
    this.focusBlockApp,
    this.focusBlockPid,
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
        pid: focusBlockPid,
      );
    } else if (focusBlockApp != null && focusBlockApp!.isNotEmpty) {
      final meta = resolver.resolve(focusBlockApp!);
      homeWidget = FocusBlockScreen(
        app: focusBlockApp!,
        appName: meta.name,
        pid: focusBlockPid,
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
