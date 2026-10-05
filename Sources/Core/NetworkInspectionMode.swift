import Foundation

/// How Jaca debugs HTTPS: through the in-process agent (the default), or as a man-in-the-middle via
/// the companion app. Exclusive by construction: see `FeatureFlags.networkInspectionMode` for why
/// the two can't both be on.
///
/// There is no "off". The agent captures either way, so off only differed from agent mode by
/// withholding response overrides, which route nothing until a rule is enabled anyway.
enum NetworkInspectionMode: String, CaseIterable, Sendable {
    // Named after the Settings choices. The raw values are what's stored on disk and predate those
    // names, so they're spelled out: renaming a case must never change what's read back.
    case agentHTTPSDebugging = "responseOverrides"
    case mitmHTTPSDebugging = "httpsDecryption"

    static let `default`: NetworkInspectionMode = .agentHTTPSDebugging

    /// The mode for what's stored. `stored` wins when it names a current mode. A build briefly
    /// offered "off", which is now the default; anything else unreadable falls back to the two
    /// toggles this replaced. Decryption-only was the one way to opt out of agent mode, so it's the
    /// only combination that keeps HTTPS debugging; both on was the broken pair, and resolves to the
    /// agent, the one that was visibly failing.
    static func resolve(stored: String?, legacyHTTPSDecryption: Bool,
                        legacyResponseOverrides: Bool) -> NetworkInspectionMode {
        if let stored {
            if let mode = NetworkInspectionMode(rawValue: stored) { return mode }
            if stored == "off" { return .default }
        }
        return legacyHTTPSDecryption && !legacyResponseOverrides ? .mitmHTTPSDebugging : .default
    }
}
