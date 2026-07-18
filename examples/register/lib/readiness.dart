import 'package:keta_rds/keta_rds.dart';

/// A `/ready` endpoint's verdict. `ready` and `degraded` both answer 200 (the
/// service still accepts traffic); `notReady` answers 503 — a load balancer's
/// usual signal to stop routing here until the next probe passes.
enum ReadinessStatus { ready, degraded, notReady }

/// What [readinessPolicy] decided, and why — the `why` matters for a human
/// reading a probe failure at 3am, not for the load balancer, which only reads
/// [httpStatus].
class Readiness {
  const Readiness(this.status, [this.reason]);
  final ReadinessStatus status;
  final String? reason;

  int get httpStatus => status == ReadinessStatus.notReady ? 503 : 200;

  Map<String, Object?> toJson() => {
    'status': status.name,
    if (reason != null) 'reason': reason,
  };
}

/// AN example readiness policy over [RdsPoolStats.writer] — not a framework
/// mechanism, not a prescription for what "ready" should mean in any real
/// service. keta ships `RdsDb.poolStats`; what a route does with the numbers
/// is entirely app code, and this is one deliberately simple reading of them:
///
///  - **not ready** when the writer pool is fully leased AND callers are
///    already piling up in [PoolStats.waiting] — saturated, not merely busy.
///    A pool that is momentarily at capacity with nobody queued is not yet in
///    trouble; a pool with waiters is actively failing to keep up.
///  - **degraded** when the writer pool is past 80% leased but nothing is
///    queued yet — a warning a dashboard might page on, without yet telling a
///    load balancer to stop routing here.
///  - **ready** otherwise.
///
/// A real service would tune (or replace outright) these thresholds against
/// its own traffic shape and SLOs; the 80%/waiters split here exists only to
/// give the demo something to compute.
Readiness readinessPolicy(RdsPoolStats stats) {
  final writer = stats.writer;
  if (writer.leased >= writer.maxConnections && writer.waiting > 0) {
    return Readiness(
      ReadinessStatus.notReady,
      'writer pool saturated: ${writer.leased}/${writer.maxConnections} '
      'leased, ${writer.waiting} waiting',
    );
  }
  if (writer.maxConnections > 0 &&
      writer.leased / writer.maxConnections >= 0.8) {
    return Readiness(
      ReadinessStatus.degraded,
      'writer pool nearing saturation: ${writer.leased}/'
      '${writer.maxConnections} leased',
    );
  }
  return const Readiness(ReadinessStatus.ready);
}
