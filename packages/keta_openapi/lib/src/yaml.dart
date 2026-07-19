library;

/// Serializes a JSON-shaped value (maps, lists, and scalars) to block-style
/// YAML. Scoped to what an OpenAPI document contains; it is an emitter, not a
/// general YAML implementation.
String encodeYaml(Object? value) {
  final buffer = StringBuffer();
  if (value is Map) {
    // An empty map/list must be emitted explicitly at the root, otherwise the
    // output is blank and parses back as null instead of `{}`/`[]`.
    if (value.isEmpty) {
      buffer.writeln('{}');
    } else {
      _writeMap(buffer, value, 0);
    }
  } else if (value is List) {
    if (value.isEmpty) {
      buffer.writeln('[]');
    } else {
      _writeList(buffer, value, 0);
    }
  } else {
    buffer.writeln(_scalar(value));
  }
  return buffer.toString();
}

void _writeMap(StringBuffer buffer, Map<Object?, Object?> map, int indent) {
  final pad = _pad(indent);
  // Keys are stringified; two keys that stringify identically (e.g. int 1 and
  // string '1') would emit a duplicate-key document that no parser accepts.
  // Refuse rather than produce invalid YAML.
  final seen = <String>{};
  map.forEach((key, value) {
    final keyText = _scalar(key.toString());
    if (!seen.add(keyText)) {
      throw ArgumentError('duplicate YAML key: ${key.toString()}');
    }
    final label = '$pad$keyText:';
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
  double() when !value.isFinite =>
    value.isNaN ? '.nan' : (value.isNegative ? '-.inf' : '.inf'),
  num() => value.toString(),
  String() => _quoteIfNeeded(value),
  _ => _quoteIfNeeded(value.toString()),
};

final RegExp _plainSafe = RegExp(r'^[A-Za-z_][A-Za-z0-9_./-]*$');
final RegExp _numberLike = RegExp(r'^-?\d+(\.\d+)?$');
const Set<String> _reserved = {
  'true',
  'false',
  'null',
  'yes',
  'no',
  'on',
  'off',
  '~',
};

// DEL (0x7f) is grouped with the C0 controls (0x00-0x1f) here, not just for
// the quoting trigger below but for escaping too: the YAML spec's
// c-printable set excludes it exactly as it excludes C0, so a bare DEL is as
// invalid inside a double-quoted scalar as a bare NUL.
final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

// Every character a double-quoted scalar must escape, in one class: the two
// structural characters (`\` and `"`) plus the whole C0/DEL control range. The
// replacer in [_quoteIfNeeded] maps each to its named escape (`\n`, `\r`, `\t`,
// `\\`, `\"`) or, for a control with no named form, to `\xHH`. A single pass
// over this class replaces the former six chained scans; it is byte-identical
// because each source character is rewritten exactly once, so the backslash a
// named escape introduces is never itself re-escaped (the old first-pass
// `\`→`\\` ordering guaranteed the same thing).
final RegExp _quotedEscape = RegExp(r'[\\"\x00-\x1f\x7f]');

String _quoteIfNeeded(String value) {
  final needsQuote =
      value.isEmpty ||
      !_plainSafe.hasMatch(value) ||
      _numberLike.hasMatch(value) ||
      _control.hasMatch(value) ||
      _reserved.contains(value.toLowerCase());
  if (!needsQuote) return value;
  final escaped = value.replaceAllMapped(_quotedEscape, (m) {
    final ch = m[0]!;
    switch (ch) {
      case '\\':
        return r'\\';
      case '"':
        return r'\"';
      case '\n':
        return r'\n';
      case '\r':
        return r'\r';
      case '\t':
        return r'\t';
      default:
        return '\\x${ch.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}';
    }
  });
  return '"$escaped"';
}
