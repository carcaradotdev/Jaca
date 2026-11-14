import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

/// A man-in-the-middle HTTP(S) proxy. Clients point their device proxy at it;
/// for `CONNECT` it terminates TLS with a per-host leaf cert (signed by our CA),
/// reads the plaintext HTTP, and runs it through an `InterceptPipeline` (the override rules,
/// then the origin), emitting a `NetworkTransaction` per request/response. A tunnel that
/// doesn't start with TLS (Chrome sends a `ws://` WebSocket through `CONNECT` too) is relayed
/// to its target unread.
///
/// Two hooks narrow what it decrypts:
/// - `shouldDecrypt(host)`: a TLS tunnel to a host it rejects is relayed raw (a pinned app).
/// - `clientPolicy`: decides per client connection. `.relayRaw` forwards that client's traffic
///   without decrypting it and without a transaction (a Mac app on the system proxy);
///   `.intercept(target:)` decrypts it and attributes it to that target (one simulator).
final class ProxyServer: @unchecked Sendable {
    let port: Int
    private let ca: CertificateAuthority
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    /// (host, success) per MITM TLS handshake — success means the client trusted our leaf
    /// (CA installed → decryption works); failure means it rejected it (CA not trusted).
    private let onHandshake: (@Sendable (String, Bool) -> Void)?
    private let pipeline: InterceptPipeline
    private let target: ProxyInterceptTarget
    private let bindHost: String
    private let shouldDecrypt: @Sendable (String) -> Bool
    private let clientPolicy: (@Sendable (ProxyClientInfo) -> ProxyClientPolicy)?
    private let targetHooks: ProxyTargetHooks?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?

    /// The actually-bound port (useful when constructed with port 0).
    var boundPort: Int { channel?.localAddress?.port ?? port }

    /// `pipeline` defaults to no rules: every request goes to the origin, redirects unfollowed
    /// so the client re-requests each hop through the proxy. `bindHost` is every interface by
    /// default, for a device on the LAN; a proxy only this Mac uses binds loopback.
    ///
    /// `shouldDecrypt` is asked once per TLS tunnel with the `CONNECT` host; false relays the
    /// tunnel raw. `clientPolicy` is asked once per accepted client connection, on
    /// `policyQueue` (never on the event loop); nil treats every client as
    /// `.intercept(target: target)`.
    init(port: Int, ca: CertificateAuthority,
         pipeline: InterceptPipeline? = nil,
         target: ProxyInterceptTarget = ProxyInterceptTarget(),
         bindHost: String = "0.0.0.0",
         shouldDecrypt: @escaping @Sendable (String) -> Bool = { _ in true },
         clientPolicy: (@Sendable (ProxyClientInfo) -> ProxyClientPolicy)? = nil,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onHandshake: (@Sendable (String, Bool) -> Void)? = nil,
         targetHooks: ProxyTargetHooks? = nil) {
        self.port = port
        self.ca = ca
        self.pipeline = pipeline
            ?? InterceptPipeline(origin: OriginClient(upstream: UpstreamClient(), policy: .doNotFollow))
        self.target = target
        self.bindHost = bindHost
        self.shouldDecrypt = shouldDecrypt
        self.clientPolicy = clientPolicy
        self.onTransaction = onTransaction
        self.onHandshake = onHandshake
        self.targetHooks = targetHooks
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [ca, pipeline, target, shouldDecrypt, clientPolicy, onTransaction, onHandshake, targetHooks] channel in
                // The channel is not registered until this future completes, so no byte is read
                // before the policy is known. The hook can be slow (a libproc scan), so it runs on
                // its own queue and never blocks the event loop that serves other clients.
                let info = ProxyServer.clientInfo(channel)
                let decided: EventLoopFuture<ProxyClientPolicy>
                if let clientPolicy {
                    let promise = channel.eventLoop.makePromise(of: ProxyClientPolicy.self)
                    ProxyServer.policyQueue.async { promise.succeed(clientPolicy(info)) }
                    decided = promise.futureResult
                } else {
                    decided = channel.eventLoop.makeSucceededFuture(.intercept(target: target))
                }
                return decided.flatMap { policy in
                let connection: ProxyHandler.Connection
                let emit: @Sendable (NetworkTransaction) -> Void
                let report: (@Sendable (String, Bool) -> Void)?
                switch policy {
                case .intercept(let target):
                    if let hooks = targetHooks {
                        connection = ProxyHandler.Connection(target: target, raw: false, shouldDecrypt: {
                            shouldDecrypt($0) && hooks.shouldDecrypt(target, $0)
                        })
                        emit = { onTransaction($0); hooks.onTransaction(target, $0) }
                        report = { onHandshake?($0, $1); hooks.onHandshake(target, $0, $1) }
                    } else {
                        connection = ProxyHandler.Connection(target: target, raw: false, shouldDecrypt: shouldDecrypt)
                        emit = onTransaction
                        report = onHandshake
                    }
                case .relayRaw:
                    connection = ProxyHandler.Connection(target: target, raw: true, shouldDecrypt: { _ in false })
                    emit = onTransaction
                    report = onHandshake
                }
                return channel.pipeline.addHandler(HTTPResponseEncoder(), name: "encoder").flatMap {
                    channel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "decoder"
                    )
                }.flatMap {
                    channel.pipeline.addHandler(
                        ProxyHandler(ca: ca, pipeline: pipeline, connection: connection,
                                     onTransaction: emit, onHandshake: report, mode: .initial),
                        name: "proxy"
                    )
                }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Bind on all interfaces, not just loopback: a physical device reaches the
        // proxy over the LAN at this Mac's IP, so 127.0.0.1 would be unreachable and
        // (because the device proxy is set) break all of its web traffic. Emulators
        // still work — 10.0.2.2 maps to the host loopback, which 0.0.0.0 includes.
        channel = try bootstrap.bind(host: bindHost, port: port).wait()
    }

