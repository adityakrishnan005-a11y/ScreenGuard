import 'dart:convert';

/// The wire format between the GUI, the broker and the daemon.
///
/// JSON has no date type, and a few domain results legitimately contain
/// `DateTime` (for example `getWeekData` returns the day it aggregated). Those
/// cross the socket as `{"__dt": <millisecondsSinceEpoch>}` and are revived on
/// the other side, so callers never see a type change just because the call
/// went through the broker.
const _dateTag = '__dt';

/// Encode arguments or a result for the wire.
String encodeWire(Object? value) => jsonEncode(value, toEncodable: _encode);

Object? _encode(Object? value) {
  if (value is DateTime) {
    return <String, Object?>{_dateTag: value.millisecondsSinceEpoch};
  }
  throw JsonUnsupportedObjectError(value);
}

/// Decode a wire value, reviving dates.
Object? decodeWire(String text) => _revive(jsonDecode(text));

Object? _revive(Object? value) {
  if (value is Map<String, Object?>) {
    if (value.length == 1 && value[_dateTag] is int) {
      return DateTime.fromMillisecondsSinceEpoch(value[_dateTag]! as int);
    }
    return value.map(
      (String k, Object? v) => MapEntry<String, Object?>(k, _revive(v)),
    );
  }
  if (value is List<Object?>) {
    return value.map(_revive).toList();
  }
  return value;
}
