library;

/// Emits a JSON-shaped value as Dart source for a `const` map literal, so a
/// parsed schema fragment round-trips back into a `Schema` constant unchanged.
String dartLiteral(Object? value) {
  final buffer = StringBuffer();
  _write(buffer, value);
  return buffer.toString();
}

void _write(StringBuffer buffer, Object? value) {
  switch (value) {
    case null:
      buffer.write('null');
    case bool():
    case num():
      buffer.write(value.toString());
    case String():
      buffer.write(_string(value));
    case List():
      buffer.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) buffer.write(', ');
        _write(buffer, value[i]);
      }
      buffer.write(']');
    case Map():
      buffer.write('{');
      var first = true;
      value.forEach((key, v) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write(_string(key.toString()));
        buffer.write(': ');
        _write(buffer, v);
      });
      buffer.write('}');
    default:
      buffer.write(_string(value.toString()));
  }
}

/// A single-quoted Dart string, using a raw literal when the value contains a
/// `$` (as JSON Schema `$ref` keys do) so no escaping is needed.
String _string(String value) {
  if (value.contains(r'$') && !value.contains("'") && !value.contains(r'\')) {
    return "r'$value'";
  }
  final escaped =
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');
  return "'$escaped'";
}
