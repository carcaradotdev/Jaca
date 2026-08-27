import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// HTTP header hygiene and response writing, shared by the MITM proxy and the override server.
/// One implementation on purpose — header handling that drifts between two servers is how a
/// proxy starts corrupting bodies.
enum HTTPWireFormat {

    /// Headers that describe *this* connection rather than the message, and must never be
    /// forwarded between hops.
    static func isHopByHop(_ name: String) -> Bool {
        let hop: Set<String> = [
            "connection", "proxy-connection", "keep-alive", "transfer-encoding",
            "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate",
        ]
        return hop.contains(name.lowercased())
    }

    /// Dropped before a request goes to a real origin: hop-by-hop, the rewritten `Host`, and
    /// every Jaca-internal marker. `X-Jaca-Original-URL` is not hop-by-hop, so without this it
    /// would leak the app's real URL structure upstream.
    static func shouldDropFromOutbound(_ name: String) -> Bool {
        let lower = name.lowercased()
        return isHopByHop(lower) || lower == "host" || lower == "content-length"
            || OverrideHeaders.isJacaInternal(lower)
    }

    /// Writes a complete response, recomputing the framing headers so they always agree with the
    /// body actually being sent.
    static func writeResponse(channel: Channel, response: InterceptedResponse) {
        var headers = HTTPHeaders()
        for pair in response.headers {
            let lower = pair.name.lowercased()
            if isHopByHop(lower) || lower == "content-length" || lower == "content-encoding" { continue }
            headers.add(name: pair.name, value: pair.value)
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
}

/// One process-wide `EventLoopGroup`, so N servers don't spawn 2N threads and teardown never
/// blocks — closing the channel is enough.
///
/// **`ProxyServer` is not on this group**: it terminates TLS for a whole device, and that load
/// does not belong on the two threads every override server shares.
enum NIOGroups {
    static let shared = MultiThreadedEventLoopGroup(numberOfThreads: 2)
}