    /// Terminal — the owner drops the instance right after — and non-blocking: `close().wait()`
    /// and `syncShutdownGracefully()` park the calling thread, which is the main actor when a tab
    /// closes, freezing the UI until the handshakes in flight unwind.
    func stop() {
        let group = self.group
        channel?.close(promise: nil)
        channel = nil
        DispatchQueue.global(qos: .utility).async { try? group.syncShutdownGracefully() }
    }

    /// Where `clientPolicy` runs. Concurrent, so one slow lookup does not delay the next client.
    static let policyQueue = DispatchQueue(label: "jaca.proxy.client-policy", qos: .userInitiated,
                                           attributes: .concurrent)

    /// The client and local addresses of an accepted connection. Empty host and 0 ports when
    /// the socket has no address (it closed before the initializer ran).
    static func clientInfo(_ channel: Channel) -> ProxyClientInfo {
        ProxyClientInfo(remoteHost: channel.remoteAddress?.ipAddress ?? "",
                        remotePort: channel.remoteAddress?.port ?? 0,
                        localPort: channel.localAddress?.port ?? 0)
    }

    /// The policy for one client: the hook's answer, or `.intercept(target: defaultTarget)` when
    /// there is no hook.
    static func resolvePolicy(_ hook: (@Sendable (ProxyClientInfo) -> ProxyClientPolicy)?,
                              info: ProxyClientInfo,
                              defaultTarget: ProxyInterceptTarget) -> ProxyClientPolicy {
        hook?(info) ?? .intercept(target: defaultTarget)
    }

    /// The host and port of a `CONNECT` target: "host:port", or "[v6]:port". 443 when the
    /// port is missing or unreadable.
    static func connectTarget(_ authority: String) -> (host: String, port: Int) {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            return (host, Int(authority[authority.index(after: close)...].dropFirst()) ?? 443)
        }
        let parts = authority.split(separator: ":", maxSplits: 1)
        return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 443 : 443)
    }

    /// The URL of a request inside a `CONNECT` tunnel: the port only when it isn't 443.
    static func tunnelURL(host: String, port: Int, path: String) -> String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == 443 ? "https://\(name)\(path)" : "https://\(name):\(port)\(path)"
    }
}

