/// keta — a reflection-free, codegen-free HTTP server framework for Dart.
///
/// Ring 0 Foundation: routing, [Context], middleware, [App]/[Server], [Log],
/// and the default HTTP/1.1 transport. Depends on nothing but the SDK.
library;

export 'src/app.dart'
    show
        App,
        RouteGroup,
        Route,
        RouteEntry,
        Router,
        Server,
        Handler,
        Middleware,
        TypedHandler,
        HasLog,
        Disposable;
export 'src/chain.dart' show chain, guard;
export 'src/context.dart' show Context, Key;
export 'src/h1_transport.dart' show H1Transport;
export 'src/log.dart' show Log, StdoutLog;
export 'src/middleware.dart'
    show accessLog, recover, cors, timeout, tracing, TraceContext, traceKey;
export 'src/response.dart'
    show
        Response,
        KetaException,
        BadRequest,
        Unauthorized,
        Forbidden,
        NotFound,
        Conflict,
        PayloadTooLarge,
        UnprocessableEntity,
        NotImplementedYet,
        Unavailable,
        GatewayTimeout;
export 'src/routing.dart'
    show
        Capture,
        Path,
        PathCapture0,
        PathCapture1,
        PathCapture2,
        PathCapture3,
        Segment,
        LiteralSegment,
        CaptureSegment,
        root,
        string,
        integer,
        number,
        boolean;
export 'src/transport.dart' show Transport, TransportRequest, TransportServer;
