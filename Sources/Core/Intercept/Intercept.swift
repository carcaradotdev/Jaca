import Foundation

/// The transport-neutral interception seam.
///
/// Every way Jaca can see an HTTP exchange — the in-process Android agent's divert, the MITM
/// proxy, the iOS Simulator agent, the companion app — asks the *same* question here:
/// "given this request, what should happen?". The answer is plain data (`InterceptDecision`),
/// and one shared `InterceptPipeline` executes it. Nothing in this file knows what adb, okhttp,
/// TLS or gRPC are, and nothing in it imports SwiftUI.
///
/// This is what makes response overrides reusable: adding HTTPS-decryption support later means
/// calling `pipeline.run(_:capabilities:)` from that transport's forwarding point and declaring
/// what it can honour — not reimplementing matching, precedence, or degradation.

// MARK: - Where interception happens

/// Identifies an *interception point*, which is deliberately not the same thing as a capture
/// source: the companion app both streams flow metadata (which can't be overridden) and, once
/// decrypting, forwards through the MITM proxy (which can).
enum InterceptTransportID: Sendable, Hashable {
    case agentDivert(package: String)
    case iosSimulatorDivert(bundleID: String)
    case mitmProxy
    case companionMetadata

    /// Short label for diagnostics and the authoring-time capability hints.
    var label: String {
        switch self {
        case .agentDivert:         return "in-process agent"
        case .iosSimulatorDivert:  return "iOS Simulator agent"
        case .mitmProxy:           return "HTTPS decryption"
        case .companionMetadata:   return "companion flow metadata"
        }
    }
}

// MARK: - Neutral exchange types

/// One request, as seen at an interception point, with the URL already restored to what the app
/// originally asked for (never the diverted loopback URL).
struct InterceptedRequest: Sendable {
    let id: UUID
    var method: String
    var url: String
    var headers: [HeaderPair]
    var body: Data?
    var transport: InterceptTransportID
    var deviceID: String?
    var appID: String?
    var startedAt: Date

    /// Parsed once at construction and reused for every rule, so matching N rules doesn't reparse
    /// the URL N times. Nil when the "URL" isn't one — companion metadata rows are `"host:port"`.
    var facts: URLFacts?

    init(id: UUID = UUID(), method: String, url: String, headers: [HeaderPair] = [],
         body: Data? = nil, transport: InterceptTransportID, deviceID: String? = nil,
         appID: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
        self.startedAt = startedAt
        self.facts = OverrideMatching.facts(url: url)
    }
}

/// One response, whether it came off the wire or was fabricated by a rule.
struct InterceptedResponse: Sendable, Equatable {
    var statusCode: Int
    var headers: [HeaderPair]
    var body: Data
    var error: String?
    /// Nil when synthesized — this exchange never hit the network, and the UI says so.
    var responseStart: Date?
    var responseEnd: Date?

    init(statusCode: Int, headers: [HeaderPair] = [], body: Data = Data(), error: String? = nil,
         responseStart: Date? = nil, responseEnd: Date? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.error = error
        self.responseStart = responseStart
        self.responseEnd = responseEnd
    }
}

// MARK: - Capabilities

/// What an interception point can actually do. The resolver *clamps* its decision to these, so a
/// rule that can't run somewhere degrades identically everywhere instead of silently doing nothing.
struct InterceptCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// Can answer without contacting the origin at all.
    static let shortCircuit = InterceptCapabilities(rawValue: 1 << 0)
    /// Can fetch the real response and rewrite it.
    static let editResponse = InterceptCapabilities(rawValue: 1 << 1)
    /// Can hold a response back before delivering it.
    static let delay = InterceptCapabilities(rawValue: 1 << 2)
    /// Sees full request/response bodies (not just metadata).
    static let bodies = InterceptCapabilities(rawValue: 1 << 3)
    /// Can repoint a request at a different origin. Modelled now; not exposed in the UI yet.
    static let mapRemote = InterceptCapabilities(rawValue: 1 << 4)
    /// Can pause an exchange for interactive editing (breakpoints). Not built.
    static let suspend = InterceptCapabilities(rawValue: 1 << 5)

    /// Any hop the desktop terminates itself: agent divert, simulator divert, MITM proxy.
    static let desktopTerminated: InterceptCapabilities = [.shortCircuit, .editResponse, .delay, .bodies]
    /// Flow metadata only — a host and a port, with no HTTP semantics to override.
    static let observeOnly: InterceptCapabilities = []
}

