import Foundation

/// Serializes captured transactions to HAR 1.2 (importable into Charles, browser
/// devtools, and other HTTP debuggers).
enum HARExport {
    static func data(from transactions: [NetworkTransaction]) -> Data? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entries: [[String: Any]] = transactions.map { txn in
            let totalMs = (txn.duration ?? 0) * 1000
            let waitMs = (txn.ttfb ?? 0) * 1000
            let receiveMs = max(0, totalMs - waitMs)

            var request: [String: Any] = [
                "method": txn.method,
                "url": txn.url,
                "httpVersion": "HTTP/1.1",
                "headers": txn.displayRequestHeaders.map { ["name": $0.name, "value": $0.value] },
                "queryString": queryString(txn.url),
                "cookies": [],
                "headersSize": -1,
                "bodySize": txn.requestBytes,
            ]
            if let body = txn.requestBody, let text = String(data: body, encoding: .utf8) {
                request["postData"] = [
                    "mimeType": txn.requestHeaders.first { $0.name.lowercased() == "content-type" }?.value ?? "",
                    "text": text,
                ]
            }

            var content: [String: Any] = [
                "size": txn.responseBytes,
                "mimeType": txn.responseContentType ?? "",
            ]
            if let body = txn.responseBody, let text = String(data: body, encoding: .utf8) {
                content["text"] = text
            }

            return [
                "startedDateTime": iso.string(from: txn.startedAt),
                "time": totalMs,
                "request": request,
                "response": [
                    "status": txn.statusCode ?? 0,
                    "statusText": txn.error ?? "",
                    "httpVersion": "HTTP/1.1",
                    "headers": txn.displayResponseHeaders.map { ["name": $0.name, "value": $0.value] },
                    "cookies": [],
                    "content": content,
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": txn.responseBytes,
                ],
                "cache": [:],
                "timings": ["send": 0, "wait": waitMs, "receive": receiveMs],
            ]
        }

        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": "Jaca", "version": "0.1.0"],
                "entries": entries,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted])
    }

    private static func queryString(_ url: String) -> [[String: String]] {
        URLComponents(string: url)?.queryItems?.map {
            ["name": $0.name, "value": $0.value ?? ""]
        } ?? []
    }
}
