import Foundation

/// Persists the override rule library to `~/.jaca/network-overrides/`.
///
/// Layout:
/// ```
/// ~/.jaca/network-overrides/
///   rules.json        — the ordered rule list, hand-editable
///   bodies/<uuid>.bin — payloads too large to inline
/// ```
///
/// Payloads sit in sibling files because a body can be megabytes and `rules.json` has to stay
/// readable. Loading goes through `CloudPersistence.decodeArray`, so one corrupt record is skipped
/// rather than wiping the library.
struct OverrideRuleStore: Sendable {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jaca/network-overrides", isDirectory: true)
    }

    static var rulesURL: URL { directory.appendingPathComponent("rules.json") }
    static var bodiesDirectory: URL { directory.appendingPathComponent("bodies", isDirectory: true) }

    /// Loads the rule library, or `[]` when nothing is saved. Synchronous by design: the model
    /// calls it from `init`, so the first frame already has the user's rules.
    static func load() -> [OverrideRule] {
        guard let data = try? Data(contentsOf: rulesURL) else { return [] }
        return CloudPersistence.decodeArray(OverrideRule.self, from: data, decoder: makeDecoder())
    }

    /// Must mirror `save`'s encoder exactly. It writes ISO-8601 dates to stay hand-editable, and
    /// decoding those numerically throws on **every** record — the library then loads empty and
    /// the next save wipes the file and every body blob with it.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes the library atomically and garbage-collects orphaned body blobs.
    @discardableResult
    static func save(_ rules: [OverrideRule]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(rules)
            try data.write(to: rulesURL, options: .atomic)
            collectGarbage(keeping: rules)
            return true
        } catch {
            return false
        }
    }

    /// Stores a payload, inlining small bodies and spilling large ones to `bodies/`.
    static func makeBodyRef(_ data: Data, preferInline: Bool = true) -> OverrideBodyRef {
        if data.isEmpty { return .none }
        if preferInline, data.count <= OverrideBodyRef.inlineLimit,
           let text = String(data: data, encoding: .utf8) {
            return .inline(text)
        }
        let filename = "\(UUID().uuidString).bin"
        do {
            try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
            try data.write(to: bodiesDirectory.appendingPathComponent(filename), options: .atomic)
            return .blob(filename: filename)
        } catch {
            // Couldn't spill — inline what we can rather than losing the body entirely.
            return String(data: data, encoding: .utf8).map { .inline($0) } ?? .none
        }
    }

    /// Deletes blobs no live rule refers to. Called after every save, so deleting a rule
    /// reclaims its payload without a separate cleanup pass.
    static func collectGarbage(keeping rules: [OverrideRule]) {
        let fm = FileManager.default
        guard let existing = try? fm.contentsOfDirectory(atPath: bodiesDirectory.path) else { return }
        var live: Set<String> = []
        for rule in rules {
            for ref in bodyRefs(of: rule) {
                if case .blob(let filename) = ref { live.insert(filename) }
            }
        }
        for file in existing where !live.contains(file) {
            try? fm.removeItem(at: bodiesDirectory.appendingPathComponent(file))
        }
    }

    private static func bodyRefs(of rule: OverrideRule) -> [OverrideBodyRef] {
        switch rule.action {
        case .respond(let spec):     return [spec.body]
        case .editResponse(let edit): return edit.body.map { [$0] } ?? []
        case .mapRemote:             return []
        }
    }
}
