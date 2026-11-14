class WindowInfo {
  final String app;
  final String? rawClass;
  final String? title;
  final int? pid;

  const WindowInfo({
    required this.app,
    this.rawClass,
    this.title,
    this.pid,
  });

  static const WindowInfo unknown =
      WindowInfo(app: 'unknown', rawClass: 'unknown');
}

abstract class WindowBackend {
  Future<WindowInfo> getActiveWindow();
  Future<int> getIdleMs();
  Future<bool> minimizeActiveWindow();
  Future<bool> closeActiveWindow();

  /// Move focus off the currently focused window without touching it.
  ///
  /// This is the last-resort enforcement step: some windows (fullscreen games,
  /// apps that swallow the minimize request) refuse to be minimized. Switching
  /// focus to another window removes them from the user's face without
  /// destroying unsaved work, which is the whole point of the non-strict path.
  Future<bool> switchAwayFromActiveWindow();
}
