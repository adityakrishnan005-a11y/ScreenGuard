import 'dart:io';

/// Lifecycle of the two kiosk windows (`--times-up=` and `--focus-block=`).
///
/// The runner (`linux/runner/my_application.cc`) turns those launches into an
/// X11 override-redirect overlay: no title bar, no window-manager frame, kept
/// above the offending app every second. The overlay only makes sense while
/// the lockout condition holds, because there is no way to give an
/// override-redirect window back to the window manager once it is mapped.
///
/// So leaving the lockout ends the process instead of navigating inside it.
/// The daemon relaunches the lockout window on the next poll if the condition
/// is still true, which is exactly the relentless behaviour the lockout wants.
class LockoutWindow {
  LockoutWindow._();

  /// Leave the lockout and show the normal app (if it is installed).
  static void toDashboard() {
    try {
      Process.start(
        Platform.resolvedExecutable,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // No usable executable path (e.g. tests): exiting is still correct.
    }
    exit(0);
  }

  /// End this lockout window. The daemon decides whether to show another.
  static void close() => exit(0);
}
