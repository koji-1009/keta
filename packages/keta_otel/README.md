# keta_otel

OpenTelemetry for keta, in two small pieces: an `otel()` middleware that records one server span per request and feeds an in-process metrics registry, and an `OtlpExporter` that batches those spans out as OTLP/JSON over HTTP. There is no external OpenTelemetry SDK anywhere — the package's only dependency is `keta` itself, and the OTLP envelope is hand-encoded.

## One middleware, two sinks

`otel<E>({exporter, metrics, exportUnsampled})` takes both sinks as optional arguments — metrics-only, traces-only, or both from the same middleware. Recording happens after the response is produced and never blocks or fails the request: handing a span to the exporter is a synchronous append to the exporter's own bounded queue, never a network call, so a slow or dead collector costs the request path nothing. A failing export is reported through the exporter's `onWarn` hook (wired once, at construction), not through any request's context. A handler that throws still records: a `KetaException` records under its own status, anything else under 500, and the error is rethrown unchanged.

```dart
import 'package:keta/keta.dart';
import 'package:keta_otel/keta_otel.dart';

final metrics = MetricsRegistry();
final exporter = OtlpExporter.http(
  Uri.parse('http://localhost:4318/v1/traces'),
  serviceName: 'my-service',
);

final app = App<Env>()..use(otel(exporter: exporter, metrics: metrics));
app.get('/users/:id', (c) => c.json({'id': c.param<String>('id')}));
app.get('/metrics', metricsHandler(metrics));
```

## Trace context: what is honored, what is minted

An incoming W3C `traceparent` goes through core's hardened `TraceContext.parse` — one parser for the whole stack, not a second copy here. A valid header's trace id is continued and its parent id becomes the span's `parentSpanId`; *any* violation (wrong field widths, uppercase or non-hex ids, the all-zero sentinels, reserved version `ff`, a malformed flags octet) treats the header as absent and starts a new root trace — a garbage header never surfaces as an error, and a garbage id never reaches an OTLP batch a strict collector would reject wholesale. The span id itself is always freshly minted (16 lowercase hex from `Random.secure()`), never taken from the header.

The upstream sampling decision is honored by default: a valid `traceparent` with the sampled bit clear means the span is never enqueued for export — metrics still record. `exportUnsampled: true` overrides that and exports every span. A root request (no valid header) defaults to sampled.

