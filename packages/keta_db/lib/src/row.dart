library;

/// Reads the columns whose Dart shape differs between engines, so one
/// hand-written `fromRow` runs unchanged against SQLite and PostgreSQL.
///
/// Only three column kinds are here, and the omissions are the point. A
/// `String`, an `int`, a `double` and a `List<int>` already arrive as
/// themselves on every adapter, so `row['id'] as String` is the canonical read
/// and gains nothing from a wrapper. What diverges is the boolean (a `bool` on
/// PostgreSQL, an `int` `0`/`1` on SQLite), the exact decimal, and the
/// timestamp — and those are exactly the reads that otherwise pass their SQLite
/// test and go wrong in production.
///
/// **The caller declares the type**, because the adapter cannot infer it: an
/// `int` `1` in a SQLite column is a boolean or a number depending on what the
/// schema meant, and the adapter never sees the schema. `row.boolAt('active')`
/// is that declaration.
///
/// **Every failure here is a [StateError], never a `BadRequest`.** A row is
/// produced by the server's own schema and its own SQL — it is not client
/// input — so a column that is absent, null where it must not be, or holding a
/// shape the declaration rules out is a defect on this side of the wire. Under
/// keta's error rule that is a 500 with nothing leaked, which is the honest
/// answer; blaming the caller with a 400 would not be.
extension DbRow on Map<String, Object?> {
  /// Reads a boolean column, accepting either an engine's native `bool` or the
  /// `0`/`1` integer a boolean-less engine stores.
  ///
  /// A [StateError] when the column is absent, null, or holds anything else —
  /// including an integer other than `0` or `1`, which means the column was
  /// never a boolean.
  bool boolAt(String column) => _nonNull(column, tryBoolAt(column))! as bool;

  /// [boolAt] where the column is nullable: null when the column holds SQL
  /// NULL, still a [StateError] when it is absent or holds a non-boolean.
  bool? tryBoolAt(String column) {
    final value = _present(column);
    return switch (value) {
      null => null,
      bool() => value,
      0 => false,
      1 => true,
      _ => throw StateError(
        'column "$column" is not a boolean: ${_describe(value)}. A boolean is '
        'a bool, or the integer 0/1 on an engine with no boolean storage '
        'class.',
      ),
    };
  }

  /// Reads an exact decimal column as the digits it holds, never as a binary
  /// float.
  ///
  /// The column must come back as a [String]. On an engine with exact-decimal
  /// storage that is what the adapter returns for `numeric`/`decimal`; on one
  /// without (`DbCapabilities.exactDecimal` false), it means the column must be
  /// declared TEXT — a NUMERIC-affinity column there has already discarded
  /// digits by the time this runs, so accepting the `int`/`double` it returns
  /// would launder that loss into a value that looks exact. It is refused
  /// instead.
  String decimalAt(String column) =>
      _nonNull(column, tryDecimalAt(column))! as String;

  /// [decimalAt] where the column is nullable.
  String? tryDecimalAt(String column) {
    final value = _present(column);
    return switch (value) {
      null => null,
      String() => value,
      num() => throw StateError(
        'column "$column" came back as ${_describe(value)}, not an exact '
        'decimal. The engine has no exact-decimal storage for this column, so '
        'its digits are already lost — declare the column TEXT and store the '
        'decimal as its digits (see DbCapabilities.exactDecimal).',
      ),
      _ => throw StateError(
        'column "$column" is not a decimal: ${_describe(value)}.',
      ),
    };
  }

  /// Reads a timestamp column as the ISO 8601 string it holds, unchanged.
  ///
  /// Nothing is invented: an offset the column never carried is not added, and
  /// the value is returned exactly as stored, because that is all the column
  /// says. What this does enforce is that it IS an ISO 8601 instant — on an
  /// engine that neither validates nor normalizes temporal values
  /// (`DbCapabilities.typedTemporal` false) the convention is the
  /// application's to keep, and this is where a Unix integer or a locale-
  /// formatted date stops instead of travelling on.
  String timestampAt(String column) =>
      _nonNull(column, tryTimestampAt(column))! as String;

  /// [timestampAt] where the column is nullable.
  String? tryTimestampAt(String column) {
    final value = _present(column);
    if (value == null) return null;
    if (value is! String) {
      throw StateError(
        'column "$column" is not a timestamp: ${_describe(value)}. Store '
        'timestamps as ISO 8601 text.',
      );
    }
    if (DateTime.tryParse(value) == null) {
      throw StateError(
        'column "$column" holds "$value", which is not ISO 8601.',
      );
    }
    return value;
  }

  /// The raw value, having established the column was selected at all.
  ///
  /// An absent column and a NULL one both read as `null` from a row map, and
  /// they are different defects: NULL is data the schema permits, an absent
  /// column means this SQL never selected it. Only the second can be told
  /// apart here, and it is worth telling apart — it is a typo in a query, not
  /// a nullable field.
  Object? _present(String column) {
    if (!containsKey(column)) {
      throw StateError(
        'no column "$column" in this row (selected: '
        '${keys.isEmpty ? 'nothing' : keys.join(', ')})',
      );
    }
    return this[column];
  }

  Object? _nonNull(String column, Object? value) {
    if (value == null) {
      throw StateError(
        'column "$column" is null; read it with the try… accessor if the '
        'column is nullable',
      );
    }
    return value;
  }
}

String _describe(Object? value) => switch (value) {
  null => 'null',
  String() => 'the string "$value"',
  _ => 'a ${value.runtimeType} ($value)',
};
