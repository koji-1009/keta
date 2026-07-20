library;

import 'db.dart';

/// What an engine can and cannot represent, as a value.
///
/// The same `fromRow` runs against SQLite in a test and PostgreSQL in
/// production, so where the two genuinely differ, the difference has to be
/// *somewhere*. Left implicit it lives in the operator's head and surfaces as a
/// production bug; declared here it is a value the application can read, assert
/// on at boot ([RequireCapabilities.requireCapabilities]), and switch a
/// conformance expectation on.
///
/// This describes what the ENGINE can hold, not what a helper can paper over.
/// Differences a reader can normalize faithfully — a boolean arriving as `0`/`1`
/// — are the row accessors' job and are not modelled here. What is modelled is
/// what no reader can recover: a decimal whose digits were already lost by the
/// storage class is gone, and no accessor can conjure them back.
final class DbCapabilities {
  const DbCapabilities({
    required this.nativeBool,
    required this.exactDecimal,
    required this.typedTemporal,
  });

  /// The engine has a boolean storage class, so a boolean column comes back as
  /// a Dart [bool] rather than an integer `0`/`1`.
  ///
  /// False does not mean booleans are unusable — `row.boolAt(...)` reads both
  /// shapes — only that the raw value is not one.
  final bool nativeBool;

  /// A `numeric`/`decimal` column round-trips with every digit intact.
  ///
  /// False means the engine has no exact-decimal storage class and the column
  /// returns a binary float or an integer: `12.10` comes back as `12.1`, and
  /// enough digits later comes back wrong. On such an engine an exact decimal
  /// must be stored in a TEXT column — `row.decimalAt(...)` then reads it back
  /// exactly, and says so loudly when the column was not TEXT.
  final bool exactDecimal;

  /// The engine distinguishes date / timestamp / timestamp-with-time-zone, and
  /// the adapter renders each as exactly what the column type carries.
  ///
  /// False means a temporal value is whatever was written — the engine neither
  /// validates nor normalizes it, so the ISO 8601 convention is the
  /// application's to keep. `row.timestampAt(...)` enforces it at the read.
  final bool typedTemporal;

  @override
  String toString() =>
      'DbCapabilities(nativeBool: $nativeBool, exactDecimal: $exactDecimal, '
      'typedTemporal: $typedTemporal)';
}

/// Asserts at boot that the engine behind this [Db] can hold what the
/// application needs.
///
/// The failure this exists for is the quiet one: an app developed and tested
/// against SQLite, deployed against PostgreSQL, or the reverse. Every test
/// passes, every request succeeds, and the money column is silently rounded.
/// Calling this in `boot` turns that into a refusal to start, on the machine of
/// whoever changed the wiring.
///
/// Named arguments left null are not required. A [StateError] — an authoring
/// defect, not a request failure — names every capability that came up short.
extension RequireCapabilities on Db {
  void requireCapabilities({
    bool? nativeBool,
    bool? exactDecimal,
    bool? typedTemporal,
  }) {
    final caps = capabilities;
    final missing = [
      if (nativeBool == true && !caps.nativeBool) 'nativeBool',
      if (exactDecimal == true && !caps.exactDecimal) 'exactDecimal',
      if (typedTemporal == true && !caps.typedTemporal) 'typedTemporal',
    ];
    if (missing.isEmpty) return;
    throw StateError(
      'this database does not provide ${missing.join(', ')}: $caps. Point the '
      'app at an engine that does, or drop the requirement and handle the '
      'difference in the application (see DbCapabilities).',
    );
  }
}
