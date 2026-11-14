import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// A blocking AF_UNIX stream socket, implemented over libc.
///
/// Dart's `RawSynchronousSocket` rejects `InternetAddressType.unix` addresses,
/// and the domain façade is synchronous by design, so the broker client calls
/// `socket/connect/send/recv/close` directly. This is a syscall wrapper: no
/// framing, no policy, no retries beyond EINTR.
class SyncUnixSocket {
  SyncUnixSocket._(this._fd);

  final int _fd;
  bool _closed = false;

  /// Connect to [path]. Throws [SyncSocketException] with `errno` set.
  static SyncUnixSocket connect(String path, {Duration timeout = const Duration(seconds: 10)}) {
    final fd = _socket.call(_afUnix, _sockStream, 0);
    if (fd < 0) throw SyncSocketException('socket', _errno());

    final addr = calloc<Uint8>(_addrSize);
    try {
      // sun_family is a native-order 16-bit value in the first two bytes.
      addr.cast<Uint16>().value = _afUnix;
      final name = _encode(path);
      if (name.length + 3 > _addrSize) {
        _close.call(fd);
        throw SyncSocketException('path-too-long', 0);
      }
      for (var i = 0; i < name.length; i++) {
        addr[2 + i] = name[i];
      }
      addr[2 + name.length] = 0;

      if (_connect.call(fd, addr, 2 + name.length + 1) != 0) {
        final errno = _errno();
        _close.call(fd);
        throw SyncSocketException('connect', errno);
      }
      _setTimeout(fd, timeout);
      return SyncUnixSocket._(fd);
    } finally {
      calloc.free(addr);
    }
  }

  /// Send every byte of [data].
  void writeAll(List<int> data) {
    if (data.isEmpty) return;
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        final n = _send.call(_fd, buf + offset, data.length - offset, 0);
        if (n < 0) {
          final errno = _errno();
          if (errno == _eintr) continue;
          throw SyncSocketException('send', errno);
        }
        offset += n;
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Read up to [max] bytes. An empty list means the peer closed the socket.
  List<int> readSome(int max) {
    final buf = calloc<Uint8>(max);
    try {
      while (true) {
        final n = _recv.call(_fd, buf, max, 0);
        if (n < 0) {
          final errno = _errno();
          if (errno == _eintr) continue;
          throw SyncSocketException('recv', errno);
        }
        if (n == 0) return const [];
        return List<int>.generate(n, (i) => buf[i], growable: false);
      }
    } finally {
      calloc.free(buf);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close.call(_fd);
  }

  static void _setTimeout(int fd, Duration timeout) {
    // struct timeval { time_t tv_sec; suseconds_t tv_usec; } = 2 × 8 bytes
    final tv = calloc<Int64>(2);
    try {
      tv[0] = timeout.inSeconds;
      tv[1] = (timeout.inMicroseconds % 1000000);
      _setsockopt.call(fd, _solSocket, _soRcvTimeout, tv, 16);
      _setsockopt.call(fd, _solSocket, _soSndTimeout, tv, 16);
    } finally {
      calloc.free(tv);
    }
  }

  static List<int> _encode(String path) => utf8.encode(path);
}

class SyncSocketException implements Exception {
  SyncSocketException(this.operation, this.errno);
  final String operation;
  final int errno;
  @override
  String toString() => 'SyncSocketException($operation, errno=$errno)';
}

// ---------------------------------------------------------------- bindings

const _afUnix = 1;
const _sockStream = 1;
const _solSocket = 1;
const _soRcvTimeout = 20;
const _soSndTimeout = 21;
const _addrSize = 110; // sizeof(struct sockaddr_un) on Linux
const _eintr = 4;

final DynamicLibrary _libc = _openLibc();

DynamicLibrary _openLibc() {
  for (final name in const ['libc.so.6', 'libc.so', 'libc.musl-x86_64.so.1', 'libc.musl-aarch64.so.1']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {}
  }
  // Last resort: symbols already loaded in the process.
  return DynamicLibrary.process();
}

final _socket = _libc.lookupFunction<
    Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');
final _connect = _libc.lookupFunction<
    Int32 Function(Int32, Pointer<Uint8>, Uint32),
    int Function(int, Pointer<Uint8>, int)>('connect');
final _send = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32),
    int Function(int, Pointer<Uint8>, int, int)>('send');
final _recv = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32),
    int Function(int, Pointer<Uint8>, int, int)>('recv');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _setsockopt = _libc.lookupFunction<
    Int32 Function(Int32, Int32, Int32, Pointer<Int64>, Uint32),
    int Function(int, int, int, Pointer<Int64>, int)>('setsockopt');
final _errnoLocation = _libc.lookupFunction<
    Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

int _errno() => _errnoLocation().value;

/// True when [path] looks like "nothing is listening", i.e. the broker is not
/// running rather than misbehaving.
bool isUnreachableErrno(int errno) => errno == 2 || errno == 111; // ENOENT, ECONNREFUSED

/// True when the socket read timed out (EAGAIN/EWOULDBLOCK).
bool isTimeoutErrno(int errno) => errno == 11;
