library;

import 'package:keta/keta.dart';

import 'route_path.dart';

/// The name a route file gives its [Exported]. One name, one value, one type.
const exportedDeclaration = 'exported';

/// The name a `_middleware.dart` file gives its [ScopedMiddleware]. One name,
/// one value, one type — the same discipline [exportedDeclaration] holds a
/// route file to.
const scopedDeclaration = 'scoped';

/// The middleware a directory scopes over every route beneath it — the
/// file-based answer to `app.group(prefix).use(...)`, except the prefix is the
/// directory the file sits in rather than a string handed in twice.
///
/// A `_middleware.dart` file declares one typed value under one name:
///
/// ```dart
/// final scoped = ScopedMiddleware<Env>([requireAuth(), rateLimit()]);
/// ```
///
/// It is a type, not a set of conventionally-named top-level functions, for the
/// same reason [Exported] is: a scope held together by string matching fails
/// quietly. The generator never parses this file — it emits `$mw$admin.scoped`
/// and lets the compiler check the shape at that binding line. A misspelled or
/// wrong-typed value is a compile error there, not a middleware that silently
/// never runs.
///
/// Nothing here names the scope. The file's *location* is its scope: the tree
/// is the truth, the same way no route file names its own URL. The list is
/// ordered outer-to-inner within the file — the first entry wraps the rest —
/// matching keta's own `..use(...)` discipline.
final class ScopedMiddleware<E> {
  /// Const, because it only holds the list the file wrote; there is nothing to
  /// check until [Exported.bind] composes it around a handler.
  const ScopedMiddleware(this.middleware);

  /// The middleware this directory contributes, outermost first.
  final List<Middleware<E>> middleware;
}

/// One of [App]'s verb methods, torn off to be paired with the slot it serves.
typedef _Bind<E> =
    void Function(Object path, Handler<E> handler, {RouteDoc? doc});

/// What one method of a URL does: the handler, and the document describing it.
///
/// The two are one value because they describe one thing. Held apart — a `get`
/// here and a `getDoc` over there, matched up by name — a misspelling silently
/// unbinds the document and the contract quietly stops describing the code.
/// Measured: renaming `getDoc` to `getDocs` dropped a route's summary from the
/// OpenAPI output with no diagnostic at all.
///
/// Which method this answers is the slot it occupies on [Exported], so it does
/// not say.
final class Serve<E> {
  const Serve(this.handler, {this.doc});

  /// What answers the request.
  final Handler<E> handler;

  /// What the contract says about it — the route's [RouteDoc], or null.
  final RouteDoc? doc;
}

/// Everything a route file contributes, under the one name the tree looks for.
///
/// The file says *what*; its location says *where*. Nothing here names a URL —
/// look at where the file sits.
///
/// One slot per method rather than a list, so the shape carries what a check
/// would otherwise have to: a URL cannot answer `GET` twice, because there is
/// nowhere to write it twice. As a list, `[Get(...), Get(...)]` compiled, and
/// only keta's own boot-time `route conflict` caught it.
///
/// This is a type rather than a set of conventionally-named top-level
/// declarations because a convention enforced by string matching fails quietly.
/// Every mistake this shape can make is now a compile error: a misspelled
/// `captures:` is an unknown named argument, a handler of the wrong shape is a
/// type error, a doc attached to a method the file does not serve is unwritable.
class Exported<E> {
  /// Const, because it has nothing to check here.
  ///
  /// Serving nothing is caught by [bind], which costs nothing: a lazy `final`
  /// only runs its initializer when something first touches it, and the first
  /// touch is the bind.
  const Exported({
    this.get,
    this.post,
    this.put,
    this.delete,
    this.patch,
    this.head,
    this.options,
    this.captures = const {},
  });

  /// What this URL does for each method it answers. `/users` fills [get] and
  /// [post]; `/health` fills [get] alone. An empty slot is a method this URL
  /// does not answer — the slots are the seven keta binds, which is the whole
  /// closed set.
  final Serve<E>? get;
  final Serve<E>? post;
  final Serve<E>? put;
  final Serve<E>? delete;
  final Serve<E>? patch;
  final Serve<E>? head;
  final Serve<E>? options;

  /// The types of the captures its location declares — `{'index': integer}` for
  /// `routes/users/_uid/tags/_index.dart`. A capture absent here is a [string],
  /// the default every file-routing convention has.
  ///
  /// This is the one thing the tree cannot say. A directory named `_index`
  /// establishes that there is a parameter and what it is called; only the file
  /// can say it is an integer, and that is what puts `type: integer` in the
  /// document and turns a non-integer into a 400.
  ///
  /// It belongs to the file rather than to a slot because a capture belongs to
  /// the URL: `/users/:id` has an `id` whether it is being fetched, replaced or
  /// deleted, and every method's document carries the same parameter.
  final Map<String, Capture<Object?>> captures;

  /// Binds every method this file serves at [template] — the URL its location
  /// denotes, handed in by the generated manifest — wrapped in the directory
  /// [middleware] its location falls under, outer directory first.
  ///
  /// [middleware] is the accumulated outer→inner chain the generator gathered
  /// from the `_middleware.dart` files on the path from `routes/` down to this
  /// file: `[$mw$root.scoped, $mw$admin.scoped]` for a route under
  /// `routes/admin/`. Composing it here — around the leaf handler, not via a
  /// group — is what makes the ordering match keta's discipline: app-wide
  /// `app.use` middleware still wraps the whole dispatch (404/405 included), and
  /// what this composes runs inside it, root scope before admin scope before the
  /// handler. A directory with no `_middleware.dart` contributes nothing, so an
  /// ordinary route keeps binding exactly as before.
  void bind(
    App<E> app,
    List<String> template, [
    List<ScopedMiddleware<E>> middleware = const [],
  ]) {
    // Paired with the binder here rather than switched on later: a slot with no
    // entry in this list would silently never bind.
    final serving = <(Serve<E>, _Bind<E>)>[
      if (get != null) (get!, app.get),
      if (post != null) (post!, app.post),
      if (put != null) (put!, app.put),
      if (delete != null) (delete!, app.delete),
      if (patch != null) (patch!, app.patch),
      if (head != null) (head!, app.head),
      if (options != null) (options!, app.options),
    ];
    if (serving.isEmpty) {
      // A file under routes/ that serves nothing looks exactly like a route and
      // answers 404. Loud at boot rather than a mystery at request time.
      throw StateError(
        'the route file for ${template.isEmpty ? '/' : '/${template.join('/')}'}'
        ' serves no method',
      );
    }
    // Flatten the scopes into one outer→inner list. A file binds through
    // `app.get(segments, handler)`, which takes a plain [Handler] with no group
    // to hang middleware on, so the chain is composed around the handler here.
    final chain = <Middleware<E>>[
      for (final scope in middleware) ...scope.middleware,
    ];
    final segments = routeSegments(template, captures);
    for (final (serve, verb) in serving) {
      verb(segments, _wrap(serve.handler, chain), doc: serve.doc);
    }
  }

  /// Wraps [base] in [chain] so `chain.first` is outermost and runs first, then
  /// each next entry, then [base] — the same left-to-right ordering keta's own
  /// group-middleware composition uses, so directory scopes read top-down as
  /// they nest.
  static Handler<E> _wrap<E>(Handler<E> base, List<Middleware<E>> chain) {
    var handler = base;
    for (final m in chain.reversed) {
      final next = handler;
      handler = (c) => m(c, next);
    }
    return handler;
  }
}
