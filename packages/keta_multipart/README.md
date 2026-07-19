# keta_multipart

`multipart/form-data` reception for keta, as an Optional Ring 3 adapter: it consumes `c.bodyStream()` and yields a `Stream<Part>`, delegating boundary parsing to `package:mime`. keta core learns no multipart vocabulary — peel this package off and nothing inward notices. The package itself never touches the filesystem; persisting an upload is the caller's job, done off `Part.stream` without ever holding the file in memory.

## The entry point

One top-level function: `Stream<Part> parts<E>(Context<E> c, {MultipartLimits limits = const MultipartLimits()})`. A non-multipart request, or a `multipart/form-data` request missing its boundary, throws `BadRequest` (400) — and the media type is *parsed* and compared for equality, not `startsWith`-matched, so an unrelated type that merely shares the prefix (`multipart/form-data-x`) is rejected too.

```dart
import 'package:keta/keta.dart';
import 'package:keta_multipart/keta_multipart.dart';

app.post('/upload', (c) async {
  final fields = <String, String>{};
  await for (final p in parts(c)) {
    if (p.filename != null) {
      await for (final chunk in p.stream) {
        // persist the file chunk-by-chunk; nothing is buffered for you
      }
    } else {
      fields[p.name ?? ''] = await p.text();
    }
  }
  return c.json({'fields': fields});
});
```

## The Part model

A `Part` exposes `headers` (lower-cased by the MIME parser), `name` (the form field's name, or null), and `filename` (set for a file part, null for a plain field). Its body has exactly three read paths: `stream` (the deliberate unbuffered path, a raw `Stream<List<int>>`), `bytes()` (buffered into a `Uint8List`), and `text()` (UTF-8 decoded). All three are bounded by `maxPartBytes` — the API owns the size limit, the caller never has to.

A part's body may be requested **at most once**, via exactly one of the three paths; a second request throws `StateError` (the backing MIME stream is single-subscription). `name` and `filename` come from a memoized `Content-Disposition` parse using the platform's RFC-compliant `HeaderValue` parser: backslash-escaped quotes inside a quoted `filename` are preserved, bare unquoted tokens (legal, emitted by non-browser clients) are read, parameter names match case-insensitively, and a duplicated parameter is last-wins. A malformed disposition header degrades to null on every read rather than tearing down the stream from a synchronous getter. RFC 5987 extended values (`filename*=`) are unsupported **by design**: they land under the distinct key `filename*`, so a percent-encoded name reads as absent rather than being mis-decoded.

## Limits

Reception rides the deliberate `c.bodyStream()` escape, so **`App.maxBodyBytes` does not apply here — this layer owns the limits**, via `MultipartLimits`:

| Limit | Default | On breach |
|---|---|---|
| `maxTotalBytes` | 8 MiB (`8 * 1024 * 1024`) | `PayloadTooLarge` (413) |
| `maxPartBytes` | 1 MiB (`1024 * 1024`) | `PayloadTooLarge` (413) |
| `maxParts` | 64 | `BadRequest` (400) |

`maxTotalBytes` meters the whole body while streaming — bytes in parts the consumer skips still count, so an attacker cannot hide payload in unread parts. `maxPartBytes` is enforced on every read path, the unbuffered `stream` included: the stream throws the moment cumulative bytes exceed the cap, never silently bypassing it. A part-count flood is a malformed/abusive request rather than an oversized payload, which is why exceeding `maxParts` is a 400, not a 413. All of these are keta exceptions, so keta's error path renders the status.

## Skipping and out-of-order consumption

Parts need not be read at all: when the consumer advances past a part whose body was never listened to, `parts` drains that body for it — charged to `maxTotalBytes` — because the MIME parser only surfaces the next part once the current body is consumed. This holds even for a part whose `stream` was requested and then dropped without a listener (`stream` is lazy; requesting is not reading), so a skipped or half-claimed part can neither deadlock the request nor smuggle uncounted bytes. The corollary: read a part's body eagerly, or not at all — a stream stashed away to listen to "later" finds its source already drained, and the late `.listen()` surfaces a `StateError` as an error event rather than quietly yielding nothing.

## What package:mime handles

Boundary mechanics are delegated, and the edges are pinned by tests here rather than assumed: an RFC 2046 preamble before the first boundary and epilogue after the closing one are discarded, and boundary-like bytes inside a body (inline `--B`, lone `--`, a different boundary token) round-trip verbatim. On the request side, a case-insensitive `Boundary=` parameter name is honored and a quoted boundary containing `;` (legal per RFC 2046) stays intact where a naive `split(';')` would mangle it; an empty `boundary=` is a `BadRequest`.

## Every claim here is tested

The project gate is that each documented invariant has a test. All of this package's tests live in `test/multipart_test.dart`; the map, by test group:

| Claim | Test |
|---|---|
| fields and files yield with `name` / `filename` / `text()` | `test/multipart_test.dart` (top-level) |
| non-multipart, and a media type merely sharing the prefix, are `BadRequest` | `test/multipart_test.dart` — `content-type validation` |
| `maxPartBytes` on both `bytes()` and `stream`; `maxTotalBytes`; `maxParts` is 400, not 413 | `test/multipart_test.dart` — `size and count limits` |
| escaped quotes, bare tokens, case-insensitive parameter names, `filename*=` reads as absent, malformed header degrades to null (memoized), duplicate parameter is last-wins | `test/multipart_test.dart` — `Content-Disposition parsing` |
| case-insensitive `Boundary=`, quoted boundary with `;`, missing or empty boundary is `BadRequest` | `test/multipart_test.dart` — `boundary parsing` |
| skipping never hangs; skipped bytes still count toward `maxTotalBytes`; a second body read is `StateError`; a claimed-but-unlistened `stream` is drained and counted | `test/multipart_test.dart` — `out-of-order / partial consumption` |
| preamble/epilogue discarded; boundary-like bytes inside a body preserved verbatim | `test/multipart_test.dart` — `package:mime integration edges` |
