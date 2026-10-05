import XCTest
@testable import Jaca

/// What's stored has to land on the mode the user last chose — through a build that briefly offered
/// "off", and from the two toggles this replaced. Only the pure resolution is tested; the real
/// `UserDefaults` belongs to the developer's running app.
final class NetworkInspectionModeTests: XCTestCase {

    private func resolve(_ stored: String?, https: Bool = false, overrides: Bool = false) -> NetworkInspectionMode {
        NetworkInspectionMode.resolve(stored: stored, legacyHTTPSDecryption: https, legacyResponseOverrides: overrides)
    }

    func test_agentIsTheDefault() {
        XCTAssertEqual(NetworkInspectionMode.default, .agentHTTPSDebugging)
        XCTAssertEqual(resolve(nil), .agentHTTPSDebugging)
    }

    func test_aStoredModeWinsOverTheLegacyToggles() {
        XCTAssertEqual(resolve("httpsDecryption", https: false, overrides: true), .mitmHTTPSDebugging)
        XCTAssertEqual(resolve("responseOverrides", https: true, overrides: false), .agentHTTPSDebugging)
    }

    /// "off" was the user's latest choice, so the old toggles must not overrule it.
    func test_storedOffIsTheDefaultNotTheLegacyToggles() {
        XCTAssertEqual(resolve("off", https: true, overrides: false), .agentHTTPSDebugging)
    }

    func test_legacyToggles() {
        XCTAssertEqual(resolve(nil, https: true, overrides: false), .mitmHTTPSDebugging,
                       "decryption alone was the only way to opt out of agent mode")
        XCTAssertEqual(resolve(nil, https: false, overrides: true), .agentHTTPSDebugging)
        XCTAssertEqual(resolve(nil, https: true, overrides: true), .agentHTTPSDebugging,
                       "both on was the broken pair; it resolves to the one that was failing")
    }

    func test_unreadableStoredValueFallsBackToTheLegacyToggles() {
        XCTAssertEqual(resolve("garbage", https: true, overrides: false), .mitmHTTPSDebugging)
        XCTAssertEqual(resolve("", https: false, overrides: false), .agentHTTPSDebugging)
    }

    /// The settings' `UserDefaults` keys. Two of them are literally the old flag names, so a
    /// find-and-replace over those identifiers would rewrite the strings too — and silently drop
    /// everyone's migrated setting.
    func test_storedKeysAreStable() {
        XCTAssertEqual(FeatureFlags.networkInspectionModeKey, "networkInspectionMode")
        XCTAssertEqual(FeatureFlags.legacyHTTPSDecryptionKey, "httpsDecryptionEnabled")
        XCTAssertEqual(FeatureFlags.legacyResponseOverridesKey, "responseOverridesEnabled")
        XCTAssertEqual(FeatureFlags.simulatorAutoReattachKey, "simulatorAutoReattachEnabled")
        XCTAssertEqual(FeatureFlags.overridesMasterKey, "networkOverridesMasterEnabled")
    }

    /// Renaming a raw value would silently reset everyone's choice.
    func test_storedRawValuesAreStable() {
        XCTAssertEqual(NetworkInspectionMode.mitmHTTPSDebugging.rawValue, "httpsDecryption")
        XCTAssertEqual(NetworkInspectionMode.agentHTTPSDebugging.rawValue, "responseOverrides")
    }
}
