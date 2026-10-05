import XCTest
@testable import Jaca

/// `divertHosts` decides which traffic leaves the device's own network. The editor used to only add
/// derived hosts, so a changed pattern kept routing its old host — and that stale value satisfied
/// the "at least one host" check, saving a rule that routed traffic it could never match.
final class DivertHostSyncTests: XCTestCase {

    func test_patternThatNamesAHostDerivesIt() {
        let next = DivertHostSync.afterMatcherChange(.init(hosts: [], isDerived: false),
                                                     derived: ["api.example.com"])
        XCTAssertEqual(next, .init(hosts: ["api.example.com"], isDerived: true))
    }

    /// The bug: `https://api.example.com/*` → `https://*.other.com/*` kept `api.example.com`.
    func test_derivedHostsAreDroppedWhenThePatternStopsNamingAHost() {
        let derived = DivertHostSync.State(hosts: ["api.example.com"], isDerived: true)
        let next = DivertHostSync.afterMatcherChange(derived, derived: [])
        XCTAssertTrue(next.hosts.isEmpty, "a stale derived host must not survive to satisfy the save check")
        XCTAssertFalse(next.isDerived)
    }

    func test_hostsTheUserTypedSurviveAPatternThatNamesNone() {
        let typed = DivertHostSync.State(hosts: ["a.example.com", "b.example.com"], isDerived: false)
        XCTAssertEqual(DivertHostSync.afterMatcherChange(typed, derived: []), typed)
    }

    func test_aLiteralHostReplacesTypedHosts() {
        let typed = DivertHostSync.State(hosts: ["a.example.com"], isDerived: false)
        let next = DivertHostSync.afterMatcherChange(typed, derived: ["api.example.com"])
        XCTAssertEqual(next, .init(hosts: ["api.example.com"], isDerived: true))
    }

    func test_typingMakesTheSetTheUsers() {
        XCTAssertEqual(DivertHostSync.afterUserEdit(hosts: ["x.com"]), .init(hosts: ["x.com"], isDerived: false))
    }

    func test_openingARuleRecognisesDerivedHosts() {
        XCTAssertTrue(DivertHostSync.initial(hosts: ["api.example.com"], derived: ["api.example.com"]).isDerived)
        // Saved under a wildcard pattern, so the user typed them.
        XCTAssertFalse(DivertHostSync.initial(hosts: ["api.example.com"], derived: []).isDerived)
        XCTAssertFalse(DivertHostSync.initial(hosts: [], derived: []).isDerived)
    }

    /// End to end against the real matcher: a regex never derives a host.
    func test_switchingToRegexDropsTheGlobsDerivedHost() {
        var matcher = OverrideMatcher()
        matcher.pattern = "https://api.example.com/v1/*"
        matcher.kind = .glob
        let glob = DivertHostSync.afterMatcherChange(.init(hosts: [], isDerived: false),
                                                     derived: OverrideCompiler.derivedDivertHosts(for: matcher))
        XCTAssertEqual(glob.hosts, ["api.example.com"])

        matcher.kind = .regex
        let regex = DivertHostSync.afterMatcherChange(glob, derived: OverrideCompiler.derivedDivertHosts(for: matcher))
        XCTAssertTrue(regex.hosts.isEmpty)
    }
}
