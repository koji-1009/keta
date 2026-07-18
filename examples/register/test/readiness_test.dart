/// lib/readiness.dart's `readinessPolicy` is a pure function over
/// `RdsPoolStats` — a plain value type (see rds_pool_stats_test.dart in
/// keta_rds itself), so every branch of the policy is testable here with no
/// Postgres connection anywhere in sight (the `readinessPolicy` group below).
///
/// The `/ready` ROUTE's own behavior when `Env.rds` is null — every test env
/// in this suite, since none of them sets `KETA_RDS_URL` — is covered by THIS
/// file's own `GET /ready` group right below, not api_test.dart: that suite
/// has no `/ready` test at all.
///
/// What is NOT covered anywhere in this suite: `/ready` with a NON-null
/// `Env.rds`, wired through a real `RdsDb.poolStats`. There is no fake/stub
/// seam for that — `RdsDb`'s only public constructors (`RdsDb()`,
/// `RdsDb.url()`) open a real socket to PostgreSQL (its `RdsDb._` constructor
/// is private; see keta_rds/lib/src/rds_db.dart), and keta_rds's own
/// rds_pool_stats_test.dart says as much: "constructing an RdsDb needs a real
/// connection". `Env.rds` (lib/env.dart) is typed as the concrete `RdsDb?`,
/// not an interface a test double could implement instead, so injecting a
/// fake here would mean changing that lib code, and driving the real thing
/// would mean a live Postgres dependency for this example's test suite — both
/// of which this example's README ("Readiness" section) explicitly declines
/// to take on. The policy math itself is fully covered by the
/// `readinessPolicy` group below; only the thin plumbing that reads
/// `rds.poolStats` and threads it into that policy is unexercised.
library;

import 'package:keta/test.dart';
import 'package:keta_rds/keta_rds.dart';
import 'package:keta_register_example/app.dart';
import 'package:keta_register_example/readiness.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('GET /ready', () {
    test(
      'is public and answers ready when no RDS pool is configured',
      () async {
        final env = await bootTestEnv();
        addTearDown(env.close);
        // No test env sets KETA_RDS_URL, so env.rds is null here — the fallback
        // branch the route takes when this example's optional Postgres pool
        // (see lib/env.dart) was never wired up.
        final res = await TestClient(buildApp(), env).get('/ready');
        expect(res.status, 200);
        expect(res.json(), {
          'status': 'ready',
          'note': 'no RDS pool configured (KETA_RDS_URL is unset)',
        });
      },
    );
  });

  group('readinessPolicy', () {
    test('ready when the writer pool has headroom', () {
      const stats = RdsPoolStats(
        writer: PoolStats(leased: 1, idle: 4, waiting: 0, maxConnections: 5),
        reader: PoolStats(leased: 1, idle: 4, waiting: 0, maxConnections: 5),
      );
      final readiness = readinessPolicy(stats);
      expect(readiness.status, ReadinessStatus.ready);
      expect(readiness.httpStatus, 200);
      expect(readiness.reason, isNull);
    });

    test('degraded (still 200) when the writer pool is past 80% leased '
        'but nothing is queued', () {
      const stats = RdsPoolStats(
        writer: PoolStats(leased: 4, idle: 1, waiting: 0, maxConnections: 5),
        reader: PoolStats(leased: 0, idle: 5, waiting: 0, maxConnections: 5),
      );
      final readiness = readinessPolicy(stats);
      expect(readiness.status, ReadinessStatus.degraded);
      expect(readiness.httpStatus, 200);
      expect(readiness.reason, contains('nearing saturation'));
    });

    test('not ready (503) when the writer pool is saturated AND '
        'waiters are piling up', () {
      const stats = RdsPoolStats(
        writer: PoolStats(leased: 5, idle: 0, waiting: 3, maxConnections: 5),
        reader: PoolStats(leased: 0, idle: 5, waiting: 0, maxConnections: 5),
      );
      final readiness = readinessPolicy(stats);
      expect(readiness.status, ReadinessStatus.notReady);
      expect(readiness.httpStatus, 503);
      expect(readiness.reason, contains('saturated'));
    });

    test(
      'a fully-leased pool with NO waiters is only degraded, not not-ready — '
      'saturation alone is not the trigger, queueing is',
      () {
        const stats = RdsPoolStats(
          writer: PoolStats(leased: 5, idle: 0, waiting: 0, maxConnections: 5),
          reader: PoolStats(leased: 0, idle: 5, waiting: 0, maxConnections: 5),
        );
        final readiness = readinessPolicy(stats);
        expect(readiness.status, ReadinessStatus.degraded);
      },
    );

    test('the reader pool never affects the verdict — only writer is read', () {
      const stats = RdsPoolStats(
        writer: PoolStats(leased: 0, idle: 5, waiting: 0, maxConnections: 5),
        reader: PoolStats(leased: 5, idle: 0, waiting: 9, maxConnections: 5),
      );
      expect(readinessPolicy(stats).status, ReadinessStatus.ready);
    });
  });
}
