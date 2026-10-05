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
        XCTAssertEqual(NetworkInspectionMode.default, .responseOverrides)
        XCTAssertEqual(resolve(nil), .responseOverrides)
    }

    func test_aStoredModeWinsOverTheLegacyToggles() {
        XCTAssertEqual(resolve("httpsDecryption", https: false, overrides: true), .httpsDecryption)
        XCTAssertEqual(resolve("responseOverrides", https: true, overrides: false), .responseOverrides)
    }

    /// "off" was the user's latest choice, so the old toggles must not overrule it.
    func test_storedOffIsTheDefaultNotTheLegacyToggles() {
        XCTAssertEqual(resolve("off", https: true, overrides: false), .responseOverrides)
    }

    func test_legacyToggles() {
        XCTAssertEqual(resolve(nil, https: true, overrides: false), .httpsDecryption,
                       "decryption alone was the only way to opt out of agent mode")
        XCTAssertEqual(resolve(nil, https: false, overrides: true), .responseOverrides)
        XCTAssertEqual(resolve(nil, https: true, overrides: true), .responseOverrides,
                       "both on was the broken pair; it resolves to the one that was failing")
    }

    func test_unreadableStoredValueFallsBackToTheLegacyToggles() {
        XCTAssertEqual(resolve("garbage", https: true, overrides: false), .httpsDecryption)
        XCTAssertEqual(resolve("", https: false, overrides: false), .responseOverrides)
    }

    /// Renaming a raw value would silently reset everyone's choice.
    func test_storedRawValuesAreStable() {
        XCTAssertEqual(NetworkInspectionMode.httpsDecryption.rawValue, "httpsDecryption")
        XCTAssertEqual(NetworkInspectionMode.responseOverrides.rawValue, "responseOverrides")
    }
}
