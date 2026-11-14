import 'package:screenguard/services/db.dart';
import 'package:screenguard/services/tracker.dart';

import 'dispatch.dart';
import 'maintenance_api.dart';
import 'policy_api.dart';
import 'tracking_api.dart';
import 'transport.dart';
import 'usage_api.dart';

part 'storage_api.dart';

/// The only public entry point to ScreenGuard's data and control surfaces.
///
/// Four domains, each with a different rule:
///
/// | Domain   | Question                       | Mutation |
/// |----------|--------------------------------|----------|
/// | usage    | what happened?                 | none     |
/// | policy   | what should happen?            | yes      |
/// | tracking | is the observer running?       | control  |
/// | storage  | raw records, guarded           | daemon   |
///
/// In the GUI every call leaves the process through the native broker
/// (`/run/user/<uid>/screenguard/control.sock`), which checks the peer uid,
/// validates the envelope, takes the storage lock for mutations and forwards
/// to the daemon. The GUI keeps an in-process read-only fallback so the app
/// still works when no broker is running.
///
/// The guard is structural: [StorageApi] has a private constructor and lives
/// in this library, so [forGui] cannot build one and GUI code cannot import
/// it. Screens only ever receive `usage` and `policy`.
class ScreenGuardApi {
  ScreenGuardApi._({
    required this.usage,
    required this.policy,
    required this.maintenance,
    required this.transport,
    this.tracking,
    this.storage,
    ScreenGuardDispatch? dispatch,
  }) : _dispatch = dispatch;

  final UsageApi usage;
  final PolicyApi policy;

  /// Explicit user intents that destroy data (delete a range, forget all).
  final MaintenanceApi maintenance;

  /// Present only in the daemon process.
  final TrackingApi? tracking;

  /// Present only in the daemon process. Writes and deletes usage facts.
  final StorageApi? storage;

  /// The path requests take. Exposed for diagnostics and status screens.
  final Transport transport;

  /// The in-process table the daemon serves over its socket. Daemon only.
  final ScreenGuardDispatch? _dispatch;
  ScreenGuardDispatch? get dispatch => _dispatch;

  /// Read and edit surface for the Flutter app.
  ///
  /// No storage, no tracking: the GUI can describe intent and read aggregates,
  /// but it cannot record or destroy a session.
  factory ScreenGuardApi.forGui({
    DatabaseService? db,
    String? brokerSocket,
  }) {
    // The fallback opens SQLite only if the broker is unreachable. With a
    // broker running, this process never opens the database at all.
    final Transport fallback = db != null
        ? InProcessTransport(
            ScreenGuardDispatch(db: db, allowStorage: false),
          )
        : LocalTransport(() {
            final local = DatabaseService();
            local.init();
            return ScreenGuardDispatch(db: local, allowStorage: false);
          });
    final Transport t = AutoTransport(
      primary: BrokerTransport(socketPath: brokerSocket),
      fallback: fallback,
    );
    return ScreenGuardApi._(
      usage: UsageApi(t),
      policy: PolicyApi(t),
      maintenance: MaintenanceApi(t),
      transport: t,
    );
  }

  /// Full surface for the reconciler process.
  factory ScreenGuardApi.forDaemon({
    required DatabaseService db,
    required Tracker tracker,
  }) {
    final dispatch = ScreenGuardDispatch(db: db, tracker: tracker);
    final Transport t = InProcessTransport(dispatch);
    return ScreenGuardApi._(
      usage: UsageApi(t),
      policy: PolicyApi(t),
      tracking: TrackingApi(t),
      maintenance: MaintenanceApi(t),
      storage: StorageApi._(t),
      transport: t,
      dispatch: dispatch,
    );
  }

  bool get canRecordUsage => storage != null;
  bool get canControlTracking => tracking != null;

  /// True when the GUI's last call was answered by the native broker.
  bool get isBrokered {
    final t = transport;
    return t is BrokerTransport || (t is AutoTransport && !t.usedFallback);
  }
}
