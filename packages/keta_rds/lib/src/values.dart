library;

import 'dart:typed_data';

import 'package:postgres/postgres.dart' show ResultRow, Type;

/// Maps a driver row to keta_db's column-name map, honouring the §3
/// type-mapping contract on each value (see [mapValue]).
///
/// The column's declared [Type] is threaded into [mapValue] because three
/// temporal shapes decode to the same Dart [DateTime] yet must render
/// differently (see there): the value alone cannot tell a `date` from a
/// `timestamp` from a `timestamptz`, so the mapping keys off the schema.
Map<String, Object?> mapRow(ResultRow row) {
  final columns = row.schema.columns;
  final map = <String, Object?>{};
  for (final (i, col) in columns.indexed) {
    // Mirror ResultRow.toColumnMap's naming of unnamed columns ('[$i]') so this
    // schema-aware path stays a drop-in for the old toColumnMap()-based one; a
    // later duplicate name overrides an earlier one, exactly as before.
    map[col.columnName ?? '[$i]'] = mapValue(row[i], col.type);
  }
  return map;
}

/// Normalizes a single driver value of column type [type] to the [DbConn]
/// type-mapping contract.
///
/// package:postgres already decodes most of the contract natively: `int2/4/8`
/// arrive as [int], `real`/`double precision` as [double], `boolean` as [bool],
/// `null` as `null` (with the column still present in the row map), and —
/// crucially — `numeric`/`decimal` as [String], so this adapter is the first
/// that can honour the "decimals keep their precision" clause without effort.
/// The shapes that need adjusting here:
///
/// - a **temporal** value (`timestamp`, `timestamptz`, `date`) decodes to a
///   [DateTime]. The contract is ISO 8601 strings, but "ISO 8601" is not one
///   rule for all three — and the driver erases the distinction, handing all
///   three back as `DateTime.utc(...)` (verified in package:postgres
///   binary_codec/text_codec: both tag the value UTC). So [type] disambiguates:
///
///   - `timestamptz` names a real instant, so it is emitted as UTC with a `Z`
///     (`2026-07-17T10:30:00.000Z`) — the honest, unambiguous form. This is
///     also the pre-existing behaviour, preserved deliberately.
///   - `timestamp` (WITHOUT time zone) is a wall-clock reading the database
///     stores with NO zone attached. The driver's UTC tag is a fiction, so we
///     emit it WITHOUT any offset designator (`2026-07-17T10:30:00.000`): the
///     string must not claim a `Z`/`+00:00` the column never carried. The
///     ambiguity is the COLUMN TYPE's, not keta's — a bare `timestamp` genuinely
///     does not know its zone. The fix at the schema level is to use
///     `timestamptz`; keta reports the value as honestly as the column allows
///     and invents nothing. (This is why `toIso8601String()` alone was wrong: on
///     a UTC-tagged DateTime it always appends `Z`, silently upgrading an
///     unzoned reading to a false instant.)
///   - `date` carries no time-of-day at all, so it is emitted as `yyyy-MM-dd`
///     (`2026-07-17`), not the full datetime string `toIso8601String()` would
///     leak (`2026-07-17T00:00:00.000Z`) — a spurious midnight-UTC instant.
///
/// - `bytea` decodes to a [Uint8List]; it is exposed as a fixed-length
///   `List<int>`, matching keta_sqlite's BLOB handling (and, being
///   fixed-length, it rejects mutation rather than silently detaching a view).
///
/// Anything outside the contract (json/jsonb objects, arrays, geometric types)
/// passes through as the driver decoded it — the adapter does not invent a
/// representation the contract does not name.
Object? mapValue(Object? value, Type type) {
  if (value is DateTime) {
    // Compare by the driver's own public Type constants (equality is by OID),
    // so this tracks the driver's OID table rather than hard-coding 1082/1114/…
    if (type == Type.date) return _formatDate(value);
    if (type == Type.timestampWithoutTimezone) return _isoWithoutOffset(value);
    // timestamptz and any other DateTime-valued type: a genuine instant. toUtc()
    // is a no-op on the driver's already-UTC value but makes the `Z` guaranteed
    // even if a future driver hands back a local DateTime.
    return value.toUtc().toIso8601String();
  }
  if (value is Uint8List) return value.toList(growable: false);
  return value;
}

/// `yyyy-MM-dd` for a `date` column, dropping the driver's synthetic
/// midnight-UTC time-of-day.
String _formatDate(DateTime value) {
  final y = value.year.toString().padLeft(4, '0');
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// ISO 8601 without a trailing zone designator, for a `timestamp` (no tz). The
/// driver hands the value back as `DateTime.utc(...)`, so `toIso8601String()`
/// always ends in `Z`; dropping exactly that `Z` leaves the wall-clock reading
/// intact while removing the zone claim the column never made. (Rebuilding a
/// local DateTime instead would be non-deterministic: `toIso8601String()` on a
/// non-UTC DateTime appends the host's offset on some platforms — the very
/// ambiguity we are removing.)
String _isoWithoutOffset(DateTime value) {
  final iso = value.toIso8601String();
  return iso.endsWith('Z') ? iso.substring(0, iso.length - 1) : iso;
}
