import Foundation

/// One response-override rule, as persisted to `~/.jaca/network-overrides/rules.json`.
///
/// **Every persisted type here has a hand-written tolerant `init(from:)` in an extension** —
/// including the nested ones, which decode as part of the parent. Synthesized `Codable` ignores
/// defaults for missing keys, so adding a field would make old files throw `keyNotFound` and the
/// next save would overwrite the user's rules with nothing (as happened once with `CloudProject`).
struct OverrideRule: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String = ""
    /// New rules are **enabled** — a hard product requirement, and the default a missing key
    /// decodes to.
    var enabled: Bool = true
    var matcher: OverrideMatcher = .init()
    var scope: OverrideScope = .init()
    var action: OverrideActionSpec = .respond(.init())
    var delayMillis: Int = 0
    /// **The blast radius** — only these hosts leave the device's own network. Derived from the
    /// pattern when it names a literal host, otherwise the editor asks. Ignored by the MITM and
    /// companion transports, which are already on the wire.
    var divertHosts: Set<String> = []
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String = "", enabled: Bool = true,
         matcher: OverrideMatcher = .init(), scope: OverrideScope = .init(),
         action: OverrideActionSpec = .respond(.init()), delayMillis: Int = 0,
         divertHosts: Set<String> = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matcher = matcher
        self.scope = scope
        self.action = action
        self.delayMillis = delayMillis
        self.divertHosts = divertHosts
        self.createdAt = createdAt
    }

    /// What the UI shows when the user hasn't named the rule.
    var displayName: String {
        if !name.isEmpty { return name }
        return matcher.pattern.isEmpty ? "Untitled override" : matcher.pattern
    }
}

/// How a request is selected: one text field plus a method filter, rather than separate
/// host/path/query fields the user has to keep consistent.
struct OverrideMatcher: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case glob, regex }
    var pattern: String = ""
    var kind: Kind = .glob
    /// Empty means any method.
    var methods: Set<String> = []

    init(pattern: String = "", kind: Kind = .glob, methods: Set<String> = []) {
        self.pattern = pattern
        self.kind = kind
        self.methods = methods
    }
}

/// Which devices/apps a rule applies to. Empty sets mean "any", so the default is global.
struct OverrideScope: Codable, Sendable, Hashable {
    var deviceIDs: Set<String> = []
    var appIDs: Set<String> = []

    init(deviceIDs: Set<String> = [], appIDs: Set<String> = []) {
        self.deviceIDs = deviceIDs
        self.appIDs = appIDs
    }

    /// True when this rule targets the given device/app (or targets everything).
    func matches(deviceID: String?, appID: String?) -> Bool {
        if !deviceIDs.isEmpty, let deviceID, !deviceIDs.contains(deviceID) { return false }
        if !deviceIDs.isEmpty, deviceID == nil { return false }
        if !appIDs.isEmpty, let appID, !appIDs.contains(appID) { return false }
        if !appIDs.isEmpty, appID == nil { return false }
        return true
    }
}

/// What the rule does when it matches.
enum OverrideActionSpec: Codable, Sendable, Hashable {
    /// "Don't send" — Jaca answers; the request never leaves the device.
    case respond(OverrideResponseSpec)
    /// "Send and override" — fetch the real response, then rewrite it.
    case editResponse(ResponseEdit)
    /// Repoint at another origin. Modelled so the clamp table is complete; not exposed yet.
    case mapRemote(url: String)

    var requiredCapabilities: InterceptCapabilities {
        switch self {
        case .respond:      return [.shortCircuit]
        case .editResponse: return [.editResponse, .bodies]
        case .mapRemote:    return [.mapRemote]
        }
    }
}

/// A fabricated response.
struct OverrideResponseSpec: Codable, Sendable, Hashable {
    var statusCode: Int = 200
    var headers: [HeaderPair] = [HeaderPair(name: "Content-Type", value: "application/json")]
    var body: OverrideBodyRef = .none

    init(statusCode: Int = 200,
         headers: [HeaderPair] = [HeaderPair(name: "Content-Type", value: "application/json")],
         body: OverrideBodyRef = .none) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// A rewrite applied to the origin's real response.
struct ResponseEdit: Codable, Sendable, Hashable {
    enum HeaderMode: String, Codable, Sendable { case merge, replace }
    /// Nil keeps the origin's status.
    var statusCode: Int?
    var headerMode: HeaderMode = .merge
    var headers: [HeaderPair] = []
    var removeHeaders: [String] = []
    /// Nil keeps the origin's body.
    var body: OverrideBodyRef?

    init(statusCode: Int? = nil, headerMode: HeaderMode = .merge, headers: [HeaderPair] = [],
         removeHeaders: [String] = [], body: OverrideBodyRef? = nil) {
        self.statusCode = statusCode
        self.headerMode = headerMode
        self.headers = headers
        self.removeHeaders = removeHeaders
        self.body = body
    }
}

/// Where a rule's payload lives: inline while `rules.json` stays hand-editable, otherwise a
/// sibling blob, since overrides can be megabytes.
enum OverrideBodyRef: Codable, Sendable, Hashable {
    case none
    /// UTF-8 text, kept under `inlineLimit` so the rules file stays readable.
    case inline(String)
    /// `bodies/<uuid>.bin` — a Jaca-owned copy, snapshotted when the rule was created.
    case blob(filename: String)
    /// A user-owned file on disk (Map Local proper), optionally watched for live reload.
    case file(path: String, watch: Bool)

