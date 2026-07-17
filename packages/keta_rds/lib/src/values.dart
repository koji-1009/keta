library;

import 'dart:typed_data';

import 'package:postgres/postgres.dart' show ResultRow;

/// Maps a driver row to keta_db's column-name map, honouring the §3
/// type-mapping contract on each value (see [mapValue]).
Map<String, Object?> mapRow(ResultRow row) => {
  for (final entry in row.toColumnMap().entries)
    entry.key: mapValue(entry.value),
};

/// Normalizes a single driver value to the [DbConn] type-mapping contract.
///
/// package:postgres already decodes most of the contract natively: `int2/4/8`
/// arrive as [int], `real`/`double precision` as [double], `boolean` as [bool],
/// `null` as `null` (with the column still present in the row map), and —
/// crucially — `numeric`/`decimal` as [String], so this adapter is the first
/// that can honour the "decimals keep their precision" clause without effort.
/// Only two shapes need adjusting here:
///
/// - a temporal value (`timestamp`, `timestamptz`, `date`) decodes to a
///   [DateTime]; the contract is ISO 8601 strings, so it is rendered with
///   [DateTime.toIso8601String];
/// - `bytea` decodes to a [Uint8List]; it is exposed as a fixed-length
///   `List<int>`, matching keta_sqlite's BLOB handling (and, being
///   fixed-length, it rejects mutation rather than silently detaching a view).
///
/// Anything outside the contract (json/jsonb objects, arrays, geometric types)
/// passes through as the driver decoded it — the adapter does not invent a
/// representation the contract does not name.
Object? mapValue(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is Uint8List) return value.toList(growable: false);
  return value;
}
