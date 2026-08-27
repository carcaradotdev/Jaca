import XCTest
@testable import Jaca

/// The frozen matcher semantics. This table *is* the specification — the UI's hint text
/// ("`*` one segment · `**` any depth · query ignored unless you write `?`") promises exactly
/// these behaviours, so a change here is a change to the product.
final class OverrideMatchingTests: XCTestCase {

    // MARK: - Helpers

    private func rule(_ pattern: String,
                      kind: OverrideMatcher.Kind = .glob,
                      methods: Set<String> = []) -> CompiledRule {
        let r = OverrideRule(matcher: OverrideMatcher(pattern: pattern, kind: kind, methods: methods))
        let set = OverrideCompiler.compile([r], masterEnabled: true)
        guard let compiled = set.rules.first else {
            XCTFail("pattern failed to compile: \(pattern)")
            return CompiledRule(rule: r, program: nil, regex: nil)
        }
        return compiled
    }

    private func matches(_ pattern: String, _ url: String,
                         method: String = "GET",
                         kind: OverrideMatcher.Kind = .glob,
                         methods: Set<String> = []) -> Bool {
        guard let facts = OverrideMatching.facts(url: url) else { return false }
        return OverrideMatching.matches(rule(pattern, kind: kind, methods: methods), facts, method: method)
    }

    // MARK: - URL parsing

    func test_facts_parsesSchemeHostPathAndQuery() {
        let f = OverrideMatching.facts(url: "https://API.Example.com/v1/Users?a=1&a=2&b=x")
        XCTAssertEqual(f?.scheme, "https")
        XCTAssertEqual(f?.host, "api.example.com")       // host lowercased
        XCTAssertEqual(f?.path, "/v1/Users")             // path case preserved
        XCTAssertEqual(f?.query["a"], ["1", "2"])
        XCTAssertEqual(f?.query["b"], ["x"])
        XCTAssertNil(f?.port)
    }

    func test_facts_pathDefaultsToSlash() {
        XCTAssertEqual(OverrideMatching.facts(url: "https://example.com")?.path, "/")
    }

    /// Companion flow-metadata rows are `"host:port"`, not URLs. They must never match a rule —
    /// there is no HTTP exchange there to override.
    func test_facts_rejectsCompanionMetadataForm() {
        XCTAssertNil(OverrideMatching.facts(url: "api.example.com:443"))
        XCTAssertNil(OverrideMatching.facts(url: ""))
        XCTAssertNil(OverrideMatching.facts(url: "not a url"))
    }

    // MARK: - Anchoring

    func test_patternMustMatchTheWholeURL() {
        XCTAssertFalse(matches("https://a.com/v1", "https://a.com/v1/users"))
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1"))
        XCTAssertTrue(matches("https://a.com/v1/**", "https://a.com/v1/users"))
    }

    // MARK: - `*` vs `**`

    func test_singleStarMatchesOneSegmentOnly() {
        XCTAssertTrue(matches("https://a.com/v1/*/state", "https://a.com/v1/abc/state"))
        XCTAssertFalse(matches("https://a.com/v1/*/state", "https://a.com/v1/abc/def/state"))
    }

    func test_globstarCrossesSlashes() {
        XCTAssertTrue(matches("https://a.com/**/state", "https://a.com/v1/abc/def/state"))
        XCTAssertTrue(matches("https://a.com/**", "https://a.com/a/b/c/d"))
    }

    /// A `*` that runs out of room must hand back to the `**` before it.
    ///
    /// The matcher kept a single backtrack slot, so a later `*` overwrote the globstar's — and
    /// since `*` may not cross `/`, it could never recover. Both of these have a valid match that
    /// the matcher used to miss, silently: the rule never fired and the editor's preview said
    /// "nothing matches", with nothing anywhere to explain why.
    func test_starFallsBackToAnEarlierGlobstar() {
        // `**` must give up the first `/api/` and take `x.com/api/v2` instead.
        XCTAssertTrue(matches("**/api/*", "https://x.com/api/v2/api/thing"))
        // `**` → `z/v1/q`, then the literal `/v1/`, then `*` → `ab`, then `x`.
        XCTAssertTrue(matches("https://a.com/**/v1/*x", "https://a.com/z/v1/q/v1/abx"))
    }

    /// The fall-back must not turn `*` into `**` — a genuine non-match stays a non-match.
    func test_backtrackingStillRefusesToLetAStarCrossASlash() {
        XCTAssertFalse(matches("https://a.com/*", "https://a.com/one/two"))
        XCTAssertFalse(matches("https://a.com/**/v1/*x", "https://a.com/z/v1/q/ab/x"))
    }

    func test_globstarMatchesEmpty() {
        XCTAssertTrue(matches("https://a.com/v1**", "https://a.com/v1"))
    }

    // MARK: - Scheme

