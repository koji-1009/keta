# keta_static

Static assets as a **prefix-scoped middleware**, not a wildcard route.

```dart
app.use(recover());
app.use(staticFiles(
  prefix: '/assets',
  source: DirectoryAssets(Directory('public')),
));
```

A wildcard route would have to win or lose against every other route under the same prefix, and the routing table would carry a pattern that means "anything". A middleware does not: a request that does not match `prefix`, or names no asset, calls `next(c)`, so ordinary routes live under the same prefix and a miss becomes the application's own 404 rather than one this mount invents. Only `GET` and `HEAD` are answered — `POST /assets/x` passes through to whatever the application registered.

## What it answers with

Everything below reads or writes a **typed header from core**, rather than re-parsing strings:

- a strong `ETag`, and `304` for a matching `If-None-Match`
- `206` with `Content-Range` for a single byte `Range`, `416` when unsatisfiable
- `Accept-Ranges: bytes`, so a client knows ranges are worth asking for
- the configured `Cache-Control` (default: `public, max-age=3600`)

The conditional check precedes the range check (RFC 9110 §13.1.3): a client whose cached copy is current gets a `304`, and asking for a range of a representation it already has does not change that.

## `AssetSource` is the seam

Bytes arrive through one interface, so where they live is not this package's business:

| Source | For |
|---|---|
| `DirectoryAssets(Directory)` | files on disk |
| `MemoryAssets.ofText({path: string})` | text held in hand, and tests |
| `MemoryAssets.ofBytes({path: bytes})` | assets compiled into the binary |
| `MemoryAssets({path: Asset})` | full control of each `Asset` (its own `etag`, an explicit content type) |

`MemoryAssets` also takes `indexFile` (default `index.html`), served for a request that names a directory.

Implement `AssetSource` for anything else (an object store, an embedded archive). `resolve(path)` returns an `Asset` — bytes, content type, length, `etag` — or `null` for a miss.

## Placement

It produces a response, so it belongs **inside `recover()`**.

It deliberately carries **no `MiddlewareOrder`**. Whether assets sit inside or outside authentication is the application's call — a public `/assets` mount goes outside, a mount serving a customer's private files goes inside — and a rank shipped here would be that decision made by the wrong party.

## Path handling, exactly

`Uri.path` has already been percent-decoded and dot-segment-normalized by the time a handler sees it, so `/assets/%2e%2e/secret` arrives as `/secret` and never matches this mount at all. The `..` and `\` guards in `_relativePath` are a second line for a caller that hands in a path some other way; over HTTP they are unreachable.

**Dotfiles are refused.** A segment beginning with `.` is a 404, so `/assets/.env` and `/assets/.git/config` are not answered even when the mounted directory holds them. A mount points at a directory of things meant to be public, and a dotfile in it is there for the toolchain; serving it lets the directory layout decide what is disclosed. There is no opt-out — an asset a client is meant to fetch can be named without a leading dot.

**Percent-encoded names do not resolve.** The relative path is matched against `Uri.path` without decoding the characters the URI form keeps escaped, so an asset whose name contains a space, a non-ASCII character, or `%` is unreachable (`/assets/a%20b.js` → 404 even though `a b.js` exists). Stated here rather than left to be discovered.

## Scope

Serving bytes that already exist. Not: compression at rest (`gzip()` from core composes over this), directory listings, template rendering, or upload.
