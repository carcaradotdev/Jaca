import Foundation

/// Applies a `ResponseEdit` to a real response. Pure, so merge/replace semantics are testable.
enum ResponseEditing {

    /// Always recomputed when writing the response back, so an edit's copy would contradict the
    /// body actually sent.
    static let managedHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding"]

    static func apply(_ edit: ResponseEdit, to response: InterceptedResponse) -> InterceptedResponse {
        var out = response

        if let status = edit.statusCode { out.statusCode = status }

        let removals = Set(edit.removeHeaders.map { $0.lowercased() })
        let incoming = edit.headers.filter { !managedHeaders.contains($0.name.lowercased()) }

        switch edit.headerMode {
        case .replace:
            out.headers = incoming
        case .merge:
            var merged = out.headers.filter { pair in
                let lower = pair.name.lowercased()
                if removals.contains(lower) { return false }
                // An incoming header of the same name replaces the origin's.
                return !incoming.contains { $0.name.lowercased() == lower }
            }
            merged.append(contentsOf: incoming)
            out.headers = merged
        }

        if let body = edit.body, let data = OverrideBodyLoader.data(for: body) {
            out.body = data
        }
        return out
    }
}

/// Resolves an `OverrideBodyRef` to bytes. A rule owns its payload — `NetworkBodyCache` wipes
/// itself on launch — and a missing blob degrades to nil rather than throwing.
enum OverrideBodyLoader {
    /// Where rule-owned payload blobs live, alongside `rules.json`.
    static var blobsDirectory: URL {
        OverrideRuleStore.directory.appendingPathComponent("bodies", isDirectory: true)
    }

    static func data(for ref: OverrideBodyRef) -> Data? {
        switch ref {
        case .none:
            return Data()
        case .inline(let text):
            return Data(text.utf8)
        case .blob(let filename):
            return try? Data(contentsOf: blobsDirectory.appendingPathComponent(filename))
        case .file(let path, _):
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    /// Why this body can't be served, or nil. Drives the caution dot on a rule row.
    static func unavailableReason(for ref: OverrideBodyRef) -> String? {
        switch ref {
        case .none, .inline:
            return nil
        case .blob(let filename):
            let url = blobsDirectory.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path)
                ? nil : "This override's saved body is missing."
        case .file(let path, _):
            return FileManager.default.fileExists(atPath: path)
                ? nil : "Override file is missing: \(path)"
        }
    }
}
