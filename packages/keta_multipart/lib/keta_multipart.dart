/// keta_multipart — multipart/form-data reception. Consumes `c.bodyStream()`
/// and yields a `Stream<Part>`, delegating boundary parsing to package:mime.
/// The core holds no multipart vocabulary; this is an Optional Ring 1 adapter.
library;

export 'src/multipart.dart' show MultipartLimits, Part, parts;
