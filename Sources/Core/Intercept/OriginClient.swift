import Foundation

/// Fetches the real response for an intercepted request.
///
/// Wraps `UpstreamClient` and adds a **per-transport redirect policy**, which is the one place
/// the two transports genuinely differ:
///
/// - **MITM proxy** — do *not* follow. The client re-requests each hop through us, so following
///   here would hide hops from capture. This is `UpstreamClient`'s existing behaviour.
/// - **Divert** — *must* follow. The device app is talking to a loopback tunnel; handing it a bare
///   3xx pointing at the real origin would make it leave the tunnel and defeat the override.
///
/// The follow loop lives here, not in `UpstreamClient`, so the proxy is untouched by it.
struct OriginClient: OriginRequesting {
    enum RedirectPolicy: Sendable, Equatable {
        case doNotFollow
        case follow(max: Int)
    }

    private let upstream: UpstreamClient
    private let policy: RedirectPolicy

    init(upstream: UpstreamClient, policy: RedirectPolicy) {
        self.upstream = upstream
        self.policy = policy
    }

    func perform(_ request: InterceptedRequest) async -> InterceptedResponse {
        var current = request
        var hops = 0
        let maxHops: Int = {
            if case .follow(let max) = policy { return max }
            return 0
        }()

        while true {
            guard let urlRequest = Self.makeURLRequest(from: current) else {
                return InterceptedResponse(statusCode: 0, error: "Invalid URL: \(current.url)")
            }
            let response = await upstream.send(urlRequest)
            let intercepted = InterceptedResponse(
                statusCode: response.error == nil ? response.statusCode : 0,
                headers: response.headers.map { HeaderPair(name: $0.0, value: $0.1) },
                body: response.body,
                error: response.error,
                responseStart: response.responseStart,
                responseEnd: response.responseEnd ?? Date()
            )

            guard hops < maxHops,
                  (300...399).contains(intercepted.statusCode),
                  let location = intercepted.headers.first(where: { $0.name.lowercased() == "location" })?.value,
                  let next = Self.resolve(location: location, against: current.url)
            else {
                return intercepted
            }
            hops += 1
            current.url = next
            if Self.downgradesToGET(status: intercepted.statusCode, method: current.method) {
                current.method = "GET"
                current.body = nil
            }
        }
    }

    /// Whether following `status` rewrites the request into a bodiless GET. Pure, so the table
    /// can be asserted without a live redirect.
    ///
    /// 303 always downgrades and 301/302 downgrade a non-GET/HEAD (as `URLSession` does), but
    /// **307/308 never do** — they exist to preserve the method and body. Downgrading every 3xx
    /// turned a diverted `POST` into a bodiless GET and a silent 404/405.
    static func downgradesToGET(status: Int, method: String) -> Bool {
        switch status {
        case 303:      return true
        case 301, 302: return method != "GET" && method != "HEAD"
        default:       return false
        }
    }

    /// Builds the outbound `URLRequest`, dropping every header that must not cross to a real
    /// origin (hop-by-hop, the tunnel's `Host`, and all `X-Jaca-*` markers).
    static func makeURLRequest(from request: InterceptedRequest) -> URLRequest? {
        guard let url = URL(string: request.url) else { return nil }
        var out = URLRequest(url: url)
        out.httpMethod = request.method
        for header in request.headers where !HTTPWireFormat.shouldDropFromOutbound(header.name) {
            out.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if let body = request.body, !body.isEmpty { out.httpBody = body }
        return out
    }

    /// Resolves a `Location` header, which may be absolute or relative.
    static func resolve(location: String, against base: String) -> String? {
        if location.hasPrefix("http://") || location.hasPrefix("https://") { return location }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: location, relativeTo: baseURL) else { return nil }
        return resolved.absoluteString
    }
}