    /// Above this, a new body is written as a blob instead of inlined.
    static let inlineLimit = 4096
}

// MARK: - Tolerant decoding
//
// Only `id` is required. Every other key falls back to its default, so an older rules.json
// keeps loading after a field is added, and unknown future keys are ignored automatically.

extension OverrideRule {
    enum CodingKeys: String, CodingKey {
        case id, name, enabled, matcher, scope, action, delayMillis, divertHosts, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        name        = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled     = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matcher     = try c.decodeIfPresent(OverrideMatcher.self, forKey: .matcher) ?? .init()
        scope       = try c.decodeIfPresent(OverrideScope.self, forKey: .scope) ?? .init()
        action      = try c.decodeIfPresent(OverrideActionSpec.self, forKey: .action) ?? .respond(.init())
        delayMillis = try c.decodeIfPresent(Int.self, forKey: .delayMillis) ?? 0
        divertHosts = try c.decodeIfPresent(Set<String>.self, forKey: .divertHosts) ?? []
        // ISO-8601 *or* numeric, so either strategy loads: `createdAt` is cosmetic and must
        // never be the reason a rule is dropped.
        createdAt   = OverrideRule.decodeDate(from: c) ?? Date()
    }
}

extension OverrideMatcher {
    enum CodingKeys: String, CodingKey { case pattern, kind, methods }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        kind    = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .glob
        methods = try c.decodeIfPresent(Set<String>.self, forKey: .methods) ?? []
    }
}

extension OverrideScope {
    enum CodingKeys: String, CodingKey { case deviceIDs, appIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deviceIDs) ?? []
        appIDs    = try c.decodeIfPresent(Set<String>.self, forKey: .appIDs) ?? []
    }
}

extension OverrideResponseSpec {
    enum CodingKeys: String, CodingKey { case statusCode, headers, body }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode) ?? 200
        headers    = try c.decodeIfPresent([HeaderPair].self, forKey: .headers)
            ?? [HeaderPair(name: "Content-Type", value: "application/json")]
        body       = try c.decodeIfPresent(OverrideBodyRef.self, forKey: .body) ?? .none
    }
}

extension ResponseEdit {
    enum CodingKeys: String, CodingKey { case statusCode, headerMode, headers, removeHeaders, body }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode    = try c.decodeIfPresent(Int.self, forKey: .statusCode)
        headerMode    = try c.decodeIfPresent(HeaderMode.self, forKey: .headerMode) ?? .merge
        headers       = try c.decodeIfPresent([HeaderPair].self, forKey: .headers) ?? []
        removeHeaders = try c.decodeIfPresent([String].self, forKey: .removeHeaders) ?? []
        body          = try c.decodeIfPresent(OverrideBodyRef.self, forKey: .body)
    }
}

// Enums with associated values need hand-written coders keyed on a "kind" string. An unknown
// kind decodes to a default rather than throwing, so a newer Jaca's rule degrades, not wipes.

extension OverrideActionSpec {
    private enum K: String, CodingKey { case kind, respond, editResponse, mapRemote }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "respond" {
        case "editResponse":
            self = .editResponse(try c.decodeIfPresent(ResponseEdit.self, forKey: .editResponse) ?? .init())
        case "mapRemote":
            self = .mapRemote(url: try c.decodeIfPresent(String.self, forKey: .mapRemote) ?? "")
        default:
            self = .respond(try c.decodeIfPresent(OverrideResponseSpec.self, forKey: .respond) ?? .init())
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .respond(let spec):
            try c.encode("respond", forKey: .kind)
            try c.encode(spec, forKey: .respond)
        case .editResponse(let edit):
            try c.encode("editResponse", forKey: .kind)
            try c.encode(edit, forKey: .editResponse)
        case .mapRemote(let url):
            try c.encode("mapRemote", forKey: .kind)
            try c.encode(url, forKey: .mapRemote)
        }
    }
}

extension OverrideBodyRef {
    private enum K: String, CodingKey { case kind, text, filename, path, watch }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "none" {
        case "inline":
            self = .inline(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "blob":
            let name = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
            self = name.isEmpty ? .none : .blob(filename: name)
        case "file":
            let path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            let watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? true
            self = path.isEmpty ? .none : .file(path: path, watch: watch)
        default:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .kind)
        case .inline(let text):
            try c.encode("inline", forKey: .kind)
            try c.encode(text, forKey: .text)
        case .blob(let filename):
            try c.encode("blob", forKey: .kind)
            try c.encode(filename, forKey: .filename)
        case .file(let path, let watch):
            try c.encode("file", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(watch, forKey: .watch)
        }
    }
}

extension OverrideRule {
    /// Decodes `createdAt` under any strategy, falling back rather than throwing.
    fileprivate static func decodeDate(from c: KeyedDecodingContainer<CodingKeys>) -> Date? {
        if let date = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) { return date }
        if let text = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) {
            return ISO8601DateFormatter().date(from: text)
        }
        if let seconds = ((try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? nil) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return nil
    }
}

/// `HeaderPair` is persisted inside `OverrideRule`, so it needs the same tolerant decode: a
/// `keyNotFound` here makes `decodeArray` skip the *entire enclosing rule*.
extension HeaderPair: Codable {
    enum CodingKeys: String, CodingKey { case name, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  value: try c.decodeIfPresent(String.self, forKey: .value) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
    }
}
