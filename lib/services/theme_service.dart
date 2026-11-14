import 'package:flutter/material.dart';
import 'package:screenguard/api/policy_api.dart';

class ThemeService extends ChangeNotifier {
  final PolicyApi _policy;
  late ThemeMode _themeMode;

  ThemeService(this._policy) {
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
        return 'system';
    }
  }

  void _loadTheme() {
    final mode = _policy.getSetting('app_theme_mode', defaultValue: 'system');
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
    _policy.setSetting('app_theme_mode', mode);
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