/// Who a proxy's requests come from, for rules scoped to a device or an app.
struct ProxyInterceptTarget: Sendable, Equatable {
    var deviceID: String?
    var appID: String?
}

/// Hooks that also receive the target of an intercepted client. One proxy that serves several
/// devices uses them to route each transaction and handshake to the capture of its device.
struct ProxyTargetHooks: Sendable {
    /// Asked with `shouldDecrypt`; a TLS tunnel is decrypted only when both return true.
    var shouldDecrypt: @Sendable (ProxyInterceptTarget, String) -> Bool
    /// Called after `onTransaction`, with the same transaction.
    var onTransaction: @Sendable (ProxyInterceptTarget, NetworkTransaction) -> Void
    /// Called after `onHandshake`, with the same host and result.
    var onHandshake: @Sendable (ProxyInterceptTarget, String, Bool) -> Void
}

/// One accepted client connection, as `ProxyServer.clientPolicy` sees it.
struct ProxyClientInfo: Sendable, Equatable {
    /// The client's IP address ("127.0.0.1", "::1").
    var remoteHost: String
    /// The client's source port. With `remoteHost` it finds the client socket's process.
    var remotePort: Int
    /// The proxy port the client connected to.
    var localPort: Int
}

/// What `ProxyServer` does with one client connection.
enum ProxyClientPolicy: Sendable, Equatable {
    /// Decrypt and record its requests, attributed to `target`.
    case intercept(target: ProxyInterceptTarget)
    /// Forward its `CONNECT` tunnels and absolute-URI requests to the origin as they are: no
    /// decryption, no override rules, no transaction.
    case relayRaw
}

// MARK: - Handler

