/// Routing values. Both the string syntax and the typed DSL converge on a
/// single [Path] value whose type parameter is the tuple of its captures.
library;

/// A single capture in a path.
///
/// [parse] turns the raw segment string into `T`; a [FormatException] it
/// throws becomes a `KetaException(400)` at the request boundary. [name]
/// labels the parameter for OpenAPI (default `p0`, `p1`, …). [schemaType] is
/// the JSON-Schema primitive the capture maps to.
class Capture<T> {
  const Capture(this.parse, {this.name, this.schemaType = 'string'});
  final T Function(String) parse;
  final String? name;
  final String schemaType;
}

String _identity(String s) => s;
int _toInt(String s) => int.parse(s);
double _toDouble(String s) => double.parse(s);
bool _toBool(String s) => switch (s) {
  'true' => true,
  'false' => false,
  _ => throw FormatException('not a bool', s),
};

/// Built-in captures, exposed as top-level constants.
const Capture<String> str = Capture(_identity);
const Capture<int> integer = Capture(_toInt, schemaType: 'integer');
const Capture<double> dbl = Capture(_toDouble, schemaType: 'number');
const Capture<bool> boolean = Capture(_toBool, schemaType: 'boolean');

/// Returns a copy of [base] carrying [name] (for OpenAPI parameter naming).
Capture<T> named<T>(Capture<T> base, String name) =>
    Capture<T>(base.parse, name: name, schemaType: base.schemaType);

/// One path segment: a fixed literal or a capture.
sealed class Segment {
  const Segment();
}

class LiteralSegment extends Segment {
  const LiteralSegment(this.value);
  final String value;
}

class CaptureSegment extends Segment {
  const CaptureSegment(this.capture);
  final Capture<Object?> capture;
}

/// A path whose type parameter `T` is the tuple of its captures. Built by
/// chaining [lit] and `cap` from [root]; only [root] is `const`.
class Path<T> {
  const Path._(this.segments, this.buildTuple);
  final List<Segment> segments;

  /// Rebuilds the tuple `T` from the ordered, already-parsed capture values.
  /// Arity-specific; supplied by the `cap` extensions.
  final T Function(List<Object?> parsed) buildTuple;

  /// The captures, in path order.
  Iterable<Capture<Object?>> get captures =>
      segments.whereType<CaptureSegment>().map((s) => s.capture);
}

() _unit(List<Object?> parsed) => ();

/// The empty path. Everything else is chained from here.
const Path<()> root = Path<()>._(<Segment>[], _unit);

/// `lit` preserves arity, so the tuple builder is unchanged.
extension PathLit<T> on Path<T> {
  Path<T> lit(String segment) =>
      Path<T>._([...segments, LiteralSegment(segment)], buildTuple);
}

// Arity-transition extensions, fixed 0–4. Each rebuilds the whole tuple from
// the full ordered capture list, so indices stay stable across `lit`.

extension PathCap0 on Path<()> {
  Path<(A,)> cap<A>(Capture<A> capture) => Path<(A,)>._([
    ...segments,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A,));
}

extension PathCap1<A> on Path<(A,)> {
  Path<(A, B)> cap<B>(Capture<B> capture) => Path<(A, B)>._([
    ...segments,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A, parsed[1] as B));
}

extension PathCap2<A, B> on Path<(A, B)> {
  Path<(A, B, C)> cap<C>(Capture<C> capture) => Path<(A, B, C)>._([
    ...segments,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A, parsed[1] as B, parsed[2] as C));
}

extension PathCap3<A, B, C> on Path<(A, B, C)> {
  Path<(A, B, C, D)> cap<D>(Capture<D> capture) => Path<(A, B, C, D)>._(
    [...segments, CaptureSegment(capture)],
    (parsed) =>
        (parsed[0] as A, parsed[1] as B, parsed[2] as C, parsed[3] as D),
  );
}

/// Desugars a string pattern such as `'/users/:id'` into a [Path]. Every
/// `:name` becomes a `Capture<String>`; typed parsing happens later at
/// `c.param<T>`. The result is `Path<dynamic>` — the string form never drives
/// the typed two-argument handler.
Path<dynamic> parsePathString(String pattern) {
  var path = root as Path<dynamic>;
  for (final raw in _splitSegments(pattern)) {
    if (raw.startsWith(':')) {
      final name = raw.substring(1);
      if (name.isEmpty) {
        throw ArgumentError.value(pattern, 'pattern', 'empty capture name');
      }
      path = _appendCapture(path, named(str, name));
    } else {
      path = path.lit(raw);
    }
  }
  return path;
}

/// Appends a capture to a `Path<dynamic>` without changing the static type
/// (the string syntax carries no tuple; captures are read via `c.param`).
Path<dynamic> _appendCapture(Path<dynamic> path, Capture<Object?> capture) =>
    Path<dynamic>._([
      ...path.segments,
      CaptureSegment(capture),
    ], path.buildTuple);

Iterable<String> _splitSegments(String pattern) =>
    pattern.split('/').where((s) => s.isNotEmpty);

/// The human-readable template of [segments]: literals verbatim, captures as
/// `:name`. Used for log and access-log route fields.
String templateOf(List<Segment> segments) {
  if (segments.isEmpty) return '/';
  final buf = StringBuffer();
  var index = 0;
  for (final s in segments) {
    buf.write('/');
    switch (s) {
      case LiteralSegment(:final value):
        buf.write(value);
      case CaptureSegment(:final capture):
        buf.write(':${capture.name ?? 'p$index'}');
        index++;
    }
  }
  return buf.toString();
}

/// The route-conflict key: literals verbatim, every capture collapsed to `*`
/// so two routes that differ only in capture names count as a conflict.
String conflictKey(String method, List<Segment> segments) {
  final buf = StringBuffer(method);
  for (final s in segments) {
    buf.write('/');
    buf.write(s is LiteralSegment ? s.value : '*');
  }
  return buf.toString();
}