// MARK: - Decision

/// What to do with an intercepted request. Deliberately *data*, never a closure, so it is
/// `Equatable` and the clamp can be exhaustively unit-tested without running a transport.
enum InterceptAction: Sendable, Equatable {
    case proceed
    case respond(InterceptedResponse)
    case edit(ResponseEdit)
}

struct InterceptDecision: Sendable, Equatable {
    var action: InterceptAction = .proceed
    var delay: Duration = .zero
    var ruleID: UUID?

    init(action: InterceptAction = .proceed, delay: Duration = .zero, ruleID: UUID? = nil) {
        self.action = action
        self.delay = delay
        self.ruleID = ruleID
    }

    static let proceed = InterceptDecision()
}

/// Why no rule was applied. The UI renders `message` and nothing else, so a blocked rule reads
/// identically in the row gutter, the rules list, and the editor.
enum InterceptSkipReason: Sendable, Equatable {
    case masterOff
    case transportUnsupported(transport: InterceptTransportID, missing: InterceptCapabilities)
    case transportNotArmed(String)
    case noRuleMatched

    var message: String {
        switch self {
        case .masterOff:
            return "Overrides are paused."
        case .transportUnsupported(let transport, let missing):
            if missing.contains(.bodies) {
                return "This rule needs response bodies, which \(transport.label) capture doesn't provide."
            }
            if missing.contains(.mapRemote) {
                return "Redirecting to another origin isn't supported by \(transport.label) capture."
            }
            return "This rule can't run in \(transport.label) capture."
        case .transportNotArmed(let detail):
            return detail
        case .noRuleMatched:
            return "No override matched this request."
        }
    }
}

// MARK: - Protocols

/// **The seam.** Pure and synchronous so it can run on a NIO event loop or the agent's reader
/// thread with no actor hop. Implementations must be thread-safe and must not mutate anything.
protocol InterceptResolving: Sendable {
    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?)
}

/// Who produces real bytes. `OriginClient` wraps `UpstreamClient`; tests inject a stub, which is
/// how the whole pipeline is tested with no sockets.
protocol OriginRequesting: Sendable {
    func perform(_ request: InterceptedRequest) async -> InterceptedResponse
}

/// Reports what actually happened, so the UI can badge the row and count hits.
protocol InterceptReporting: Sendable {
    func report(requestID: UUID, appliedRuleID: UUID?, skipped: InterceptSkipReason?)
}

/// Lets the desktop arm/disarm a device-side transport. This single signature is where any
/// attempt to teach the device about rules would show up in a diff — see `Divert.kt`.
protocol InterceptArming: AnyObject, Sendable {
    func arm(_ endpoint: OverrideEndpoint?)
}

/// The entire vocabulary the device is ever given: where to send traffic, which hosts, and how
/// long that permission lasts without being renewed. No patterns, payloads, or statuses.
struct OverrideEndpoint: Sendable, Equatable {
    var origin: String
    var hosts: Set<String>
    var heartbeatSeconds: Int = 15
}

// MARK: - Pipeline

/// Executes an `InterceptDecision`: resolve → delay → (short-circuit | origin → edit) → report.
/// One implementation, shared by every transport, so behaviour can't drift between them.
struct InterceptPipeline: Sendable {
    struct Result: Sendable {
        var response: InterceptedResponse
        var appliedRuleID: UUID?
        var skipped: InterceptSkipReason?
    }

    var resolver: InterceptResolving?
    var origin: OriginRequesting?
    var reporter: InterceptReporting?

    init(resolver: InterceptResolving? = nil, origin: OriginRequesting? = nil,
         reporter: InterceptReporting? = nil) {
        self.resolver = resolver
        self.origin = origin
        self.reporter = reporter
    }

