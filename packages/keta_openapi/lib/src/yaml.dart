library;

/// Serializes a JSON-shaped value (maps, lists, and scalars) to block-style
/// YAML. Scoped to what an OpenAPI document contains; it is an emitter, not a
/// general YAML implementation.
String encodeYaml(Object? value) {
  final buffer = StringBuffer();
  if (value is Map) {
    _writeMap(buffer, value, 0);
  } else if (value is List) {
    _writeList(buffer, value, 0);
  } else {
    buffer.writeln(_scalar(value));
  }
  return buffer.toString();
}

void _writeMap(StringBuffer buffer, Map<Object?, Object?> map, int indent) {
  final pad = _pad(indent);
  map.forEach((key, value) {
    final label = '$pad${_scalar(key.toString())}:';
    if (value is Map && value.isNotEmpty) {
      buffer.writeln(label);
      _writeMap(buffer, value, indent + 1);
    } else if (value is List && value.isNotEmpty) {
      buffer.writeln(label);
      _writeList(buffer, value, indent);
    } else if (value is Map) {
      buffer.writeln('$label {}');
    } else if (value is List) {
      buffer.writeln('$label []');
    } else {
      buffer.writeln('$label ${_scalar(value)}');
    }
  });
}

void _writeList(StringBuffer buffer, List<Object?> list, int indent) {
  final pad = _pad(indent);
  for (final item in list) {
    if (item is Map && item.isNotEmpty) {
      buffer.writeln('$pad-');
      _writeMap(buffer, item, indent + 1);
    } else if (item is List && item.isNotEmpty) {
      buffer.writeln('$pad-');
      _writeList(buffer, item, indent + 1);
    } else if (item is Map) {
      buffer.writeln('$pad- {}');
    } else if (item is List) {
      buffer.writeln('$pad- []');
    } else {
      buffer.writeln('$pad- ${_scalar(item)}');
    }
  }
}

String _pad(int indent) => '  ' * indent;

String _scalar(Object? value) => switch (value) {
      null => 'null',
      bool() => value.toString(),
      num() => value.toString(),
      String() => _quoteIfNeeded(value),
      _ => _quoteIfNeeded(value.toString()),
    };

final RegExp _plainSafe = RegExp(r'^[A-Za-z_][A-Za-z0-9_./-]*$');
final RegExp _numberLike = RegExp(r'^-?\d+(\.\d+)?$');
const Set<String> _reserved = {
  'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~',
};

String _quoteIfNeeded(String value) {
  final needsQuote = value.isEmpty ||
      !_plainSafe.hasMatch(value) ||
      _numberLike.hasMatch(value) ||
      _reserved.contains(value.toLowerCase());
  if (!needsQuote) return value;
  final escaped =
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');
  return '"$escaped"';
}
