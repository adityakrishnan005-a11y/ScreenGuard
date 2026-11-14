import 'dart:convert';
import 'dart:io';

import 'dispatch.dart';
import 'sync_unix_socket.dart';
import 'wire.dart';

/// Anything that can answer a `<domain> <method> <json>` request.
///
/// The daemon answers in-process. The GUI answers through the native broker,
/// which owns the socket, the uid check and the routing table. Both paths use
/// the same [ScreenGuardDispatch], so a method cannot behave differently
/// depending on which side of the boundary it was called from.
abstract class Transport {
  Object? call(String domain, String method, Map<String, Object?> args);
}

/// A request the transport could not deliver or the daemon refused.
class TransportException implements Exception {
  TransportException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// `/run/user/<uid>` when the session provides it, else a per-uid directory
/// under /tmp. The broker uses the exact same rule, so both sides agree.
String runtimeDirectory() {
  final env = Platform.environment['XDG_RUNTIME_DIR'];
  if (env != null && env.isNotEmpty) return '$env/screenguard';
  var uid = Platform.environment['UID'];
  if (uid == null || uid.isEmpty) {
    try {
      final r = Process.runSync('id', const ['-u']);
      uid = (r.stdout as String).trim();
    } catch (_) {
      uid = '0';
    }
  }
  return '/tmp/screenguard-$uid';
}

String brokerSocketPath() => '${runtimeDirectory()}/control.sock';
String daemonSocketPath() => '${runtimeDirectory()}/daemon.sock';

/// Answers requests by calling the dispatch table directly. Used by the
/// daemon, and by the GUI only as a fallback when no broker is running.
class InProcessTransport implements Transport {
  InProcessTransport(this.dispatch);
  final ScreenGuardDispatch dispatch;

  @override
  Object? call(String domain, String method, Map<String, Object?> args) {
    try {
      return dispatch.call(domain, method, args);
    } on DispatchException catch (e) {
      throw TransportException(e.reason);
    }
  }
}

/// Answers requests by opening the dispatch table on first use. The GUI uses
/// this so it does not touch SQLite at all while the broker is serving it.
class LocalTransport implements Transport {
  LocalTransport(this._open);

  final ScreenGuardDispatch Function() _open;
  ScreenGuardDispatch? _dispatch;

  @override
  Object? call(String domain, String method, Map<String, Object?> args) {
    final dispatch = _dispatch ??= _open();
    try {
      return dispatch.call(domain, method, args);
    } on DispatchException catch (e) {
      throw TransportException(e.reason);
    }
  }
}

/// A blocking unix-socket client. Synchronous on purpose: the domain façade
/// is synchronous, and a local socket round trip costs microseconds.
class BrokerTransport implements Transport {
  BrokerTransport({String? socketPath})
      : socketPath = socketPath ?? brokerSocketPath();

  final String socketPath;

  @override
  Object? call(String domain, String method, Map<String, Object?> args) {
    final request = '$domain $method ${encodeWire(args)}\n';

    SyncUnixSocket socket;
    try {
      socket = SyncUnixSocket.connect(socketPath);
    } on SyncSocketException catch (e) {
      // The broker socket itself is not there. Distinct from "the broker is
      // up but the daemon is down": only this one may be bypassed.
      throw TransportException(
        isUnreachableErrno(e.errno) ? 'broker-unreachable' : 'broker-connect-failed',
      );
    }

    try {
      socket.writeAll(utf8.encode(request));

      final acc = <int>[];
      var complete = false;
      while (acc.length < 4 * 1024 * 1024 && !complete) {
        final chunk = socket.readSome(65536);
        if (chunk.isEmpty) break;
        for (final byte in chunk) {
          if (byte == 0x0a) {
            complete = true;
            break;
          }
          acc.add(byte);
        }
      }
      if (acc.isEmpty) throw TransportException('empty-response');
      if (acc.isNotEmpty && acc.last == 0x0d) acc.removeLast();
      final line = utf8.decode(acc, allowMalformed: true);

      if (line.startsWith('ok ')) {
        return decodeWire(line.substring(3));
      }
      if (line.startsWith('ok')) return null;
      if (line.startsWith('err ')) {
        throw TransportException(line.substring(4));
      }
      throw TransportException('malformed-response');
    } on TransportException {
      rethrow;
    } on SyncSocketException catch (e) {
      throw TransportException(isTimeoutErrno(e.errno) ? 'broker-timeout' : 'transport-failed');
    } catch (_) {
      throw TransportException('transport-failed');
    } finally {
      socket.close();
    }
  }
}

/// Tries the broker first. Only when the broker *socket* is missing does it
/// answer from the in-process dispatch, so the app keeps working on installs
/// that predate the broker or while nothing is running.
///
/// A broker that is up but whose daemon is down is never bypassed: the honest
/// answer is `err daemon-unavailable`, not a silent read of the database
/// behind the daemon's back.
class AutoTransport implements Transport {
  AutoTransport({required this.primary, required this.fallback});

  final Transport primary;
  final Transport fallback;

  /// Whether the most recent call was answered in-process. Starts true: until
  /// a call actually succeeds through the broker, nothing is brokered.
  bool usedFallback = true;

  @override
  Object? call(String domain, String method, Map<String, Object?> args) {
    try {
      final result = primary.call(domain, method, args);
      usedFallback = false;
      return result;
    } on TransportException catch (e) {
      if (e.reason != 'broker-unreachable') rethrow;
    }
    usedFallback = true;
    return fallback.call(domain, method, args);
  }
}