    /// A pipeline that never overrides anything — the default, so wiring it into an existing
    /// transport is behaviour-preserving until a resolver is supplied.
    static let passthrough = InterceptPipeline()

    /// What to do when no rule applies.
    enum UnmatchedPolicy: Sendable, Equatable {
        /// Fetch the real response and return it — correct for the MITM proxy, which *is* the
        /// only path the request has.
        case fetchFromOrigin
        /// Don't touch the network: report that nothing applied and let the caller hand the
        /// request back to the device. Correct for divert, where the device will send it itself —
        /// fetching here as well would execute every unmatched request **twice**.
        case handBack
    }

    func run(_ request: InterceptedRequest,
             capabilities: InterceptCapabilities,
             unmatched: UnmatchedPolicy = .fetchFromOrigin) async -> Result {
        let (decision, skip) = resolver?.resolve(request, capabilities: capabilities)
            ?? (.proceed, InterceptSkipReason.noRuleMatched)

        if decision.delay > .zero, capabilities.contains(.delay) {
            try? await Task.sleep(for: decision.delay)
        }

        switch decision.action {
        case .respond(var canned):
            // Synthesized: it never hit the network, so responseStart stays nil and the UI can
            // honestly show no time-to-first-byte.
            canned.responseEnd = Date()
            reporter?.report(requestID: request.id, appliedRuleID: decision.ruleID, skipped: nil)
            return Result(response: stamp(canned, ruleID: decision.ruleID),
                          appliedRuleID: decision.ruleID, skipped: nil)

        case .edit(let edit):
            let real = await fetch(request)
            let edited = ResponseEditing.apply(edit, to: real)
            reporter?.report(requestID: request.id, appliedRuleID: decision.ruleID, skipped: nil)
            return Result(response: stamp(edited, ruleID: decision.ruleID),
                          appliedRuleID: decision.ruleID, skipped: nil)

        case .proceed:
            guard unmatched == .fetchFromOrigin else {
                reporter?.report(requestID: request.id, appliedRuleID: nil, skipped: skip)
                return Result(response: InterceptedResponse(statusCode: 0), appliedRuleID: nil,
                              skipped: skip)
            }
            let real = await fetch(request)
            reporter?.report(requestID: request.id, appliedRuleID: nil, skipped: skip)
            return Result(response: real, appliedRuleID: nil, skipped: skip)
        }
    }

    private func fetch(_ request: InterceptedRequest) async -> InterceptedResponse {
        guard let origin else {
            return InterceptedResponse(statusCode: 0, error: "No origin client configured")
        }
        return await origin.perform(request)
    }

    /// Marks a response as ours so capture can badge the row without guessing. Kept out of the
    /// Headers tab and out of HAR exports by the UI layer.
    private func stamp(_ response: InterceptedResponse, ruleID: UUID?) -> InterceptedResponse {
        guard let ruleID else { return response }
        var out = response
        out.headers.append(HeaderPair(name: OverrideHeaders.override, value: ruleID.uuidString))
        return out
    }
}

/// Header names Jaca uses on the wire. All are stripped before a request reaches a real origin,
/// and hidden from the Headers tab.
enum OverrideHeaders {
    /// Set by the device so the desktop can recover the URL the app actually asked for.
    static let originalURL = "X-Jaca-Original-URL"
    /// Set by the desktop to bounce a request back for a direct retry.
    static let divert = "X-Jaca-Divert"
    /// Value of `divert` meaning "not mocking this — send it yourself".
    static let retryDirect = "retry-direct"
    /// Status paired with `retryDirect`. 599 is unassigned, so it can't collide with an origin.
    static let retryDirectStatus = 599
    /// Stamped on any response a rule produced, carrying the rule's UUID.
    static let override = "X-Jaca-Override"

    /// True for every Jaca-internal header, which must never reach a real origin.
    static func isJacaInternal(_ name: String) -> Bool {
        name.lowercased().hasPrefix("x-jaca-")
    }
}
