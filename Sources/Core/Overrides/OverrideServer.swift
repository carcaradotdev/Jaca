import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// The loopback HTTP server a diverted device request lands on.
///
/// Modelled on `ProxyServer`'s non-CONNECT branch, minus `handleConnect`/`upgradeToTLS` — divert
/// traffic always arrives as cleartext origin-form HTTP over the adb tunnel, so there is no TLS to
/// terminate here. That is also *why* the mechanism beats a MITM proxy on a pinned app: no TLS
/// happens app-side at all, so `CertificatePinner` never engages.
///
/// Bound to **127.0.0.1 only**, unlike `ProxyServer`, which deliberately binds `0.0.0.0` so a LAN
/// device can reach it. `adb reverse` delivers on loopback, so loopback is both sufficient and far
/// safer for a channel that is cleartext by construction.
final class OverrideServer: @unchecked Sendable {
    private let pipeline: InterceptPipeline
    private let transport: InterceptTransportID
    private let deviceID: String?
    private let appID: String?
    private let onTransaction: (@Sendable (NetworkTransaction) -> Void)?
    private var channel: Channel?

    /// The actually-bound port. Read after `start()`; the coordinator passes it to `adb reverse`.
    var boundPort: Int { channel?.localAddress?.port ?? 0 }

    init(pipeline: InterceptPipeline,
         transport: InterceptTransportID,
         deviceID: String? = nil,
         appID: String? = nil,
         onTransaction: (@Sendable (NetworkTransaction) -> Void)? = nil) {
        self.pipeline = pipeline
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
        self.onTransaction = onTransaction
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: NIOGroups.shared)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [pipeline, transport, deviceID, appID] channel in
                channel.pipeline.addHandler(HTTPResponseEncoder(), name: "encoder").flatMap {
                    channel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "decoder")
                }.flatMap {
                    channel.pipeline.addHandler(
                        OverrideHandler(pipeline: pipeline, transport: transport,
                                        deviceID: deviceID, appID: appID),
                        name: "override")
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    /// Closes the listener. Deliberately does **not** shut down the event-loop group — it's shared
    /// process-wide (`NIOGroups.shared`), so tearing a session down never blocks a thread.
    func stop() {
        channel?.close(promise: nil)
        channel = nil
    }
}

// MARK: - Handler

private final class OverrideHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let pipeline: InterceptPipeline
    private let transport: InterceptTransportID
    private let deviceID: String?
    private let appID: String?

    private var head: HTTPRequestHead?
    private var body = Data()

    init(pipeline: InterceptPipeline, transport: InterceptTransportID,
         deviceID: String?, appID: String?) {
        self.pipeline = pipeline
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            handle(context: context, head: head, body: body)
            self.head = nil
            body.removeAll(keepingCapacity: false)
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let channel = context.channel
        let headers = head.headers.map { HeaderPair(name: $0.name, value: $0.value) }

        // Streaming responses can't survive this hop: `UpstreamClient` buffers whole bodies and
        // `writeResponse` forces a Content-Length, so an SSE/gRPC exchange would hang end-to-end.
        // Bounce it before touching upstream and let the device send it directly.
        if Self.isStreamingRequest(headers) {
            Self.writeRetryDirect(channel: channel)
            return
        }

        guard let url = AgentOriginalURL.recover(headers: headers, uri: head.uri) else {
            JacaLog.warn("override", "couldn't recover the original URL for \(head.method) \(head.uri)")
            Self.writeRetryDirect(channel: channel)
            return
        }

        let request = InterceptedRequest(
            method: head.method.rawValue,
            url: url,
            headers: headers,
            body: body.isEmpty ? nil : body,
            transport: transport,
            deviceID: deviceID,
            appID: appID
        )

        let pipeline = self.pipeline
        Task {
            // `.handBack` is essential, not cosmetic: the device re-sends anything we bounce, so
            // fetching it here too would run every unmatched request twice — duplicating POSTs.
            let result = await pipeline.run(request, capabilities: .desktopTerminated,
                                            unmatched: .handBack)

            // Nothing matched — hand it back so the device re-runs it on its own network. That
            // keeps VPN, cookies, HTTP/2 and DNS intact for every request we aren't mocking, and
            // is why diverting a whole host is safe.
            guard result.appliedRuleID != nil else {
                // The single most useful line when a rule "should have" fired.
                JacaLog.debug("override",
                    "no rule for \(request.method) \(url) — \(result.skipped?.message ?? "no match"); bouncing")
                channel.eventLoop.execute { Self.writeRetryDirect(channel: channel) }
                return
            }
            JacaLog.info("override", "answered \(request.method) \(url) with \(result.response.statusCode)")
            channel.eventLoop.execute {
                HTTPWireFormat.writeResponse(channel: channel, response: result.response)
            }
        }
    }

    /// Content types that never end, or that carry framing we can't reproduce.
    static func isStreamingRequest(_ headers: [HeaderPair]) -> Bool {
        guard let accept = headers.first(where: { $0.name.lowercased() == "accept" })?.value.lowercased()
        else { return false }
        return accept.contains("text/event-stream") || accept.contains("application/grpc")
    }

    /// The bounce: `599` + `X-Jaca-Divert: retry-direct`. The agent recognises this pair, drops
    /// the exchange from capture, and re-sends the original request itself.
    static func writeRetryDirect(channel: Channel) {
        HTTPWireFormat.writeResponse(channel: channel, response: InterceptedResponse(
            statusCode: OverrideHeaders.retryDirectStatus,
            headers: [HeaderPair(name: OverrideHeaders.divert, value: OverrideHeaders.retryDirect)],
            body: Data()
        ))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