private final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    enum Mode {
        case initial            // first request on a connection (CONNECT or absolute-URI)
        case tls(host: String, port: Int)  // after CONNECT + TLS upgrade; origin-form requests
    }

    /// What the client policy decided for this client connection.
    struct Connection: Sendable {
        var target: ProxyInterceptTarget
        /// Relay without decryption, rules or transactions.
        var raw: Bool
        var shouldDecrypt: @Sendable (String) -> Bool
    }

    private let ca: CertificateAuthority
    private let pipeline: InterceptPipeline
    private let connection: Connection
    private var target: ProxyInterceptTarget { connection.target }
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onHandshake: (@Sendable (String, Bool) -> Void)?
    private let mode: Mode

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = Data()

    init(ca: CertificateAuthority, pipeline: InterceptPipeline, connection: Connection,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onHandshake: (@Sendable (String, Bool) -> Void)?, mode: Mode) {
        self.ca = ca
        self.pipeline = pipeline
        self.connection = connection
        self.onTransaction = onTransaction
        self.onHandshake = onHandshake
        self.mode = mode
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer.removeAll(keepingCapacity: true)
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                bodyBuffer.append(contentsOf: bytes)
            }
        case .end:
            guard let head = requestHead else { return }
            if head.method == .CONNECT {
                handleConnect(context: context, head: head)
            } else if connection.raw {
                forwardRaw(context: context, head: head, body: bodyBuffer)
            } else {
                forward(context: context, head: head, body: bodyBuffer)
            }
        }
    }

    // MARK: CONNECT → TLS upgrade, or a relay

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let (host, port) = ProxyServer.connectTarget(head.uri)
        // Stop delivering inbound bytes until the tunnel's handler is installed, so the
        // client's first bytes (sent right after our 200) aren't read by the stale
        // HTTP decoder mid-reconfiguration.
        let channel = context.channel
        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        var resHead = HTTPResponseHead(
            version: head.version,
            status: .custom(code: 200, reasonPhrase: "Connection Established")
        )
        resHead.headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(resHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { [weak self] _ in
            self?.startTunnel(channel: channel, host: host, port: port)
        }
    }

    /// Swaps the HTTP handlers for a sniffer that reads the tunnel's first bytes.
    private func startTunnel(channel: Channel, host: String, port: Int) {
        let pipeline = channel.pipeline
        let sniffer = TunnelSniffer(host: host, port: port, shouldDecrypt: connection.shouldDecrypt,
                                    tls: { [self] in try tlsHandlers(host: host, port: port) })
        pipeline.removeHandler(name: "decoder")
            .flatMap { pipeline.removeHandler(name: "encoder") }
            .flatMap { pipeline.removeHandler(name: "proxy") }
            .flatMap { pipeline.addHandler(sniffer, name: "sniffer") }
            .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
            .whenComplete { result in
                switch result {
                case .success: channel.read()
                case .failure: channel.close(promise: nil)
                }
            }
    }

    /// The handlers that decrypt a TLS tunnel and read the HTTP inside it, in pipeline order.
    private func tlsHandlers(host: String, port: Int) throws -> [ChannelHandler] {
        let sslHandler = NIOSSLServerHandler(context: try ca.serverContext(forHost: host))
        return [
            sslHandler,
            HandshakeObserver(host: host, report: onHandshake),
            HTTPResponseEncoder(),
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
            ProxyHandler(ca: ca, pipeline: self.pipeline, connection: connection, onTransaction: onTransaction,
                         onHandshake: onHandshake, mode: .tls(host: host, port: port)),
        ]
    }

    // MARK: Forwarding

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let urlString: String
        let host: String
        let scheme: String
        switch mode {
        case .tls(let connectHost, let port):
            host = connectHost
            scheme = "https"
            urlString = ProxyServer.tunnelURL(host: connectHost, port: port, path: head.uri)
        case .initial:
            scheme = "http"
            urlString = head.uri            // absolute-form for plain proxying
            host = URL(string: head.uri)?.host ?? head.headers.first(name: "Host") ?? ""
        }

        guard URL(string: urlString) != nil else {
            writeError(context: context, message: "Invalid URL: \(urlString)")
            return
        }

        let requestHeaders = head.headers.map { HeaderPair(name: $0.name, value: $0.value) }
        var txn = NetworkTransaction(
            method: head.method.rawValue, url: urlString, host: host, scheme: scheme,
            requestHeaders: requestHeaders, requestBody: body.isEmpty ? nil : body
        )
        onTransaction(txn)   // in-flight

        // The pipeline drops hop-by-hop and X-Jaca-* headers before the origin sees them.
        let request = InterceptedRequest(
            id: txn.id, method: head.method.rawValue, url: urlString, headers: requestHeaders,
            body: body.isEmpty ? nil : body, transport: .mitmProxy,
            deviceID: target.deviceID, appID: target.appID, startedAt: txn.startedAt
        )
        let channel = context.channel
        let emit = onTransaction
        Task { [pipeline] in
            let result = await pipeline.run(request, capabilities: .desktopTerminated,
                                            unmatched: .fetchFromOrigin)
            let response = result.response
            channel.eventLoop.execute {
                HTTPWireFormat.writeResponse(channel: channel, response: response)
            }
            txn.statusCode = response.error == nil ? response.statusCode : nil
            txn.responseHeaders = response.headers
            txn.responseBody = response.body.isEmpty ? nil : response.body
            txn.responseBytes = response.body.count
            txn.responseContentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value
            txn.responseReceivedAt = response.responseStart
            txn.finishedAt = response.responseEnd ?? Date()
            txn.error = response.error
            txn.overriddenByRuleID = result.appliedRuleID
            emit(txn)            // completed
        }
    }

    /// A plain-HTTP request of a `.relayRaw` client: fetched from the origin and written back,
    /// with no rules and no transaction. Each request is fetched on its own, because one client
    /// connection can carry requests for different hosts.
    private func forwardRaw(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        guard URL(string: head.uri)?.host != nil else {
            writeError(context: context, message: "Invalid URL: \(head.uri)")
            return
        }
        let request = InterceptedRequest(
            method: head.method.rawValue, url: head.uri,
            headers: head.headers.map { HeaderPair(name: $0.name, value: $0.value) },
            body: body.isEmpty ? nil : body, transport: .mitmProxy
        )
        let channel = context.channel
        Task {
            let response = await ProxyHandler.rawOrigin.perform(request)
            channel.eventLoop.execute {
                HTTPWireFormat.writeResponse(channel: channel, response: response)
            }
        }
    }

    /// The origin for `.relayRaw` requests. It never follows redirects, so the client sees each
    /// hop as it would without a proxy.
    private static let rawOrigin = OriginClient(upstream: UpstreamClient(), policy: .doNotFollow)

    private func writeError(context: ChannelHandlerContext, message: String) {
        var headers = HTTPHeaders()
        let body = Data(message.utf8)
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Tunnel

/// The first handler of a `CONNECT` tunnel. TLS (a handshake record, 0x16) to a host that
/// `shouldDecrypt` accepts gets the decrypting handlers. Anything else is relayed to the target as
/// it is, without a transaction: TLS to a passed-through host, or a protocol the proxy doesn't
/// read, such as a `ws://` WebSocket.
private final class TunnelSniffer: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum State { case waiting, decrypting, connecting([ByteBuffer]) }

    private let host: String
    private let port: Int
    private let shouldDecrypt: @Sendable (String) -> Bool
    private let tls: () throws -> [ChannelHandler]
    private var state = State.waiting

    init(host: String, port: Int, shouldDecrypt: @escaping @Sendable (String) -> Bool,
         tls: @escaping () throws -> [ChannelHandler]) {
        self.host = host
        self.port = port
        self.shouldDecrypt = shouldDecrypt
        self.tls = tls
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .decrypting:
            context.fireChannelRead(data)
        case .connecting(var pending):
            pending.append(unwrapInboundIn(data))
            state = .connecting(pending)
        case .waiting:
            let buffer = unwrapInboundIn(data)
            guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return }
            if first == 0x16, shouldDecrypt(host) {
                decrypt(context: context, data: data)
            } else {
                relay(context: context, first: buffer)
            }
        }
    }

    private func decrypt(context: ChannelHandlerContext, data: NIOAny) {
        do {
            var after: ChannelHandler = self
            for handler in try tls() {
                try context.pipeline.syncOperations.addHandler(handler, position: .after(after))
                after = handler
            }
        } catch {
            context.close(promise: nil)
            return
        }
        state = .decrypting
        context.fireChannelRead(data)
        context.pipeline.removeHandler(context: context, promise: nil)
    }

    private func relay(context: ChannelHandlerContext, first: ByteBuffer) {
        state = .connecting([first])
        let inbound = context.channel
        _ = inbound.setOption(ChannelOptions.autoRead, value: false)
        ClientBootstrap(group: context.eventLoop).connect(host: host, port: port).whenComplete { [self] result in
            guard case .success(let outbound) = result, case .connecting(let pending) = state else {
                inbound.close(promise: nil)
                return
            }
            let (here, there) = GlueHandler.matchedPair()
            do {
                try inbound.pipeline.syncOperations.addHandler(here, position: .after(self))
                try outbound.pipeline.syncOperations.addHandler(there)
            } catch {
                inbound.close(promise: nil)
                outbound.close(promise: nil)
                return
            }
            for buffer in pending { outbound.write(buffer, promise: nil) }
            outbound.flush()
            inbound.pipeline.removeHandler(self, promise: nil)
            _ = inbound.setOption(ChannelOptions.autoRead, value: true)
            inbound.read()
        }
    }
}

/// One end of a relay: what one channel reads, the other writes. Both channels are on one
/// event loop, so each can use the other's context.
private final class GlueHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Handshake observer (CA auto-validation)

/// Sits just after the MITM TLS handler. A completed handshake means the client trusted our
/// per-host leaf (CA is installed → decryption works); an error before completion means it
/// rejected the cert (CA not trusted). Reports the first outcome, then removes itself.
private final class HandshakeObserver: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let host: String
    private let report: (@Sendable (String, Bool) -> Void)?
    private var done = false

    init(host: String, report: (@Sendable (String, Bool) -> Void)?) {
        self.host = host
        self.report = report
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !done, let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            done = true
            report?(host, true)
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; report?(host, false) } // handshake failed → CA not trusted
        context.fireErrorCaught(error)
    }
}
