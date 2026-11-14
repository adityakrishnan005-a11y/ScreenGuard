import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dispatch.dart';
import 'transport.dart' show daemonSocketPath;
import 'wire.dart';

/// The backend the native broker forwards to.
///
/// The real boundary is in C: the broker owns the world-facing socket
/// (`control.sock`), checks `SO_PEERCRED`, validates the envelope, holds the
/// storage lock and already runs as the right uid. This server therefore
/// listens on a private path inside a 0700 runtime directory, accepts one
/// request per connection, and turns the line into a dispatch call.
///
/// Wire format (identical to the broker's):
///
///   request   `<domain> <method> <json-args>`
///   response  `ok <json>`
///             `err <reason>`
class DaemonServer {
  DaemonServer({required this.dispatch, String? socketPath})
      : socketPath = socketPath ?? daemonSocketPath();

  final ScreenGuardDispatch dispatch;
  final String socketPath;

  ServerSocket? _server;
  bool get isRunning => _server != null;

  Future<void> start() async {
    final dir = Directory(File(socketPath).parent.path);
    try {
      dir.createSync(recursive: true);
      _chmod(dir.path, '700');
    } catch (e) {
      stderr.writeln('[daemon-server] cannot prepare ${dir.path}: $e');
      rethrow;
    }

    // A crashed daemon leaves its socket behind; bind() would then fail.
    try {
      if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    } catch (_) {}

    _server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    _chmod(socketPath, '600');
    _server!.listen(_handle, onError: (Object _) {});
    stderr.writeln('[daemon-server] listening on $socketPath');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    try {
      if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    } catch (_) {}
  }

  Future<void> _handle(Socket socket) async {
    final buffer = <int>[];
    try {
      await for (final chunk in socket) {
        buffer.addAll(chunk);
        if (buffer.contains(0x0a) || buffer.length > 4 * 1024 * 1024) break;
      }
    } catch (_) {
      // Peer vanished mid-request; nothing to answer.
    }

    String response;
    try {
      response = _serve(buffer);
    } catch (e) {
      response = 'err ${_reason(e)}';
    }

    try {
      socket.write('$response\n');
      await socket.flush();
    } catch (_) {
      // Broker gave up (its own timeout); drop the reply.
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  String _serve(List<int> buffer) {
    var text = utf8.decode(buffer, allowMalformed: true);
    while (text.endsWith('\n') || text.endsWith('\r')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) return 'err empty-request';

    final firstSpace = text.indexOf(' ');
    if (firstSpace <= 0) return 'err malformed: expected \'<domain> <method>\'';
    final domain = text.substring(0, firstSpace);
    final rest = text.substring(firstSpace + 1);
    final secondSpace = rest.indexOf(' ');
    final method = secondSpace < 0 ? rest : rest.substring(0, secondSpace);
    final payload = secondSpace < 0 ? '' : rest.substring(secondSpace + 1);

    Map<String, Object?> args;
    if (payload.isEmpty) {
      args = const {};
    } else {
      try {
        final decoded = decodeWire(payload);
        if (decoded is! Map<String, Object?>) {
          return 'err invalid-arguments';
        }
        args = decoded;
      } on FormatException {
        return 'err invalid-arguments';
      }
    }

    try {
      final result = dispatch.call(domain, method, args);
      return 'ok ${encodeWire(result)}';
    } on DispatchException catch (e) {
      return 'err ${e.reason}';
    } catch (e) {
      return 'err ${_reason(e)}';
    }
  }

  /// Exception text is developer-facing and must never leak a path or a
  /// stack trace across the socket; collapse it to one token.
  static String _reason(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), '-');
    final trimmed = text.length > 80 ? text.substring(0, 80) : text;
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '') == ''
        ? 'internal-error'
        : trimmed;
  }

  static void _chmod(String path, String mode) {
    try {
      Process.runSync('chmod', [mode, path]);
    } catch (_) {
      // chmod is defence in depth; the 0700 runtime dir is the real control.
    }
  }
}
