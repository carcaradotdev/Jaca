import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

/// A man-in-the-middle HTTP(S) proxy. Clients point their device proxy at it;
/// for `CONNECT` it terminates TLS with a per-host leaf cert (signed by our CA),
/// reads the plaintext HTTP, and forwards upstream via `UpstreamClient`,
/// emitting a `NetworkTransaction` per request/response.
final class ProxyServer: @unchecked Sendable {
    let port: Int
    private let ca: CertificateAuthority
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    /// (host, success) per MITM TLS handshake — success means the client trusted our leaf
    /// (CA installed → decryption works); failure means it rejected it (CA not trusted).
    private let onHandshake: (@Sendable (String, Bool) -> Void)?
    private let upstream = UpstreamClient()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?

    /// The actually-bound port (useful when constructed with port 0).
    var boundPort: Int { channel?.localAddress?.port ?? port }

    init(port: Int, ca: CertificateAuthority,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onHandshake: (@Sendable (String, Bool) -> Void)? = nil) {
        self.port = port
        self.ca = ca
        self.onTransaction = onTransaction
        self.onHandshake = onHandshake
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [ca, upstream, onTransaction, onHandshake] channel in
                channel.pipeline.addHandler(HTTPResponseEncoder(), name: "encoder").flatMap {
                    channel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "decoder"
                    )
                }.flatMap {
                    channel.pipeline.addHandler(
                        ProxyHandler(ca: ca, upstream: upstream, onTransaction: onTransaction,
                                     onHandshake: onHandshake, mode: .initial),
                        name: "proxy"
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Bind on all interfaces, not just loopback: a physical device reaches the
        // proxy over the LAN at this Mac's IP, so 127.0.0.1 would be unreachable and
        // (because the device proxy is set) break all of its web traffic. Emulators
        // still work — 10.0.2.2 maps to the host loopback, which 0.0.0.0 includes.
        channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
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
}

// MARK: - Handler

private final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    enum Mode {
        case initial            // first request on a connection (CONNECT or absolute-URI)
        case tls(host: String)  // after CONNECT + TLS upgrade; origin-form requests
    }

    private let ca: CertificateAuthority
    private let upstream: UpstreamClient
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onHandshake: (@Sendable (String, Bool) -> Void)?
    private let mode: Mode

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = Data()

    init(ca: CertificateAuthority, upstream: UpstreamClient,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onHandshake: (@Sendable (String, Bool) -> Void)?, mode: Mode) {
        self.ca = ca
        self.upstream = upstream
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
            } else {
                forward(context: context, head: head, body: bodyBuffer)
            }
        }
    }

    // MARK: CONNECT → TLS upgrade

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let host = String(head.uri.split(separator: ":").first ?? "")
        // Stop delivering inbound bytes until the TLS handler is installed, so the
        // client's ClientHello (sent right after our 200) isn't read by the stale
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
            self?.upgradeToTLS(channel: channel, host: host)
        }
    }

    private func upgradeToTLS(channel: Channel, host: String) {
        let pipeline = channel.pipeline
        let sslContext: NIOSSLContext
        do { sslContext = try ca.serverContext(forHost: host) }
        catch { channel.close(promise: nil); return }

        let sslHandler = NIOSSLServerHandler(context: sslContext)
        let observer = HandshakeObserver(host: host, report: onHandshake)
        let newProxy = ProxyHandler(ca: ca, upstream: upstream, onTransaction: onTransaction,
                                    onHandshake: onHandshake, mode: .tls(host: host))

        pipeline.removeHandler(name: "decoder")
            .flatMap { pipeline.removeHandler(name: "encoder") }
            .flatMap { pipeline.removeHandler(name: "proxy") }
            .flatMap { pipeline.addHandler(sslHandler, name: "ssl", position: .first) }
            .flatMap { pipeline.addHandler(observer, name: "handshake", position: .after(sslHandler)) }
            .flatMap { pipeline.addHandler(HTTPResponseEncoder(), name: "encoder") }
            .flatMap {
                pipeline.addHandler(
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    name: "decoder"
                )
            }
            .flatMap { pipeline.addHandler(newProxy, name: "proxy") }
            .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
            .whenComplete { result in
                switch result {
                case .success: channel.read()
                case .failure: channel.close(promise: nil)
                }
            }
    }

    // MARK: Forwarding

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let urlString: String
        let host: String
        let scheme: String
        switch mode {
        case .tls(let connectHost):
            host = connectHost
            scheme = "https"
            urlString = "https://\(connectHost)\(head.uri)"
        case .initial:
            scheme = "http"
            urlString = head.uri            // absolute-form for plain proxying
            host = URL(string: head.uri)?.host ?? head.headers.first(name: "Host") ?? ""
        }

        guard let url = URL(string: urlString) else {
            writeError(context: context, message: "Invalid URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = head.method.rawValue
        var requestHeaders: [HeaderPair] = []
        for header in head.headers {
            requestHeaders.append(HeaderPair(name: header.name, value: header.value))
            if !Self.isHopByHop(header.name) {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
        }
        if !body.isEmpty { request.httpBody = body }

        var txn = NetworkTransaction(
            method: head.method.rawValue, url: urlString, host: host, scheme: scheme,
            requestHeaders: requestHeaders, requestBody: body.isEmpty ? nil : body
        )
        onTransaction(txn)   // in-flight

        let channel = context.channel
        let emit = onTransaction
        Task { [upstream] in
            let response = await upstream.send(request)
            channel.eventLoop.execute {
                Self.writeResponse(channel: channel, response: response)
            }
            txn.statusCode = response.error == nil ? response.statusCode : nil
            txn.responseHeaders = response.headers.map { HeaderPair(name: $0.0, value: $0.1) }
            txn.responseBody = response.body.isEmpty ? nil : response.body
            txn.responseBytes = response.body.count
            txn.responseContentType = response.headers.first { $0.0.lowercased() == "content-type" }?.1
            txn.responseReceivedAt = response.responseStart
            txn.finishedAt = response.responseEnd ?? Date()
            txn.error = response.error
            emit(txn)            // completed
        }
    }

    private static func writeResponse(channel: Channel, response: UpstreamClient.Response) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            let lower = name.lowercased()
            if isHopByHop(name) || lower == "content-length" || lower == "content-encoding" { continue }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        headers.replaceOrAdd(name: "Connection", value: "keep-alive")

        let status = HTTPResponseStatus(statusCode: response.statusCode == 0 ? 502 : response.statusCode)
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        var buffer = channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }

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

    private static func isHopByHop(_ name: String) -> Bool {
        let hop: Set<String> = [
            "connection", "proxy-connection", "keep-alive", "transfer-encoding",
            "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate",
        ]
        return hop.contains(name.lowercased())
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
