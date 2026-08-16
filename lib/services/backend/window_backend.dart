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
}
