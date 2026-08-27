import Foundation

/// Turning a captured transaction into a pre-filled rule. Pure rather than on the `@MainActor`
/// model, so "does a seeded rule actually match the request it came from?" is directly testable.
enum OverrideSeeding {

    /// `scheme://host + path`, **query dropped**: the matcher ignores the query unless the
    /// pattern names one, so carrying it over would imply a constraint that isn't applied — and
    /// dropping it makes the rule match the same endpoint with different query values.
    static func pattern(for txn: NetworkTransaction) -> String {
        guard let comps = URLComponents(string: txn.url), let host = comps.host else { return txn.url }
        let scheme = comps.scheme ?? "https"
        let path = comps.path.isEmpty ? "/" : comps.path
        return "\(scheme)://\(host)\(path)"
    }

    static func name(for txn: NetworkTransaction) -> String {
        let last = URLComponents(string: txn.url)?.path
            .split(separator: "/").last.map(String.init) ?? txn.host
        return "\(txn.method) \(last)"
    }

    /// Response headers worth copying: everything except the framing headers Jaca recomputes and
    /// its own internal markers.
    static func headers(_ headers: [HeaderPair]) -> [HeaderPair] {
        let managed: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection"]
        let kept = headers.filter {
            !managed.contains($0.name.lowercased()) && !OverrideHeaders.isJacaInternal($0.name)
        }
        return kept.isEmpty ? [HeaderPair(name: "Content-Type", value: "application/json")] : kept
    }

    static func prettyPrinted(_ data: Data, contentType: String?) -> Data {
        guard (contentType ?? "").lowercased().contains("json"),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys])
        else { return data }
        return pretty
    }

    /// Why a seeded rule may not reproduce the captured response faithfully — surfaced in the
    /// editor rather than discovered later.
    static func warning(for txn: NetworkTransaction) -> String? {
        let contentType = (txn.responseContentType ?? "").lowercased()
        if contentType.contains("text/event-stream") || contentType.contains("application/grpc") {
            return "This is a streamed response. Jaca can't capture streamed bodies, and an "
                 + "override replies with one complete body — the app's stream will end after your payload."
        }
        if let body = txn.responseBody, body.count >= 1024 * 1024 {
            return "The captured body hit the 1 MB cap and is truncated. Sending it as-is would "
                 + "return a truncated payload."
        }
        if !contentType.isEmpty, !isTextual(contentType) {
            return "Binary responses are captured as text and can't be reproduced byte-for-byte."
        }
        return nil
    }

    private static func isTextual(_ contentType: String) -> Bool {
        contentType.contains("json") || contentType.contains("text")
            || contentType.contains("xml") || contentType.contains("javascript")
            || contentType.contains("x-www-form-urlencoded")
    }
}
