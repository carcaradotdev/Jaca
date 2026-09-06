import Foundation

/// Why a captured row can't seed an override rule, or nil when it can.
///
/// Answers *authoring*, not *arming*: a rule you can't apply this second is still worth writing,
/// and the row badge and toolbar say whether it will fire. Only reasons that make the row itself
/// unusable as a seed belong here.
enum OverrideRowGate {

    static func unavailableReason(transport: InterceptTransportID,
                                  arming: InterceptArmingState,
                                  hasRunningSource: Bool,
                                  overridesAvailable: Bool,
                                  featureEnabled: Bool,
                                  url: String,
                                  /// Android-only, so consulted for `.agentDivert` and nowhere
                                  /// else. nil means *unknown* (an agent predating `httpStack`)
                                  /// and must never block authoring.
                                  httpStack: String?) -> String? {
        guard overridesAvailable else { return "Response overrides aren't available." }
        guard featureEnabled else { return "Turn on Response overrides in Settings first." }

        // Companion flow-metadata rows are "host:port" — no method, path or body to override.
        if OverrideMatching.facts(url: url) == nil {
            return "This row is flow metadata, not an HTTP request."
        }

        switch transport {
        case .companionMetadata:
            return "Overrides apply to in-process agent capture. Companion capture will follow."
        case .agentDivert:
            // `httpStack` is the only reliable signal: `callStack` strips okhttp frames, so
            // testing *it* here disabled every row (OverrideAuthoringTests).
            if let httpStack, httpStack != "okhttp3" {
                return "This request came from \(InterceptTransportID.stackLabel(httpStack)), "
                     + "not okhttp3 — Jaca can't divert it."
            }
        case .iosSimulatorDivert, .mitmProxy:
            // No stack check: the iOS agent hooks `URLSession`, so everything it reports is
            // divertible, and the proxy never learns which client stack sent a request.
            break
        }

        // Arming states only mean anything while a source runs: otherwise `.idle` just means
        // "capture is stopped", which is no reason to refuse a rule.
        if hasRunningSource, case .detached(let appID) = arming {
            return InterceptArmingState.detached(appID: appID).blockedMessage
        }
        return nil
    }
}
