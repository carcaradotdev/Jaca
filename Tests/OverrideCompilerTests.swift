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
        r.routedHosts = hosts ?? OverrideCompiler.derivedRoutedHosts(for: r.matcher)
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

    // MARK: - Route hosts (the blast radius)

    func test_routedHostsUnionOnlyEnabledRules() {
        let a = rule("https://a.com/**")
        let b = rule("https://b.com/**", enabled: false)
        let set = OverrideCompiler.compile([a, b], masterEnabled: true)
        XCTAssertEqual(set.routedHosts(deviceID: nil, appID: nil), ["a.com"])
    }

    /// Master off must route *nothing*: pausing overrides has to take the device's traffic
    /// completely off the tunnel, not just stop matching.
    func test_masterOffRoutesNoHosts() {
        let set = OverrideCompiler.compile([rule("https://a.com/**")], masterEnabled: false)
        XCTAssertTrue(set.routedHosts(deviceID: nil, appID: nil).isEmpty)
    }

    func test_routedHostsRespectScope() {
        let scoped = rule("https://a.com/**", scope: OverrideScope(appIDs: ["com.example"]))
        let set = OverrideCompiler.compile([scoped], masterEnabled: true)
        XCTAssertEqual(set.routedHosts(deviceID: nil, appID: "com.example"), ["a.com"])
        XCTAssertTrue(set.routedHosts(deviceID: nil, appID: "com.other").isEmpty)
    }

    /// The safety property that matters most: a rule that can't name its hosts contributes
    /// nothing, so Jaca can never end up tunnelling an app's entire traffic by accident.
    func test_ruleWithNoDerivableHostContributesNothing() {
        let wildcard = rule("**/product-state")
        XCTAssertTrue(wildcard.routedHosts.isEmpty)
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertTrue(set.routedHosts(deviceID: nil, appID: nil).isEmpty)
    }

    func test_explicitHostsAreHonouredForWildcardPatterns() {
        let wildcard = rule("**/product-state", hosts: ["api.example.com"])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertEqual(set.routedHosts(deviceID: nil, appID: nil), ["api.example.com"])
    }

    // MARK: - Routed hosts as a host filter under MITM

    func test_mitm_wildcardRuleFiresOnlyOnItsRoutedHosts() {
        let wildcard = rule("**/path", hosts: ["a.com"])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertNotNil(set.firstMatch(facts: facts("https://a.com/path"), method: "GET",
                                       deviceID: nil, appID: nil, transport: .mitmProxy))
        XCTAssertNil(set.firstMatch(facts: facts("https://b.com/path"), method: "GET",
                                    deviceID: nil, appID: nil, transport: .mitmProxy))
    }

    func test_agent_wildcardRuleStillFiresOnEveryHost() {
        let wildcard = rule("**/path", hosts: ["a.com"])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        let agent = InterceptTransportID.androidAgent(package: "com.example")
        XCTAssertNotNil(set.firstMatch(facts: facts("https://a.com/path"), method: "GET",
                                       deviceID: nil, appID: nil, transport: agent))
        XCTAssertNotNil(set.firstMatch(facts: facts("https://b.com/path"), method: "GET",
                                       deviceID: nil, appID: nil, transport: agent))
    }

    func test_mitm_ruleWithNoRoutedHostsMatchesEveryHost() {
        let wildcard = rule("**/path", hosts: [])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        for url in ["https://a.com/path", "https://b.com/path"] {
            XCTAssertNotNil(set.firstMatch(facts: facts(url), method: "GET",
                                           deviceID: nil, appID: nil, transport: .mitmProxy), url)
        }
    }

    /// A rule filtered out by host must not hide a later rule that does apply.
    func test_mitm_filteredRuleFallsThroughToTheNextRule() {
        let first = rule("**/path", name: "first", hosts: ["a.com"])
        let second = rule("**/path", name: "second", hosts: [])
        let set = OverrideCompiler.compile([first, second], masterEnabled: true)
        XCTAssertEqual(set.firstMatch(facts: facts("https://b.com/path"), method: "GET",
                                      deviceID: nil, appID: nil, transport: .mitmProxy)?.rule.name,
                       "second")
    }

    func test_mitm_hostCompareIgnoresCaseAndPort() {
        let wildcard = rule("**/path", hosts: ["API.Example.com:8443"])
        let set = OverrideCompiler.compile([wildcard], masterEnabled: true)
        XCTAssertNotNil(set.firstMatch(facts: facts("https://api.example.com:8443/path"), method: "GET",
                                       deviceID: nil, appID: nil, transport: .mitmProxy))
    }

    /// Generalize keeps the device's host as the routed host. In This Mac's Chrome capture,
    /// which is also `.mitmProxy`, the rule must still answer the dev server's other host.
    func test_mitm_browserCaptureIgnoresRoutedHosts() {
        let generalized = rule("**/lending/v1/offers", hosts: ["private-api.teya.xyz"])
        let set = OverrideCompiler.compile([generalized], masterEnabled: true)
        let browser = facts("http://localhost:3000/private-api/lending/v1/offers")
        XCTAssertNotNil(set.firstMatch(facts: browser, method: "GET", deviceID: Device.thisMac.id,
                                       appID: nil, transport: .mitmProxy))
        XCTAssertNil(set.firstMatch(facts: browser, method: "GET", deviceID: "emulator-5554",
                                    appID: nil, transport: .mitmProxy),
                     "a device proxy still limits the rule to its routed hosts")
        XCTAssertNotNil(set.firstMatch(facts: facts("https://private-api.teya.xyz/lending/v1/offers"),
                                       method: "GET", deviceID: "emulator-5554", appID: nil,
                                       transport: .mitmProxy))
    }

    /// The row badge and the context menu match through this, so they agree with the runtime.
    func test_uiHostFilterTransport_followsTheRuntime() {
        XCTAssertEqual(OverridesModel.hostFilterTransport(.mitmProxy, deviceID: "emulator-5554"), .mitmProxy)
        XCTAssertNil(OverridesModel.hostFilterTransport(.mitmProxy, deviceID: Device.thisMac.id))
        XCTAssertNil(OverridesModel.hostFilterTransport(nil, deviceID: "emulator-5554"))
        let filtered = rule("**/v1/users", hosts: ["api.prod.com"])
        let set = OverrideCompiler.compile([filtered], masterEnabled: true)
        XCTAssertNil(set.firstMatch(facts: facts("https://api.staging.com/v1/users"), method: "GET",
                                    deviceID: nil, appID: nil,
                                    transport: OverridesModel.hostFilterTransport(.mitmProxy, deviceID: "emulator-5554")))
    }

    func test_allMatches_appliesTheSameHostFilter() {
        let filtered = rule("**/path", name: "filtered", hosts: ["a.com"])
        let open = rule("**/path", name: "open", hosts: [])
        let set = OverrideCompiler.compile([filtered, open], masterEnabled: true)
        let names = set.allMatches(facts: facts("https://b.com/path"), method: "GET", deviceID: nil,
                                   appID: nil, transport: .mitmProxy).map(\.rule.name)
        XCTAssertEqual(names, ["open"])
        XCTAssertEqual(set.allMatches(facts: facts("https://b.com/path"), method: "GET", deviceID: nil,
                                      appID: nil).count, 2, "no transport, no filter")
    }

    func test_hostFilterNormalize() {
        XCTAssertEqual(OverrideHostFilter.normalize("A.com:443"), "a.com")
        XCTAssertEqual(OverrideHostFilter.normalize("[::1]:8080"), "::1")
        XCTAssertEqual(OverrideHostFilter.normalize("::1"), "::1")
        XCTAssertEqual(OverrideHostFilter.normalize("a.com"), "a.com")
    }

    func test_resolverAppliesTheHostFilterForMitmRequests() {
        var r = rule("**/path", hosts: ["a.com"])
        r.action = .respond(OverrideResponseSpec(statusCode: 418, body: .inline("")))
        let resolver = OverrideResolver(ruleSet: OverrideCompiler.compile([r], masterEnabled: true))

        let other = InterceptedRequest(method: "GET", url: "https://b.com/path", transport: .mitmProxy)
        let (decision, skip) = resolver.resolve(other, capabilities: .desktopTerminated)
        XCTAssertEqual(decision.action, .proceed)
        XCTAssertEqual(skip, .noRuleMatched)

        let routed = InterceptedRequest(method: "GET", url: "https://a.com/path", transport: .mitmProxy)
        guard case .respond = resolver.resolve(routed, capabilities: .desktopTerminated).0.action else {
            return XCTFail("expected .respond")
        }
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
