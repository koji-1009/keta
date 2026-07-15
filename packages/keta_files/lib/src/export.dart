library;

import 'package:keta/keta.dart';

import 'route_path.dart';

/// The name a route file gives its [Exported]. One name, one value, one type.
const exportedDeclaration = 'exported';

/// One of [App]'s verb methods, torn off to be paired with the slot it serves.
typedef _Bind<E> =
    void Function(Object path, Handler<E> handler, {Object? doc});

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

  /// What the contract says about it — a `RouteDoc`, when keta_openapi is in
  /// play. Typed as [Object] because Ring 3 does not depend on Ring 2; keta
  /// carries a route's doc opaquely for exactly this reason.
  final Object? doc;
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
  /// denotes, handed in by the generated manifest.
  void bind(App<E> app, List<String> template) {
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
    final segments = routeSegments(template, captures);
    for (final (serve, verb) in serving) {
      verb(segments, serve.handler, doc: serve.doc);
    }
  }
}
