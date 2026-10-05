import XCTest
@testable import Jaca

/// `routedHosts` decides which traffic leaves the device's own network. The editor used to only add
/// derived hosts, so a changed pattern kept routing its old host — and that stale value satisfied
/// the "at least one host" check, saving a rule that routed traffic it could never match.
final class RoutedHostsSyncTests: XCTestCase {

    func test_patternThatNamesAHostDerivesIt() {
        let next = RoutedHostsSync.afterMatcherChange(.init(hosts: [], isDerived: false),
                                                     derived: ["api.example.com"])
        XCTAssertEqual(next, .init(hosts: ["api.example.com"], isDerived: true))
    }

    /// The bug: `https://api.example.com/*` → `https://*.other.com/*` kept `api.example.com`.
    func test_derivedHostsAreDroppedWhenThePatternStopsNamingAHost() {
        let derived = RoutedHostsSync.State(hosts: ["api.example.com"], isDerived: true)
        let next = RoutedHostsSync.afterMatcherChange(derived, derived: [])
        XCTAssertTrue(next.hosts.isEmpty, "a stale derived host must not survive to satisfy the save check")
        XCTAssertFalse(next.isDerived)
    }

    func test_hostsTheUserTypedSurviveAPatternThatNamesNone() {
        let typed = RoutedHostsSync.State(hosts: ["a.example.com", "b.example.com"], isDerived: false)
        XCTAssertEqual(RoutedHostsSync.afterMatcherChange(typed, derived: []), typed)
    }

    func test_aLiteralHostReplacesTypedHosts() {
        let typed = RoutedHostsSync.State(hosts: ["a.example.com"], isDerived: false)
        let next = RoutedHostsSync.afterMatcherChange(typed, derived: ["api.example.com"])
        XCTAssertEqual(next, .init(hosts: ["api.example.com"], isDerived: true))
    }

    func test_typingMakesTheSetTheUsers() {
        XCTAssertEqual(RoutedHostsSync.afterUserEdit(hosts: ["x.com"]), .init(hosts: ["x.com"], isDerived: false))
    }

    func test_openingARuleRecognisesDerivedHosts() {
        XCTAssertTrue(RoutedHostsSync.initial(hosts: ["api.example.com"], derived: ["api.example.com"]).isDerived)
        // Saved under a wildcard pattern, so the user typed them.
        XCTAssertFalse(RoutedHostsSync.initial(hosts: ["api.example.com"], derived: []).isDerived)
        XCTAssertFalse(RoutedHostsSync.initial(hosts: [], derived: []).isDerived)
    }

    /// End to end against the real matcher: a regex never derives a host.
    func test_switchingToRegexDropsTheGlobsDerivedHost() {
        var matcher = OverrideMatcher()
        matcher.pattern = "https://api.example.com/v1/*"
        matcher.kind = .glob
        let glob = RoutedHostsSync.afterMatcherChange(.init(hosts: [], isDerived: false),
                                                     derived: OverrideCompiler.derivedRoutedHosts(for: matcher))
        XCTAssertEqual(glob.hosts, ["api.example.com"])

        matcher.kind = .regex
        let regex = RoutedHostsSync.afterMatcherChange(glob, derived: OverrideCompiler.derivedRoutedHosts(for: matcher))
        XCTAssertTrue(regex.hosts.isEmpty)
    }
}