`otel()` exposes the request's trace identity to handlers as an `OtelSpanContext` under `otelSpanKey` — the (possibly continued) `traceId` plus the span id minted here. This is deliberately not core's `tracing()`/`traceKey`, and the two answer different questions: `traceKey` is "who called me" (the incoming header's ids, verbatim, or nothing), `otelSpanKey` is "what span am I" — the ids to stamp into log lines or fold into an outbound `00-$traceId-$spanId-01` so a downstream service continues the trace.

## What a span carries

Each request yields one span of OTel SERVER kind, named `METHOD /route/template`, with attributes `http.request.method`, `http.route`, and `http.response.status_code`. Status follows the SERVER-span convention: `Error` only for a 5xx response (499 is `Unset`, 500 is `Error` — a 4xx is a client problem, not a server error); a 2xx is `Unset`, not `Ok`. The wire format is OTLP/JSON — an `ExportTraceServiceRequest` body with `service.name` as a resource attribute, scope `keta_otel`, and the nanosecond timestamps as strings, POSTed with content-type `application/json` to whatever `v1/traces` endpoint you configure.

## Every label axis is bounded

The registry itself has no cap and no eviction — every distinct (method, route, status) key is a permanent series, by design. That is safe only because both attacker-controlled axes are folded *before* they reach it:

- **Route** is the low-cardinality route template (`/users/:id`, never `/users/42`), and a request that matches no route records under the fixed `(unmatched)` label — the raw, attacker-controlled path never appears in a label or a span. The unmatched span is also path-free: named just `METHOD`, with no `http.route` attribute (OTel semconv for an unmatched SERVER span).
- **Method** is folded to the closed set of seven keta verbs, matched case-insensitively and normalized to uppercase; anything else — and the HTTP request line accepts any token — folds to the fixed `(other)` label, in the metrics key, the span name, and the `http.request.method` attribute alike. Five hundred distinct bogus verbs mint one series, not five hundred.

## The exporter: batching, backpressure, bounded shutdown

Spans accumulate in a bounded queue that a periodic timer drains in batches, mirroring OTel's BatchSpanProcessor defaults — 2048 queued, 512 per POST, 5s between drains (`exportInterval: Duration.zero` disables the timer; draining then happens only via `flush()`). Past `maxQueueSize` the oldest queued span is evicted (drop-oldest), and the loss is never silent: evictions and failed batches alike are counted and reported through `onWarn` at the next *successful* export — deferred, not dropped.

`OtlpExporter.http` bounds every way a collector can misbehave. Each POST's whole request/response cycle is capped by `timeout` (default 10s), and a timeout `abort()`s the in-flight request — actually tearing down the socket, not just abandoning the Future — while the same `timeout` doubles as the client's `connectionTimeout` so a blackholed connect phase is bounded too. A 429/503 is retried (default: 2 retries after the first attempt) honoring `Retry-After` only in its delta-seconds form, clamped to `maxRetryDelay` (default 5s) — the header is collector-controlled, so a 63-year value can never park a batch; every other non-2xx is terminal. A retrying batch holds only its own spans and never head-of-line-blocks newer batches. `flush()` drains fully, including spans enqueued mid-flush; `close()` fires a shutdown signal that cuts any batch mid-retry-sleep, flushes, cancels the timer, and force-closes the client — bounded in wall-clock time regardless of collector behavior. For tests or custom transports, the plain `OtlpExporter(send)` constructor takes any `OtlpSender` in place of the HTTP one; `export(spans)` sends immediately, bypassing the queue.

`OtlpExporter` implements keta's `Disposable`: when your `Env` implements `Disposable` and closes the exporter from its `close()`, `Server.shutdown` drains in-flight requests and then drives that close, so pending spans land before the process exits — the same Env-owned lifecycle keta_bus's connection uses.

```dart
class Env implements Disposable {
  Env(this.exporter);
  final OtlpExporter exporter;
  @override
  Future<void> close() => exporter.close(); // Server.shutdown drives this
}
```

## The /metrics endpoint

`metricsHandler(registry)` is an ordinary handler — mount it at `/metrics` — that renders the registry in Prometheus text exposition format, served with the full media type `text/plain; version=0.0.4; charset=utf-8` (the `version` parameter is how a scraper recognizes the format). Two metric families, each labeled `method`/`route`/`status`: `keta_requests_total` (a counter) and `keta_request_duration_seconds` (a *histogram* — cumulative `_bucket{le=...}` lines, the implicit `+Inf` bucket, `_sum`, and `_count` — so `histogram_quantile` can answer "what's p95" later; a summary's `_sum`/`_count` alone cannot). Durations are recorded in fractional seconds from microsecond resolution, so a sub-millisecond handler never truncates to 0. Label values are backslash-escaped (`\`, `"`, newline, and CR), so no route string can desync the exposition framing.

The default buckets are Prometheus's own conventional boundaries, 5ms to 10s; `MetricsRegistry(buckets: ...)` replaces them wholesale, and the list is validated at construction — non-empty, strictly ascending, finite, positive, with `+Inf` implicit and rejected if listed explicitly. Size a custom list knowing each (method, route, status) key renders `buckets.length + 3` duration lines per scrape.

## Judged absences

Deliberate, per the source's own documentation — not TODOs: no dependency on an external OpenTelemetry SDK (the OTLP envelope is hand-encoded); the registry has no cap or eviction (safe because the label axes are pre-bounded — do not `record` raw attacker-controlled values into it); `Retry-After` is honored only in delta-seconds form, never the HTTP-date form (a bogus or date value falls back to the fixed backoff rather than failing the send).

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| a span continues a valid incoming `traceparent`; each malformed variant falls back to a new root trace | `test/otel_test.dart` |
| an unsampled `traceparent` is not exported but metrics still record; `exportUnsampled` overrides | `test/otel_test.dart` |
| `otelSpanKey` exposes the traceId/spanId that appear on the exported span; a root request gets minted ids | `test/otel_test.dart` |
| status: 5xx is `Error`, 4xx is `Unset`, the 499/500 boundary is exact; thrown `KetaException`s record their own status | `test/otel_test.dart` |
| unmatched requests record under `(unmatched)` with a path-free span name; the raw path never appears | `test/otel_test.dart` |
| 500 distinct bogus methods mint one `(other)` series; a lowercase known verb folds to its uppercase label | `test/otel_test.dart` |
| a synchronously-throwing or async-rejecting sender never fails the request; failures surface via `onWarn` | `test/otel_test.dart` |
| enqueues coalesce into batched POSTs; oversized backlogs split at `maxBatchSize`; drop-oldest is reported once, deferred to the next successful export | `test/otel_test.dart` |
| export is deferred off the request path; `flush()` drains and awaits, looping until quiescent (including spans enqueued mid-flush); `close()` cancels the periodic timer | `test/otel_test.dart`, `test/otlp_http_test.dart` |
| the OTLP/JSON envelope: SERVER kind, string nanos, `service.name` resource attribute, typed attribute encoding | `test/otel_test.dart` |
| `OtlpExporter.http` POSTs OTLP JSON with configured headers; a non-2xx response is a failure, not a silent ok | `test/otlp_http_test.dart` |
| a collector that accepts and never responds times out and its socket is actually torn down; `connectionTimeout` is wired to `timeout` | `test/otlp_http_test.dart` |
| 429/503 are retried honoring `Retry-After`; a huge `Retry-After` is clamped to `maxRetryDelay`; a persistent 503 exhausts retries and the drop is reported on the next success | `test/otlp_http_test.dart` |
| `close()` cuts a batch mid-retry-sleep and completes promptly; retry sleeps never accumulate | `test/otlp_http_test.dart` |
| Prometheus exposition: the `version=0.0.4` content type, histogram shape (`_bucket`/`le`/`+Inf`/`_sum`/`_count`), cumulative monotonicity, `le` as `<=` at the edges, label escaping including CR, fractional non-zero durations | `test/metrics_test.dart`, `test/otel_test.dart` |
| bucket validation rejects empty, non-ascending, non-positive, explicit `+Inf`, and NaN lists; custom buckets replace the defaults wholesale | `test/metrics_test.dart` |
