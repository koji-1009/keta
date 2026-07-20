/// keta_db's shared adapter conformance suite, run against PostgreSQL.
///
/// The same floor keta_sqlite runs, so the two adapters are held to one
/// contract instead of to whatever each suite's author thought to check. The
/// expectations inside it switch on `db.capabilities`, never on the engine's
/// name: this engine declares all three capabilities, and the suite makes it
/// demonstrate them.
///
/// Gated on `KETA_TEST_PG` exactly as `rds_contract_test.dart` is — a suite
/// that did not run must never look like a suite that passed.
library;

import 'dart:io';

import 'package:keta_db/test.dart';
import 'package:keta_rds/keta_rds.dart';

final String? _pgUrl = Platform.environment['KETA_TEST_PG'];

void main() {
  if (_pgUrl == null) {
    // ignore: avoid_print
    print(
      'SKIP: keta_rds conformance suite — set KETA_TEST_PG to a postgres:// '
      'URL to run keta_db\'s shared adapter contract against it.',
    );
    return;
  }
  runDbConformance(
    open: () async => RdsDb.url(_pgUrl!),
    boolType: 'boolean',
    decimalType: 'numeric(12,2)',
    timestampType: 'timestamptz',
  );
}
