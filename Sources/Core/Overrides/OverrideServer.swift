import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// The loopback HTTP server a diverted device request lands on.
///
/// `ProxyServer`'s non-CONNECT branch without the TLS: divert traffic always arrives as cleartext
/// origin-form HTTP. That's also why it beats a MITM proxy on a pinned app — no TLS happens
/// app-side, so `CertificatePinner` never engages.
///
/// Bound to **127.0.0.1 only** (`ProxyServer` binds `0.0.0.0` for LAN devices): `adb reverse`
/// delivers on loopback, which is safer for a channel that is cleartext by construction.
final class OverrideServer: @unchecked Sendable {
    private let pipeline: InterceptPipeline
    private let transport: InterceptTransportID
    private let deviceID: String?
    private let appID: String?
    /// What the wired capture source declared it can honour, so the clamp applied here is the
    /// value the toolbar shows.
    private let capabilities: InterceptCapabilities
    private var channel: Channel?

    /// Accepted connections, so `stop()` can close them too. `writeResponse` forces
    /// `Connection: keep-alive`, so closing only the listener left children still answering
    /// requests after the tab had stopped.
    private let childLock = NSLock()
    private var children: [ObjectIdentifier: Channel] = [:]
    /// Set by `stop()`. `channel.close` is async, so a connection accepted between it and
    /// `takeChildren()` would register after the drain and never be closed.
    private var stopped = false

    /// The actually-bound port. Read after `start()`; the coordinator hands it to the tunnel.
    var boundPort: Int { channel?.localAddress?.port ?? 0 }

    init(pipeline: InterceptPipeline,
         transport: InterceptTransportID,
         deviceID: String? = nil,
         appID: String? = nil,
         capabilities: InterceptCapabilities) {
        self.pipeline = pipeline
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
        self.capabilities = capabilities
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: NIOGroups.shared)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [pipeline, transport, deviceID, appID, capabilities, weak self] channel in
                self?.track(channel)
                return channel.pipeline.addHandler(HTTPResponseEncoder(), name: "encoder").flatMap {
                    channel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "decoder")
                }.flatMap {
                    channel.pipeline.addHandler(
                        OverrideHandler(pipeline: pipeline, transport: transport,
                                        deviceID: deviceID, appID: appID,
                                        capabilities: capabilities),
                        name: "override")
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    /// Closes the listener, but not the process-wide `NIOGroups.shared` group — so tearing a
    /// session down never blocks a thread.
    func stop() {
        childLock.lock(); stopped = true; childLock.unlock()
        channel?.close(promise: nil)
        channel = nil
        for child in takeChildren() { child.close(promise: nil) }
    }

    private func track(_ child: Channel) {
        let key = ObjectIdentifier(child)
        childLock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { children[key] = child }
        childLock.unlock()
        guard !alreadyStopped else { return child.close(promise: nil) }
        child.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.childLock.lock()
            self.children.removeValue(forKey: key)
            self.childLock.unlock()
        }
    }

    private func takeChildren() -> [Channel] {
        childLock.lock()
        defer { childLock.unlock() }
        let all = Array(children.values)
        children.removeAll()
        return all
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
    private let capabilities: InterceptCapabilities

    private var head: HTTPRequestHead?
    private var body = Data()
    /// Set once `body` would exceed `maxBodyBytes`; the request is bounced instead of buffered.
    private var bodyOverflowed = false

    /// A divert routes a *whole host*, so a multipart upload would otherwise buffer in full in
    /// Jaca's memory on an event-loop thread. Past this we bounce it and let the agent go direct.
    private static let maxBodyBytes = 8 * 1024 * 1024

    init(pipeline: InterceptPipeline, transport: InterceptTransportID,
         deviceID: String?, appID: String?, capabilities: InterceptCapabilities) {
        self.pipeline = pipeline
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
        self.capabilities = capabilities
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            bodyOverflowed = false
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            guard !bodyOverflowed else { return }
            if body.count + buffer.readableBytes > Self.maxBodyBytes {
                bodyOverflowed = true
                body.removeAll(keepingCapacity: false)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            if bodyOverflowed {
                JacaLog.warn("override", "body over \(Self.maxBodyBytes) bytes — sent direct: \(head.method) \(head.uri)")
                Self.writeRetryDirect(channel: context.channel)
            } else {
                handle(context: context, head: head, body: body)
            }
            self.head = nil
            bodyOverflowed = false
            body.removeAll(keepingCapacity: false)
        }
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let channel = context.channel
        let headers = head.headers.map { HeaderPair(name: $0.name, value: $0.value) }

        // Streaming can't survive this hop: `UpstreamClient` buffers whole bodies and
        // `writeResponse` forces a Content-Length, so SSE/gRPC would hang end-to-end.
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
        let capabilities = self.capabilities
        Task {
            // `.handBack` matters: the device re-sends what we bounce, so fetching here too
            // would run every unmatched request twice — duplicating POSTs.
            let result = await pipeline.run(request, capabilities: capabilities,
                                            unmatched: .handBack)

            // Nothing matched — hand it back, keeping VPN, cookies, HTTP/2 and DNS intact for
            // everything we aren't mocking. That's what makes diverting a whole host safe.
            guard result.appliedRuleID != nil else {
                // The single most useful line when a rule "should have" fired.
                JacaLog.debug("override",
                    "no rule for \(request.method) \(url) — \(result.skipped?.message ?? "no match"); bouncing")
                channel.eventLoop.execute { Self.writeRetryDirect(channel: channel) }
                return
            }
            // `debug`, not `info`: once per answered request on an event loop, and
            // `JacaLog.append` is a synchronous write under a global lock.
            JacaLog.debug("override", "answered \(request.method) \(url) with \(result.response.statusCode)")
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

    /// The bounce: `599` + `X-Jaca-Divert: retry-direct`. The agent drops the exchange from
    /// capture and re-sends the original request itself.
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
