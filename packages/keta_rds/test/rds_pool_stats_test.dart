/// Pins RdsPoolStats's value semantics (equality, hashCode, toString) against
/// plain PoolStats snapshots — no real Postgres connection needed, since the
/// pairing itself carries no logic beyond holding two PoolStats. RdsDb.poolStats
/// wiring the pairing to its real writer/reader pools is exercised by the
/// KETA_TEST_PG-gated contract suite (rds_contract_test.dart), because
/// constructing an RdsDb needs a real connection.
library;

import 'package:keta_rds/src/pool.dart';
import 'package:keta_rds/src/rds_db.dart';
import 'package:test/test.dart';

void main() {
  group('RdsPoolStats', () {
    const writer = PoolStats(leased: 1, idle: 2, waiting: 0, maxConnections: 5);
    const reader = PoolStats(leased: 0, idle: 1, waiting: 0, maxConnections: 5);

    test('equality and hashCode compare both pools', () {
      const a = RdsPoolStats(writer: writer, reader: reader);
      const b = RdsPoolStats(writer: writer, reader: reader);
      const differentReader = RdsPoolStats(
        writer: writer,
        reader: PoolStats(leased: 1, idle: 0, waiting: 0, maxConnections: 5),
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentReader)));
    });

    test('toString reports both snapshots', () {
      const stats = RdsPoolStats(writer: writer, reader: reader);
      expect(
        stats.toString(),
        'RdsPoolStats(writer: $writer, reader: $reader)',
      );
    });

    test('reader and writer report identically when the pool is shared', () {
      // Mirrors RdsDb's "pool model": no readerEndpoint/readerUrl means
      // reader and writer are stats of the very same Pool, so the two fields
      // are expected to be equal rather than the type inventing a distinction
      // that is not there.
      const stats = RdsPoolStats(writer: writer, reader: writer);
      expect(stats.reader, equals(stats.writer));
    });
  });
}
