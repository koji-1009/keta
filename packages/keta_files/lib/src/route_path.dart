library;

import 'package:keta/keta.dart';

/// The segments a route file's location denotes.
///
/// This is the whole of file-based routing at runtime: the URL comes from where
/// the file sits, not from a string written inside it. A `:name` part is a
/// capture — its [Capture] comes from the file's `captures` declaration, which
/// is what supplies the type and the OpenAPI schema. The tree says *where*; the
/// file says *what*. A capture the file does not mention is a [string], the same
/// default every file-routing convention has.
///
/// The result binds through `app.get(segments, handler)`: captures are read with
/// `c.param`, because a shape derived from a tree has no static arity to hand a
/// handler as a tuple.
List<Segment> routeSegments(
  List<String> template, [
  Map<String, Capture<Object?>> captures = const {},
]) => [
  for (final part in template)
    if (part.startsWith(':'))
      CaptureSegment(_captureFor(part.substring(1), captures))
    else
      LiteralSegment(part),
];

Capture<Object?> _captureFor(
  String name,
  Map<String, Capture<Object?>> captures,
) {
  final declared = captures[name];
  if (declared == null) return string(name);
  // Naming it here rather than in the file keeps the declaration about the type
  // alone: the name is already established by the file's own location, and
  // saying it twice invites the two to disagree.
  return declared(name);
}
