import Foundation

/// Recovers the URL the app *originally* asked for. Every transport rewrites the request on its
/// way here — the agent repoints it at loopback, the proxy strips the origin into a CONNECT — so
/// matching runs against this, never the wire URL, or rules would match `localhost:41234`.
enum AgentOriginalURL {

    /// Prefers `X-Jaca-Original-URL` (set by the agent, which knows the real URL), falling back
    /// to `Host` + origin-form URI — what a non-agent client hitting loopback sends.
    static func recover(headers: [HeaderPair], uri: String) -> String? {
        if let original = headers.first(where: { $0.name.lowercased() == OverrideHeaders.originalURL.lowercased() })?.value,
           !original.isEmpty, URL(string: original)?.host != nil {
            return original
        }
        // Absolute-form URI (a plain proxy request).
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
        // Origin-form: rebuild from Host.
        guard let host = headers.first(where: { $0.name.lowercased() == "host" })?.value,
              !host.isEmpty else { return nil }
        let path = uri.hasPrefix("/") ? uri : "/" + uri
        return "http://\(host)\(path)"
    }
}

/// Recovers the original URL for a request arriving at the MITM proxy, mirroring how
/// `ProxyServer` already builds it: a tunnelled request carries an origin-form URI and gets its
/// host from the preceding CONNECT, while a plain proxy request carries an absolute-form URI.
enum ProxyOriginalURL {
    enum Mode: Sendable, Equatable {
        case tls(host: String)
        case initial
    }

    static func recover(mode: Mode, uri: String, hostHeader: String?) -> String? {
        switch mode {
        case .tls(let host):
            let path = uri.hasPrefix("/") ? uri : "/" + uri
            return "https://\(host)\(path)"
        case .initial:
            if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
            guard let host = hostHeader, !host.isEmpty else { return nil }
            let path = uri.hasPrefix("/") ? uri : "/" + uri
            return "http://\(host)\(path)"
        }
    }
}
