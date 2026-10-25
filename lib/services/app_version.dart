/// Single source of truth for the application version.
///
/// The GUI, the daemon and the feedback service must never disagree about
/// which build is running — the version decides which update is offered and
/// which feedback request is shown.  The release pipeline may compile with
/// `-DAPP_VERSION=<version>`; when that define is missing we fall back to
/// [value] so every component still agrees.
class AppVersion {
  /// Canonical version of the current release.
  static const String value = '0.1.1';

  /// Version of the running binary.
  static const String current =
      String.fromEnvironment('APP_VERSION', defaultValue: value);
}
