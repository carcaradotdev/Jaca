import Foundation

/// Process-wide, persisted feature flags. Kept tiny and dependency-free so both `Core`
/// (e.g. `CaptureSourceRegistry`) and `Model`/`Features` can read the same value.
enum FeatureFlags {
    /// Companion + HTTPS decryption (CA install, device-wide capture). OFF by default and
    /// fully opt-in: when off, the companion subsystem is never started and network inspection
    /// offers only the in-process Agent. Experimental — see the Settings description.
    static let httpsDecryptionKey = "httpsDecryptionEnabled"
    static var httpsDecryptionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: httpsDecryptionKey) }
        set { UserDefaults.standard.set(newValue, forKey: httpsDecryptionKey) }
    }

    /// Response overrides (answer a matched request from a rule instead of the origin).
    /// OFF by default: arming it routes selected hosts through the Mac over an adb tunnel, so it
    /// stays opt-in until the user asks for it.
    static let responseOverridesKey = "responseOverridesEnabled"
    static var responseOverridesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: responseOverridesKey) }
        set { UserDefaults.standard.set(newValue, forKey: responseOverridesKey) }
    }

    /// The user's master switch for overrides — distinct from the feature flag above: the flag
    /// says "this feature exists for me", this says "apply my rules right now".
    static let overridesMasterKey = "networkOverridesMasterEnabled"
    static var overridesMasterEnabled: Bool {
        get { UserDefaults.standard.object(forKey: overridesMasterKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: overridesMasterKey) }
    }
}
