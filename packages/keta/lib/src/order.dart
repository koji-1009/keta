/// Where a middleware belongs in the chain, and the check that the chain
/// actually reads that way.
library;

import 'app.dart';

/// The position a middleware occupies in the chain, outermost first.
///
/// keta defines the comparison and nothing else: the *vocabulary* is the
/// application's to declare, because which stages a stack has — and how many
/// times one of them recurs — is a property of that stack, not of the
/// framework. Declare it as a sealed class so a variant can carry a value and
/// a `switch` over the stack stays exhaustive:
///
/// ```dart
/// sealed class Stage implements MiddlewareOrder {
///   const Stage(this.name, this.rank);
///   final String name;
///   final int rank;
/// }
///
/// final class Shed extends Stage { const Shed(int rank) : super('shed', rank); }
/// ```
///
/// A value rather than a fixed constant is what lets one conceptual stage
/// appear twice at different depths — `rateLimit` keyed by IP belongs *before*
/// authentication and keyed by principal *after* it, and both are the same
/// stage.
///
/// [rank] is compared against [KetaOrder]'s, which are spaced by
/// [KetaOrder.spacing] so an application's own stages interleave with keta's
/// rather than replacing them.
abstract interface class MiddlewareOrder {
  /// Ascending outward-to-inward: a lower rank is registered further out.
  int get rank;

  /// Names this position in the [StateError] a misordered chain raises.
  String get name;
}

/// The ranks keta's own middleware carry.
///
/// These are values, not a checklist. The constraints between keta's built-ins
/// — gzip outside etag so the tag is computed over the un-encoded body,
/// `recover` outside `tx` so a failed request cannot commit, `oidc` outside
/// `requireScopes` so a principal exists to authorize — hold because the
/// middleware ship carrying these numbers, co-authored and co-tested at one
/// commit of this workspace. Nothing has to re-derive them per application, and
/// an application that leaves keta's middleware untagged inherits them.
///
/// The numbers are spaced by [spacing]: an application interleaves its own
/// stages in the gaps instead of renumbering keta's.
abstract final class KetaOrder {
  /// The gap between adjacent keta ranks, and the room an application has to
  /// place its own stages between two of them.
  static const int spacing = 1000;

  /// Times and records the whole chain, so it is outermost. `accessLog()`.
  static const MiddlewareOrder observe = _KetaRank('observe', 0);

  /// Attaches the headers that let a browser read the response at all.
  /// `cors()`.
  ///
  /// Outside [recover], not beside [negotiate]: a 500, a 504, and a 404 all
  /// need `Access-Control-Allow-Origin` too, and a `cors()` registered inside
  /// the middleware that produced them never sees those responses.
  static const MiddlewareOrder crossOrigin = _KetaRank('crossOrigin', 1000);

  /// Turns a thrown error into a response. `recover()`.
  static const MiddlewareOrder recover = _KetaRank('recover', 2000);

  /// Refuses work before it is spent. `rateLimit()`, `concurrencyLimit()`.
  static const MiddlewareOrder shed = _KetaRank('shed', 3000);

  /// Bounds time-to-response. `timeout()`.
  static const MiddlewareOrder deadline = _KetaRank('deadline', 4000);

  /// Encodes the response body. `gzip()`.
  static const MiddlewareOrder negotiate = _KetaRank('negotiate', 5000);

  /// Answers a conditional request. `etag()` — inside `gzip()`, so the
  /// validator is computed over the body before it is encoded.
  static const MiddlewareOrder validate = _KetaRank('validate', 6000);

  /// Establishes who is calling. `enforceSecurity()`, keta_oidc's `oidc()`.
  static const MiddlewareOrder authenticate = _KetaRank('authenticate', 7000);

  /// Decides what they may do. keta_oidc's `requireScopes()`.
  static const MiddlewareOrder authorize = _KetaRank('authorize', 8000);

  /// Holds a resource for the handler's duration. keta_db's `tx()`, which is
  /// innermost so `recover()` sees the failure first and the transaction rolls
  /// back.
  static const MiddlewareOrder resource = _KetaRank('resource', 9000);
}

final class _KetaRank implements MiddlewareOrder {
  const _KetaRank(this.name, this.rank);
  @override
  final String name;
  @override
  final int rank;
  @override
  String toString() => 'MiddlewareOrder($name, rank: $rank)';
}

/// Tags [m] with the position it occupies, and returns it.
///
/// The tag rides on the middleware value itself, so a package that ships
/// middleware declares its own position at the definition site — keta_db tags
/// `tx()` with [KetaOrder.resource] without keta knowing that `tx` exists, and
/// without keta_db reaching for anything above its ring. `App.use` reads the
/// tag; an explicit `order:` there overrides it.
///
/// Each call to a middleware factory returns a fresh closure, so tagging one
/// never marks another.
Middleware<E> ordered<E>(Middleware<E> m, MiddlewareOrder order) {
  _orders[m] = order;
  return m;
}

/// The position [m] was tagged with by [ordered], or null when it carries none
/// — an untagged middleware is unconstrained and may sit anywhere.
MiddlewareOrder? orderOf(Object m) => _orders[m];

final Expando<MiddlewareOrder> _orders = Expando('keta middleware order');

/// Throws when [orders] — one entry per middleware in the chain, outermost
/// first, null where the middleware carries no position — is not ascending.
///
/// Untagged entries are skipped rather than pinned between their neighbours:
/// an application's own middleware that never declares a position imposes no
/// constraint and takes none.
void checkMiddlewareOrder(List<MiddlewareOrder?> orders, String chain) {
  MiddlewareOrder? outer;
  for (final order in orders) {
    if (order == null) continue;
    if (outer != null && order.rank < outer.rank) {
      throw StateError(
        'middleware order in $chain: "${order.name}" (rank ${order.rank}) is '
        'registered inside "${outer.name}" (rank ${outer.rank}), but the '
        'lower rank belongs further out. Registration order is '
        'outermost-first; pass `order:` to place a middleware deliberately.',
      );
    }
    outer = order;
  }
}
