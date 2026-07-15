library;

import 'package:keta/keta.dart';

import 'route_path.dart';

/// The name a route file gives its [Exported]. One name, one value, one type.
const exportedDeclaration = 'exported';

/// One verb a route file serves: the handler, and the document describing it.
///
/// Sealed, so [Exported.bind] must account for every verb that exists. Adding
/// one is then a compile error at the place that has to handle it, rather than
/// a verb that silently never binds.
///
/// The handler and its doc are one value because they describe one thing. Kept
/// apart — a `get` here and a `getDoc` over there, matched up by name — a
/// misspelling silently unbinds the document, and the contract quietly stops
/// describing the code. Measured: renaming `getDoc` to `getDocs` dropped a
/// route's summary from the OpenAPI output with no diagnostic at all.
sealed class Verb<E> {
  const Verb(this.handler, {this.doc});

  /// What answers the request.
  final Handler<E> handler;

  /// What the contract says about it — a `RouteDoc`, when keta_openapi is in
  /// play. Typed as [Object] because Ring 3 does not depend on Ring 2; keta
  /// carries a route's doc opaquely for exactly this reason.
  final Object? doc;
}

final class Get<E> extends Verb<E> {
  const Get(super.handler, {super.doc});
}

final class Post<E> extends Verb<E> {
  const Post(super.handler, {super.doc});
}

final class Put<E> extends Verb<E> {
  const Put(super.handler, {super.doc});
}

final class Delete<E> extends Verb<E> {
  const Delete(super.handler, {super.doc});
}

final class Patch<E> extends Verb<E> {
  const Patch(super.handler, {super.doc});
}

final class Head<E> extends Verb<E> {
  const Head(super.handler, {super.doc});
}

final class Options<E> extends Verb<E> {
  const Options(super.handler, {super.doc});
}

/// Everything a route file contributes, under the one name the tree looks for.
///
/// The file says *what*; its location says *where*. Nothing here names a URL —
/// look at where the file sits.
///
/// This is a type rather than a set of conventionally-named top-level
/// declarations because a convention enforced by string matching fails quietly.
/// Every mistake this shape can make is now a compile error: a misspelled
/// `captures:` is an unknown named argument, a handler of the wrong shape is a
/// type error, a doc attached to a verb the file does not serve is unwritable.
class Exported<E> {
  /// Const, because it has nothing to check here.
  ///
  /// A URL answering one method twice is caught by keta itself, at boot, and
  /// named better than this could: `route conflict: GET /users/:id registered
  /// twice`. Serving nothing is caught by [bind] — which is where it was caught
  /// before too, since a lazy `final` only runs its initializer when something
  /// first touches it, and the first touch is the bind.
  const Exported(this.verbs, {this.captures = const {}});

  /// What this file serves — one entry per verb the URL answers. `/users` is
  /// [Get] and [Post]; `/health` is just [Get].
  final List<Verb<E>> verbs;

  /// The types of the captures its location declares — `{'index': integer}` for
  /// `routes/users/_uid/tags/_index.dart`. A capture absent here is a [string],
  /// the default every file-routing convention has.
  ///
  /// This is the one thing the tree cannot say. A directory named `_index`
  /// establishes that there is a parameter and what it is called; only the file
  /// can say it is an integer, and that is what puts `type: integer` in the
  /// document and turns a non-integer into a 400.
  final Map<String, Capture<Object?>> captures;

  /// Binds every verb at [template] — the URL this file's location denotes,
  /// handed in by the generated manifest.
  void bind(App<E> app, List<String> template) {
    if (verbs.isEmpty) {
      // A file under routes/ that serves nothing looks exactly like a route and
      // answers 404. Loud at boot rather than a mystery at request time.
      throw StateError(
        'the route file for ${template.isEmpty ? '/' : '/${template.join('/')}'}'
        ' serves no verb',
      );
    }
    final segments = routeSegments(template, captures);
    for (final verb in verbs) {
      // Exhaustive over the sealed hierarchy: a new Verb without a case here
      // does not compile.
      switch (verb) {
        case Get<E>():
          app.get(segments, verb.handler, doc: verb.doc);
        case Post<E>():
          app.post(segments, verb.handler, doc: verb.doc);
        case Put<E>():
          app.put(segments, verb.handler, doc: verb.doc);
        case Delete<E>():
          app.delete(segments, verb.handler, doc: verb.doc);
        case Patch<E>():
          app.patch(segments, verb.handler, doc: verb.doc);
        case Head<E>():
          app.head(segments, verb.handler, doc: verb.doc);
        case Options<E>():
          app.options(segments, verb.handler, doc: verb.doc);
      }
    }
  }
}
