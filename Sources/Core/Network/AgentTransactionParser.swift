import Foundation

/// Parses one agent JSON line into a NetworkTransaction. Pure & testable.
enum AgentTransactionParser {
    static func parse(_ line: String) -> NetworkTransaction? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "txn" else { return nil }

        let url = obj["url"] as? String ?? ""
        let comps = URLComponents(string: url)
        var txn = NetworkTransaction(
            method: obj["method"] as? String ?? "GET",
            url: url,
            host: comps?.host ?? "",
            scheme: comps?.scheme ?? (url.hasPrefix("https") ? "https" : "http"),
            requestHeaders: headers(obj["requestHeaders"]),
            requestBody: bodyData(obj["requestBody"]),
            startedAt: date(obj["startedAt"]) ?? Date()
        )
        if let status = obj["status"] as? Int, status > 0 { txn.statusCode = status }
        txn.responseHeaders = headers(obj["responseHeaders"])
        txn.responseBody = bodyData(obj["responseBody"])
        txn.responseContentType = txn.responseHeaders.first { $0.name.lowercased() == "content-type" }?.value
        txn.responseReceivedAt = date(obj["responseAt"])
        txn.finishedAt = date(obj["finishedAt"])
        txn.requestBytes = obj["requestSize"] as? Int ?? (txn.requestBody?.count ?? 0)
        txn.responseBytes = obj["responseSize"] as? Int ?? (txn.responseBody?.count ?? 0)
        txn.error = obj["error"] as? String
        txn.callStack = (obj["callStack"] as? [Any])?.compactMap { $0 as? String }
        txn.httpStack = obj["httpStack"] as? String
        // The agent captures our stamp on the way back, so the row knows it was overridden with
        // no id matching across two id spaces.
        txn.overriddenByRuleID = txn.responseHeaders
            .first { $0.name.lowercased() == OverrideHeaders.override.lowercased() }
            .flatMap { UUID(uuidString: $0.value) }
        return txn
    }

    private static func headers(_ any: Any?) -> [HeaderPair] {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    private static func bodyData(_ any: Any?) -> Data? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s.data(using: .utf8)
    }
    private static func date(_ any: Any?) -> Date? {
        guard let t = any as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}
