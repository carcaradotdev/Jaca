import XCTest
@testable import Jaca

/// Rule-set compilation: precedence, scoping, and — most importantly — how the routed-host set
/// is derived, since that set is the feature's blast radius.
final class OverrideCompilerTests: XCTestCase {

    private func rule(_ pattern: String, enabled: Bool = true, name: String = "",
                      methods: Set<String> = [], scope: OverrideScope = .init(),
                      hosts: Set<String>? = nil) -> OverrideRule {
        var r = OverrideRule(name: name,
                             matcher: OverrideMatcher(pattern: pattern, methods: methods),
                             scope: scope)
        r.enabled = enabled
        r.divertHosts = hosts ?? OverrideCompiler.derivedDivertHosts(for: r.matcher)
        return r
    }

    private func facts(_ url: String) -> URLFacts {
        OverrideMatching.facts(url: url)!
    }

    // MARK: - Precedence

    func test_firstEnabledRuleInListOrderWins() {
        let first = rule("https://a.com/**", name: "first")
        let second = rule("https://a.com/v1/**", name: "second")
        let set = OverrideCompiler.compile([first, second], masterEnabled: true)

        let winner = set.firstMatch(facts: facts("https://a.com/v1/users"), method: "GET",
                                    deviceID: nil, appID: nil)
        XCTAssertEqual(winner?.rule.name, "first",
                       "precedence is list order, not specificity — the table must be readable")
    }

    func test_reorderingChangesTheWinner() {
        let broad = rule("https://a.com/**", name: "broad")
        let narrow = rule("https://a.com/v1/**", name: "narrow")
        let set = OverrideCompiler.compile([narrow, broad], masterEnabled: true)
        XCTAssertEqual(set.firstMatch(facts: facts("https://a.com/v1/x"), method: "GET",
                                      deviceID: nil, appID: nil)?.rule.name, "narrow")
    }

    func test_disabledRulesAreNotCompiled() {
        let set = OverrideCompiler.compile([rule("https://a.com/**", enabled: false)],
                                           masterEnabled: true)
        XCTAssertTrue(set.rules.isEmpty)
    }

    func test_allMatchesReportsShadowing() {
        let first = rule("https://a.com/**", name: "first")
        let second = rule("https://a.com/v1/**", name: "second")
        let set = OverrideCompiler.compile([first, second], masterEnabled: true)
        let all = set.allMatches(facts: facts("https://a.com/v1/x"), method: "GET",
                                 deviceID: nil, appID: nil)
        XCTAssertEqual(all.map(\.rule.name), ["first", "second"])
    }

    // MARK: - Scope

    func test_scopeFiltersByAppAndDevice() {
        let scoped = rule("https://a.com/**", scope: OverrideScope(appIDs: ["com.example"]))
        let set = OverrideCompiler.compile([scoped], masterEnabled: true)

        XCTAssertNotNil(set.firstMatch(facts: facts("https://a.com/x"), method: "GET",
                                       deviceID: nil, appID: "com.example"))
        XCTAssertNil(set.firstMatch(facts: facts("https://a.com/x"), method: "GET",
                                    deviceID: nil, appID: "com.other"))
    }

    func test_emptyScopeMatchesAnything() {
        let set = OverrideCompiler.compile([rule("https://a.com/**")], masterEnabled: true)
        XCTAssertNotNil(set.firstMatch(facts: facts("https://a.com/x"), method: "GET",
                                       deviceID: "any", appID: "any"))
    }

    // MARK: - Divert hosts (the blast radius)

    func test_divertHostsUnionOnlyEnabledRules() {
        let a = rule("https://a.com/**")
        let b = rule("https://b.com/**", enabled: false)
        let set = OverrideCompiler.compile([a, b], masterEnabled: true)
        XCTAssertEqual(set.divertHosts(deviceID: nil, appID: nil), ["a.com"])
    }

