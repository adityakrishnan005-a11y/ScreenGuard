import 'transport.dart';

/// **Maintenance** — user-initiated data management.
///
/// These are the only destructive operations a screen may ask for: "show me
/// how big my data is", "forget this date range", "forget everything". They
/// travel in the `storage` domain so the broker's storage lock serialises them
/// against the daemon, but they are not the raw `StorageApi`: no screen can
/// open, close or silently rewrite a session record.
class MaintenanceApi {
  MaintenanceApi(this._t);

  final Transport _t;

  int databaseFileSize() =>
      _t.call('storage', 'databaseFileSize', const {}) as int;

  int sessionCount() => _t.call('storage', 'sessionCount', const {}) as int;

  /// Where the facts live on disk, for the "your data" panel.
  String databaseFilePath() =>
      _t.call('storage', 'databaseFilePath', const {}) as String;

  int deleteSessionsInRange(DateTime from, DateTime to) => _t.call(
        'storage',
        'deleteSessionsInRange',
        {
          'from': from.millisecondsSinceEpoch,
          'to': to.millisecondsSinceEpoch,
        },
      ) as int;

  int deleteSessionsOnDates(Iterable<DateTime> days) => _t.call(
        'storage',
        'deleteSessionsOnDates',
        {'days': days.map((d) => d.millisecondsSinceEpoch).toList()},
      ) as int;

  int clearAllUsageData() =>
      _t.call('storage', 'clearAllUsageData', const {}) as int;
}