    func test_omittedSchemeMatchesEither() {
        XCTAssertTrue(matches("a.com/v1", "https://a.com/v1"))
        XCTAssertTrue(matches("a.com/v1", "http://a.com/v1"))
    }

    func test_explicitSchemeIsRequired() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1"))
        XCTAssertFalse(matches("https://a.com/v1", "http://a.com/v1"))
    }

    // MARK: - Host / port / case

    func test_hostIsCaseInsensitive_pathIsCaseSensitive() {
        XCTAssertTrue(matches("https://API.example.com/v1", "https://api.EXAMPLE.com/v1"))
        XCTAssertFalse(matches("https://a.com/Users", "https://a.com/users"))
    }

    func test_portComparedOnlyWhenPatternNamesOne() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com:8443/v1"))
        XCTAssertTrue(matches("https://a.com:8443/v1", "https://a.com:8443/v1"))
        XCTAssertFalse(matches("https://a.com:9999/v1", "https://a.com:8443/v1"))
    }

    // MARK: - Query

    func test_queryIgnoredUnlessPatternHasQuestionMark() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1?locale=en&x=1"))
    }

    func test_queryRequirementIsASubsetMatch() {
        XCTAssertTrue(matches("https://a.com/v1?locale=en", "https://a.com/v1?locale=en&extra=1"))
        XCTAssertTrue(matches("https://a.com/v1?locale=en", "https://a.com/v1?extra=1&locale=en"))
        XCTAssertFalse(matches("https://a.com/v1?locale=en", "https://a.com/v1?locale=fr"))
        XCTAssertFalse(matches("https://a.com/v1?locale=en", "https://a.com/v1"))
    }

    func test_queryValueWildcard() {
        XCTAssertTrue(matches("https://a.com/v1?token=*", "https://a.com/v1?token=abc123"))
    }

    func test_fragmentIsNeverMatched() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1#section"))
    }

    // MARK: - Methods

    func test_emptyMethodSetMatchesAnyMethod() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1", method: "POST"))
    }

    func test_methodFilterIsRespected() {
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1", method: "GET", methods: ["GET"]))
        XCTAssertFalse(matches("https://a.com/v1", "https://a.com/v1", method: "POST", methods: ["GET"]))
        XCTAssertTrue(matches("https://a.com/v1", "https://a.com/v1", method: "post", methods: ["POST"]))
    }

    // MARK: - Regex

    func test_regexIsAnchoredToTheWholeURL() {
        XCTAssertTrue(matches(".*/product-state", "https://a.com/v1/product-state", kind: .regex))
        XCTAssertFalse(matches("/product-state", "https://a.com/v1/product-state", kind: .regex))
    }

    func test_invalidRegexDoesNotCompileAndNeverMatches() {
        let r = OverrideRule(matcher: OverrideMatcher(pattern: "([", kind: .regex))
        let set = OverrideCompiler.compile([r], masterEnabled: true)
        XCTAssertTrue(set.rules.isEmpty)
        XCTAssertNotNil(set.diagnostics[r.id])
    }

    // MARK: - Divert-host derivation

    func test_literalHostIsDerivedFromPattern() {
        XCTAssertEqual(OverrideCompiler.derivedDivertHosts(
            for: OverrideMatcher(pattern: "https://api.teya.xyz/lending/**")), ["api.teya.xyz"])
        XCTAssertEqual(OverrideCompiler.derivedDivertHosts(
            for: OverrideMatcher(pattern: "api.teya.xyz/lending/**")), ["api.teya.xyz"])
    }

    /// A wildcarded host must yield **empty**, never "all hosts" — that emptiness is what makes
    /// the editor ask the user which hosts to route, so Jaca never tunnels everything by accident.
    func test_wildcardHostDerivesNoDivertHosts() {
        XCTAssertTrue(OverrideCompiler.derivedDivertHosts(
            for: OverrideMatcher(pattern: "**/product-state")).isEmpty)
        XCTAssertTrue(OverrideCompiler.derivedDivertHosts(
            for: OverrideMatcher(pattern: "*.teya.xyz/v1/**")).isEmpty)
        XCTAssertTrue(OverrideCompiler.derivedDivertHosts(
            for: OverrideMatcher(pattern: ".*", kind: .regex)).isEmpty)
    }

    // MARK: - Generalize

    func test_generalizeReplacesUUIDAndNumericSegments() {
        XCTAssertEqual(
            OverrideMatching.generalize("https://a.com/v1/companies/3F2504E0-4F89-11D3-9A0C-0305E82C3301/state"),
            "https://a.com/v1/companies/*/state")
        XCTAssertEqual(OverrideMatching.generalize("https://a.com/users/12345/posts"),
                       "https://a.com/users/*/posts")
    }

    func test_generalizeLeavesRouteSegmentsAlone() {
        XCTAssertEqual(OverrideMatching.generalize("https://a.com/lending/v1/product-state"),
                       "https://a.com/lending/v1/product-state")
    }
}