    /// Master off must route *nothing*: pausing overrides has to take the device's traffic
    /// completely off the tunnel, not just stop matching.
    func test_masterOffRoutesNoHosts() {
        let set = OverrideCompiler.compile([rule("https://a.com/**")], masterEnabled: false)
        XCTAssertTrue(set.divertHosts(deviceID: nil, appID: nil).isEmpty)
    }

    func test_divertHostsRespectScope() {
        let scoped = rule("https://a.com/**", scope: OverrideScope(appIDs: ["com.example"]))
        let set = OverrideCompiler.compile([scoped], masterEnabled: true)
        XCTAssertEqual(set.divertHosts(deviceID: nil, appID: "com.example"), ["a.com"])
        XCTAssertTrue(set.divertHosts(deviceID: nil, appID: "com.other").isEmpty)
    }

    /// The safety property that matters most: a rule that can't name its hosts contributes
    /// nothing, so Jaca can never end up tunnelling an app's entire traffic by accident.
    func test_ruleWithNoDerivableHostContributesNothing() {
        let wildcard = rule("**/product-state")
        XCTAssertTrue(wildcard.divertHosts.isEmpty)
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertTrue(set.divertHosts(deviceID: nil, appID: nil).isEmpty)
    }

    func test_explicitHostsAreHonouredForWildcardPatterns() {
        let wildcard = rule("**/product-state", hosts: ["api.example.com"])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertEqual(set.divertHosts(deviceID: nil, appID: nil), ["api.example.com"])
    }

    // MARK: - Diagnostics

    func test_emptyPatternIsDiagnosedNotCompiled() {
        let empty = rule("")
        let set = OverrideCompiler.compile([empty], masterEnabled: true)
        XCTAssertTrue(set.rules.isEmpty)
        XCTAssertNotNil(set.diagnostics[empty.id])
    }

    func test_missingBodyFileIsDiagnosed() {
        var r = rule("https://a.com/**")
        r.action = .respond(OverrideResponseSpec(body: .file(path: "/nope/missing.json", watch: false)))
        let set = OverrideCompiler.compile([r], masterEnabled: true)
        XCTAssertNotNil(set.diagnostics[r.id])
        XCTAssertTrue(set.diagnostics[r.id]!.contains("missing"))
    }

    // MARK: - Resolver

    func test_resolverAppliesMatchingRuleAndFillsTheBody() {
        var r = rule("https://a.com/**")
        r.action = .respond(OverrideResponseSpec(statusCode: 418, body: .inline("{\"ok\":true}")))
        let resolver = OverrideResolver(ruleSet: OverrideCompiler.compile([r], masterEnabled: true))

        let request = InterceptedRequest(method: "GET", url: "https://a.com/v1", transport: .mitmProxy)
        let (decision, skip) = resolver.resolve(request, capabilities: .desktopTerminated)

        XCTAssertNil(skip)
        guard case .respond(let response) = decision.action else { return XCTFail("expected .respond") }
        XCTAssertEqual(response.statusCode, 418)
        XCTAssertEqual(response.body, Data("{\"ok\":true}".utf8))
    }

    /// Companion metadata rows have no parseable URL and must never match.
    func test_resolverIgnoresUnparseableURLs() {
        let r = rule("**")
        let resolver = OverrideResolver(ruleSet: OverrideCompiler.compile([r], masterEnabled: true))
        let request = InterceptedRequest(method: "GET", url: "api.example.com:443",
                                         transport: .companionMetadata)
        let (decision, skip) = resolver.resolve(request, capabilities: .observeOnly)
        XCTAssertEqual(decision.action, .proceed)
        XCTAssertEqual(skip, .noRuleMatched)
    }

    func test_resolverPublishesNewSnapshotsAtomically() {
        let resolver = OverrideResolver()
        XCTAssertTrue(resolver.current.rules.isEmpty)
        resolver.publish(OverrideCompiler.compile([rule("https://a.com/**")], masterEnabled: true))
        XCTAssertEqual(resolver.current.rules.count, 1)
    }
}
