/// Middleware ordering: keta's own ranks, the ascending check `App.compile`
/// runs over the chain a request actually gets, and the application's freedom
/// to declare its own vocabulary — or to ignore the whole mechanism.
library;

import 'package:keta/keta.dart';
import 'package:test/test.dart';

/// The shape an application declares: a sealed class, so a `switch` over the
/// stack stays exhaustive and a stage can carry a value — `Shed` appears twice
/// at different depths because a rate limiter keyed by IP belongs before
/// authentication and one keyed by principal after it.
sealed class Stage implements MiddlewareOrder {
  const Stage(this.name, this.rank);
  @override
  final String name;
  @override
  final int rank;
}

final class Shed extends Stage {
  const Shed(int rank) : super('shed', rank);
}

final class Audit extends Stage {
  // Between keta's `authenticate` (7000) and `authorize` (8000): the app's own
  // stage interleaves in the gap rather than renumbering keta's.
  const Audit() : super('audit', 7500);
}

Middleware<void> noop() =>
    (c, next) => next(c);

void main() {
  group("keta's own ranks", () {
    // The table is the mechanism: keta's invariants hold because these numbers
    // ship together from one commit of this workspace, not because anything
    // re-derives them per application. Editing one so a pair inverts is the
    // failure this test exists to catch.
    test('ascend in the order the chain must run', () {
      final ranks = [
        KetaOrder.observe,
        KetaOrder.crossOrigin,
        KetaOrder.recover,
        KetaOrder.shed,
        KetaOrder.deadline,
        KetaOrder.negotiate,
        KetaOrder.validate,
        KetaOrder.authenticate,
        KetaOrder.authorize,
        KetaOrder.resource,
      ];
      for (var i = 1; i < ranks.length; i++) {
        expect(
          ranks[i].rank,
          greaterThan(ranks[i - 1].rank),
          reason: '${ranks[i].name} must be inside ${ranks[i - 1].name}',
        );
      }
    });

    test('pin the pairs whose inversion is a silent bug', () {
      // gzip outside etag: the tag must be computed over the un-encoded body.
      expect(KetaOrder.negotiate.rank, lessThan(KetaOrder.validate.rank));
      // recover outside tx: a thrown error must reach the transaction (→
      // ROLLBACK) before anything converts it into a Response.
      expect(KetaOrder.recover.rank, lessThan(KetaOrder.resource.rank));
      // oidc outside requireScopes: the principal must exist to be authorized.
      expect(KetaOrder.authenticate.rank, lessThan(KetaOrder.authorize.rank));
      // accessLog outermost, so it times (and logs) even a shed request.
      expect(KetaOrder.observe.rank, lessThan(KetaOrder.shed.rank));
      // cors outside recover and timeout: a 500 or a 504 must still carry the
      // headers that let the browser hand the response to the page.
      expect(KetaOrder.crossOrigin.rank, lessThan(KetaOrder.recover.rank));
      expect(KetaOrder.crossOrigin.rank, lessThan(KetaOrder.deadline.rank));
    });

    test('leave room for an application stage between any two', () {
      expect(
        KetaOrder.crossOrigin.rank - KetaOrder.observe.rank,
        KetaOrder.spacing,
      );
      expect(const Audit().rank, greaterThan(KetaOrder.authenticate.rank));
      expect(const Audit().rank, lessThan(KetaOrder.authorize.rank));
    });
  });

  group("keta's middleware carry their ranks", () {
    test('so an application inherits them without naming any', () {
      expect(orderOf(accessLog<void>()), KetaOrder.observe);
      expect(orderOf(recover<void>()), KetaOrder.recover);
      expect(orderOf(gzip<void>()), KetaOrder.negotiate);
      expect(orderOf(cors<void>(allowOrigins: ['*'])), KetaOrder.crossOrigin);
      expect(orderOf(etag<void>()), KetaOrder.validate);
      expect(orderOf(timeout<void>(Duration.zero)), KetaOrder.deadline);
      expect(orderOf(concurrencyLimit<void>(maxInFlight: 1)), KetaOrder.shed);
      expect(
        orderOf(
          rateLimit<void>(
            key: (c) => null,
            capacity: 1,
            refillPeriod: const Duration(seconds: 1),
          ),
        ),
        KetaOrder.shed,
      );
    });

    test('and an untagged middleware carries none', () {
      expect(orderOf(noop()), isNull);
    });

    test('tagging one instance never marks another', () {
      final a = accessLog<void>();
      final b = ordered(noop(), const Audit());
      expect(orderOf(a), KetaOrder.observe);
      expect(orderOf(b), const Audit());
      expect(orderOf(noop()), isNull);
    });
  });

  group('App.compile checks the chain', () {
    test('accepts an ascending app-wide chain', () {
      final app = App<void>()
        ..use(accessLog())
        ..use(recover())
        ..use(gzip())
        ..use(etag());
      app.get('/', (c) => c.text('ok'));
      expect(() => app.compile(null), returnsNormally);
    });

    test('rejects etag registered outside gzip, naming both', () {
      final app = App<void>()
        ..use(etag())
        ..use(gzip());
      app.get('/', (c) => c.text('ok'));
      expect(
        () => app.compile(null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('negotiate'),
              contains('validate'),
              contains('app-wide middleware'),
            ),
          ),
        ),
      );
    });

    test('checks the app-wide chain even with no routes registered', () {
      final app = App<void>()
        ..use(etag())
        ..use(gzip());
      expect(() => app.compile(null), throwsA(isA<StateError>()));
    });

    test('reads a route chain as app-wide first, then the group — the order '
        'they actually compose in', () {
      // Neither list is misordered on its own; the violation exists only
      // across the seam, which is exactly what a per-list check would miss.
      final app = App<void>()..use(etag());
      app.group('/api')
        ..use(gzip())
        ..get('/x', (c) => c.text('ok'));
      expect(
        () => app.compile(null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('GET /api/x'), contains('negotiate')),
          ),
        ),
      );
    });

    test('an untagged middleware constrains nothing and is constrained by '
        'nothing', () {
      final app = App<void>()
        ..use(gzip())
        ..use(noop())
        ..use(etag());
      app.get('/', (c) => c.text('ok'));
      expect(() => app.compile(null), returnsNormally);

      final between = App<void>()
        ..use(etag())
        ..use(noop());
      between.get('/', (c) => c.text('ok'));
      // Still a violation: skipping the untagged entry does not let the tagged
      // pair off — but with nothing after it, this chain is fine.
      expect(() => between.compile(null), returnsNormally);
    });

    test('equal ranks are unordered: two shedders compose either way', () {
      for (final ordering in [
        [
          concurrencyLimit<void>(maxInFlight: 1),
          rateLimit<void>(
            key: (c) => null,
            capacity: 1,
            refillPeriod: const Duration(seconds: 1),
          ),
        ],
        [
          rateLimit<void>(
            key: (c) => null,
            capacity: 1,
            refillPeriod: const Duration(seconds: 1),
          ),
          concurrencyLimit<void>(maxInFlight: 1),
        ],
      ]) {
        final app = App<void>();
        for (final m in ordering) {
          app.use(m);
        }
        app.get('/', (c) => c.text('ok'));
        expect(() => app.compile(null), returnsNormally);
      }
    });

    test('cors sits outside recover, so an error response still carries its '
        'headers', () {
      final ok = App<void>()
        ..use(cors(allowOrigins: const ['*']))
        ..use(recover());
      ok.get('/', (c) => c.text('ok'));
      expect(() => ok.compile(null), returnsNormally);

      final inverted = App<void>()
        ..use(recover())
        ..use(cors(allowOrigins: const ['*']));
      inverted.get('/', (c) => c.text('ok'));
      expect(() => inverted.compile(null), throwsA(isA<StateError>()));
    });
  });

  group('the application owns the vocabulary', () {
    test('one stage may recur at two depths, carrying its own value', () {
      final app = App<void>()
        ..use(accessLog())
        ..use(noop(), order: const Shed(2000))
        ..use(enforceSecurity(const SecurityPolicy(defaults: [])))
        ..use(noop(), order: const Shed(7500));
      app.get('/', (c) => c.text('ok'));
      expect(() => app.compile(null), returnsNormally);
    });

    test("an explicit order: overrides keta's own tag — the app decides", () {
      // etag before gzip is refused above; declaring it deliberately is not
      // this mechanism's business to prevent.
      final app = App<void>()
        ..use(etag(), order: const Shed(100))
        ..use(gzip());
      app.get('/', (c) => c.text('ok'));
      expect(() => app.compile(null), returnsNormally);
    });

    test('a stack that declares nothing is checked against nothing', () {
      final app = App<void>()
        ..use(noop())
        ..use(noop());
      app.get('/', (c) => c.text('ok'));
      expect(() => app.compile(null), returnsNormally);
    });
  });

  group('checkMiddlewareOrder', () {
    test('accepts an empty chain and a single entry', () {
      expect(() => checkMiddlewareOrder([], 'x'), returnsNormally);
      expect(
        () => checkMiddlewareOrder([KetaOrder.resource], 'x'),
        returnsNormally,
      );
    });

    test('accepts a repeated rank', () {
      expect(
        () => checkMiddlewareOrder([KetaOrder.shed, KetaOrder.shed], 'x'),
        returnsNormally,
      );
    });

    test('names the chain it was given', () {
      expect(
        () => checkMiddlewareOrder([
          KetaOrder.resource,
          KetaOrder.recover,
        ], 'POST /orders'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('POST /orders'),
          ),
        ),
      );
    });
  });
}
