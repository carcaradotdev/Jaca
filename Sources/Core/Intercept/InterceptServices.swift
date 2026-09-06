import Foundation

/// Identifies one armed transport: a specific app on a specific device.
///
/// Keying by package alone cross-wired two devices running the same app — the second
/// registration replaced the first, orphaning its host-set updates.
struct InterceptTarget: Sendable, Hashable {
    var deviceID: String
    var package: String
}

/// What a capture source needs to participate in interception, handed to it through
/// `CaptureContext` exactly like `companion: CompanionHub?`.
///
/// The boundary that keeps the layering honest: a transport gets a resolver, an origin client and
/// a reporter, and never sees `OverridesModel`, the rule list, or SwiftUI.
struct InterceptServices: Sendable {
    /// Evaluates rules. Thread-safe and synchronous, so it can be called from a NIO event loop.
    var resolver: InterceptResolving
    /// Records what happened, so the UI can badge rows and count hits.
    var reporter: InterceptReporting
    /// Told when a transport's arming state changes (server bound, tunnel failed, disarmed).
    var onArmingChange: @Sendable (InterceptTarget, DivertCoordinator?, InterceptArmingState) -> Void
    /// Told about each transport's coordinator, so the model can push host-set changes to it.
    var onRegisterCoordinator: @Sendable (InterceptTarget, DivertCoordinator) -> Void
    /// Told when a coordinator tears down. Identity-carrying on purpose — see `deregister`.
    var onDeregisterCoordinator: @Sendable (InterceptTarget, DivertCoordinator) -> Void

    /// Builds the pipeline for one interception point.
    func pipeline(for transport: InterceptTransportID,
                  deviceID: String?, appID: String?) -> InterceptPipeline {
        InterceptPipeline(
            resolver: resolver,
            origin: OriginClient(upstream: UpstreamClient(),
                                 policy: Self.redirectPolicy(for: transport)),
            reporter: reporter
        )
    }

    /// The one transport-specific piece of the pipeline, pulled out so it can be asserted
    /// directly. A diverted app needs redirects followed on the Mac (otherwise it leaves the
    /// tunnel chasing a 3xx); the MITM proxy must not, or it hides hops the client re-requests.
    static func redirectPolicy(for transport: InterceptTransportID) -> OriginClient.RedirectPolicy {
        switch transport {
        case .agentDivert, .iosSimulatorDivert: return .follow(max: 5)
        case .mitmProxy, .companionMetadata:    return .doNotFollow
        }
    }

    /// Reports arming state. `coordinator` identifies the reporter so the model can drop a stale
    /// report; `nil` is a controller-level failure raised before (or without) a coordinator.
    func reportArming(target: InterceptTarget, coordinator: DivertCoordinator?,
                      state: InterceptArmingState) {
        onArmingChange(target, coordinator, state)
    }

    func register(target: InterceptTarget, coordinator: DivertCoordinator) {
        onRegisterCoordinator(target, coordinator)
    }

    /// Drops `coordinator` **only if it is still the registered one**. The target is identical
    /// across a stop/start of the same app, and teardown takes at least a ~300 ms flush — so a
    /// restart inside that window would otherwise have the old teardown evict the new
    /// registration, leaving `republish()` unable to reach the live coordinator.
    func deregister(target: InterceptTarget, coordinator: DivertCoordinator) {
        onDeregisterCoordinator(target, coordinator)
    }
}
