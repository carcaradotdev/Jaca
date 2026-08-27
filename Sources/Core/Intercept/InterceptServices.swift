import Foundation

/// What a capture source needs in order to participate in interception, handed to it through
/// `CaptureContext` exactly like `companion: CompanionHub?` already is.
///
/// This is the boundary that keeps the layering honest: a transport receives a *resolver*, an
/// *origin client* and a *reporter*, and never sees `OverridesModel`, the rule list, or SwiftUI.
/// Everything flows one way — the model publishes snapshots into the resolver, transports read
/// them, and results come back through the reporter.
/// Identifies one armed transport: a specific app on a specific device.
///
/// Keying by package alone cross-wired two devices running the same app — the second
/// registration replaced the first, orphaning its host-set updates.
struct InterceptTarget: Sendable, Hashable {
    var deviceID: String
    var package: String
}

struct InterceptServices: Sendable {
    /// Evaluates rules. Thread-safe and synchronous, so it can be called from a NIO event loop.
    var resolver: InterceptResolving
    /// Records what happened, so the UI can badge rows and count hits.
    var reporter: InterceptReporting
    /// Told when a transport's arming state changes (server bound, tunnel failed, disarmed).
    var onArmingChange: @Sendable (InterceptTarget, AgentDivertCoordinator.State) -> Void
    /// Told about each transport's coordinator, so the model can push host-set changes to it.
    var onRegisterCoordinator: @Sendable (InterceptTarget, AgentDivertCoordinator?) -> Void

    /// Builds the pipeline for one interception point.
    ///
    /// The redirect policy is the one genuinely transport-specific piece: a diverted app must have
    /// redirects followed on the Mac (otherwise it leaves the tunnel chasing a 3xx), while the
    /// MITM proxy must *not* follow them (the client re-requests each hop through us, so following
    /// would hide hops from capture).
    func pipeline(for transport: InterceptTransportID,
                  deviceID: String?, appID: String?) -> InterceptPipeline {
        let policy: OriginClient.RedirectPolicy
        switch transport {
        case .agentDivert, .iosSimulatorDivert: policy = .follow(max: 5)
        case .mitmProxy, .companionMetadata:    policy = .doNotFollow
        }
        return InterceptPipeline(
            resolver: resolver,
            origin: OriginClient(upstream: UpstreamClient(), policy: policy),
            reporter: reporter
        )
    }

    func reportArming(target: InterceptTarget, state: AgentDivertCoordinator.State) {
        onArmingChange(target, state)
    }

    func register(target: InterceptTarget, coordinator: AgentDivertCoordinator?) {
        onRegisterCoordinator(target, coordinator)
    }
}

/// Reads the agent's `hello` frame.
///
/// The desktop pushes an override endpoint only after seeing `override/1`, so an agent built
/// before this feature — which never reads its socket — is simply never spoken to.
enum AgentHelloParser {
    static func advertisesOverrideSupport(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "hello" else { return false }
        let caps = (obj["caps"] as? [Any])?.compactMap { $0 as? String } ?? []
        return caps.contains("override/1")
    }
}
