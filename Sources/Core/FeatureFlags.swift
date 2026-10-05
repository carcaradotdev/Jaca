import Foundation

/// Process-wide, persisted feature flags. Kept tiny and dependency-free so both `Core`
/// (e.g. `CaptureSourceRegistry`) and `Model`/`Features` can read the same value.
enum FeatureFlags {
    /// How HTTPS is debugged: through the agent (the default) or as a man-in-the-middle.
    ///
    /// These were two independent toggles, but they aren't independent: response overrides only run
    /// in the in-process agent, and HTTPS decryption is the companion source, which can't apply a
    /// rule. With both on, tabs led with companion capture and every rule read "not here". One
    /// three-way setting makes that combination unrepresentable.
    static let networkInspectionModeKey = "networkInspectionMode"
    static var networkInspectionMode: NetworkInspectionMode {
        get {
            NetworkInspectionMode.resolve(
                stored: UserDefaults.standard.string(forKey: networkInspectionModeKey),
                legacyHTTPSDecryption: UserDefaults.standard.bool(forKey: legacyHTTPSDecryptionKey),
                legacyResponseOverrides: UserDefaults.standard.bool(forKey: legacyResponseOverridesKey))
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: networkInspectionModeKey) }
    }

    /// The two settings the mode replaced. Read only to migrate, and never deleted, so an older
    /// build run afterwards still finds what the user had.
    static let legacyHTTPSDecryptionKey = "httpsDecryptionEnabled"
    static let legacyResponseOverridesKey = "responseOverridesEnabled"

    /// Companion + HTTPS decryption (CA install, device-wide capture). When off, the companion
    /// subsystem is never started and network inspection offers only the in-process Agent.
    static var httpsDecryptionEnabled: Bool { networkInspectionMode == .httpsDecryption }

    /// Response overrides (answer a matched request from a rule instead of the origin). Arming it
    /// routes selected hosts through the Mac — over an `adb reverse` tunnel on Android, over the
    /// shared loopback on the iOS Simulator — so it stays opt-in.
    static var responseOverridesEnabled: Bool { networkInspectionMode == .responseOverrides }

    /// Whether Jaca may relaunch a **simulator** app itself to put the agent back, after the user
    /// reopened that app outside Jaca.
    ///
    /// OFF by default, and that default is the feature: restarting somebody's app throws away
    /// whatever state they had navigated to. Asking (the attach banner's button) is the default;
    /// this only removes the click, and the relaunch still announces itself.
    ///
    /// Only in Agent HTTPS debugging. A simulator has no companion app, so its tabs still capture
    /// through the agent under HTTPS debugging, and the supervisor reads this per decision there
    /// too: gating only the Settings toggle would leave a stored "on" still relaunching apps.
    static let simulatorAutoReattachKey = "simulatorAutoReattachEnabled"
    static var simulatorAutoReattachEnabled: Bool {
        // `bool(forKey:)` is false for a missing key, which is exactly the wanted default. The
        // stored preference is kept as-is under HTTPS debugging, so switching back restores it.
        get { UserDefaults.standard.bool(forKey: simulatorAutoReattachKey) && responseOverridesEnabled }
        set { UserDefaults.standard.set(newValue, forKey: simulatorAutoReattachKey) }
    }

    /// The user's master switch for overrides — distinct from the feature flag above: the flag
    /// says "this feature exists for me", this says "apply my rules right now".
    static let overridesMasterKey = "networkOverridesMasterEnabled"
    static var overridesMasterEnabled: Bool {
        get { UserDefaults.standard.object(forKey: overridesMasterKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: overridesMasterKey) }
    }
}
