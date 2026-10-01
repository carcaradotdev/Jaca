import Foundation

/// Renders a captured transaction as a runnable `curl` command, so a request can be
/// replayed from a terminal (or pasted into a bug report) exactly as the app sent it.
///
/// Pure string work — no AppKit — so it is unit-testable on its own.
enum CurlExport {
    /// Headers curl derives itself; sending the captured value would fight the real body.
    private static let droppedHeaders: Set<String> = ["content-length"]

    static func command(for txn: NetworkTransaction) -> String {
        var parts = ["curl " + shellQuote(txn.url)]

        let method = txn.method.uppercased()
        let body = txn.requestBody.flatMap { $0.isEmpty ? nil : $0 }
        // curl defaults to GET, and to POST once a body is attached — only spell the
        // method out when it isn't what curl would have picked anyway.
        if method != "GET" || body != nil {
            parts.append("-X " + methodToken(method))
        }

        var compressed = false
        for header in txn.requestHeaders {
            let name = header.name.lowercased()
            // HTTP/2 pseudo-headers (":method", ":authority", …) aren't real headers.
            if name.hasPrefix(":") || droppedHeaders.contains(name) { continue }
            // Keeping the header without --compressed makes curl print the raw gzip bytes,
            // so trade the header for the flag that actually decodes the response.
            if name == "accept-encoding", isCompressionOffer(header.value) {
                compressed = true
                continue
            }
            parts.append("-H " + shellQuote("\(header.name): \(header.value)"))
        }

        if let body { parts.append(dataArgument(body)) }
        if compressed { parts.append("--compressed") }

        return parts.joined(separator: " \\\n  ")
    }

    private static func methodToken(_ method: String) -> String {
        method.allSatisfy { $0.isLetter } ? method : shellQuote(method)
    }

    private static func isCompressionOffer(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["gzip", "deflate", "br", "zstd"].contains { lowered.contains($0) }
    }

    private static func dataArgument(_ body: Data) -> String {
        if let text = String(data: body, encoding: .utf8) {
            return "--data-raw " + shellQuote(text)
        }
        // Binary payload (protobuf, multipart with a file, …): ANSI-C quoting keeps every
        // byte intact in bash/zsh where a plain single-quoted string would not.
        return "--data-binary " + ansiCQuote(body)
    }

    /// Wraps a value in single quotes, which are literal in POSIX shells except for the
    /// quote itself — closed, escaped, and reopened.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func ansiCQuote(_ data: Data) -> String {
        "$'" + data.map { String(format: "\\x%02x", $0) }.joined() + "'"
    }
}
