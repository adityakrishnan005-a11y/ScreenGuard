import 'package:flutter/material.dart';
import 'package:screenguard/services/db.dart';

class ThemeService extends ChangeNotifier {
  final DatabaseService _db;
  late ThemeMode _themeMode;

  ThemeService(this._db) {
    _loadTheme();
  }

  ThemeMode get themeMode => _themeMode;

  String get themeModeString {
    switch (_themeMode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
      default:
        return 'system';
    }
  }

  void _loadTheme() {
    final mode = _db.getSetting('app_theme_mode', defaultValue: 'system');
    switch (mode) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      case 'system':
      default:
        _themeMode = ThemeMode.system;
        break;
    }
  }

  void setThemeMode(String mode) {
    _db.setSetting('app_theme_mode', mode);
    switch (mode) {
      case 'light':
        _themeMode = ThemeMode.light;
        break;
      case 'dark':
        _themeMode = ThemeMode.dark;
        break;
      case 'system':
      default:
        _themeMode = ThemeMode.system;
        break;
    }
    notifyListeners();
  }
}
