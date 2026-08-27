import XCTest
@testable import Jaca

/// Regressions for the two bugs that made response overrides unusable on first release:
/// the context-menu item was disabled on every row, and a newly created rule was silently
/// discarded instead of saved.
final class OverrideAuthoringTests: XCTestCase {

    // MARK: - Bug 1: every row's override item was disabled

    /// `callStack` deliberately strips okhttp/okio frames (`SqueezeTracker.isInfraFrame`) so the
    /// stack starts at app code. The UI used to test it for an "okhttp3." frame, which is
    /// therefore **never** present — disabling "Override response…" on every single row.
    /// `httpStack` is the signal that actually carries this.
    func test_agentCallStackNeverContainsOkhttpFrames_soItCannotIdentifyTheStack() {
        let line = """
        {"type":"txn","method":"GET","url":"https://a.com/v1","status":200,
         "callStack":["com.example.Repo.load(Repo.kt:42)","com.example.VM.refresh(VM.kt:10)"],
         "httpStack":"okhttp3"}
        """
        let txn = AgentTransactionParser.parse(line)
        XCTAssertNotNil(txn)
        XCTAssertFalse(txn!.callStack!.contains { $0.contains("okhttp3.") },
                       "callStack is app-code only by design — never test it for the HTTP stack")
        XCTAssertEqual(txn!.httpStack, "okhttp3")
    }

    func test_httpStackIsParsedForEachStack() {
        for stack in ["okhttp3", "okhttp2", "urlconnection"] {
            let line = "{\"type\":\"txn\",\"method\":\"GET\",\"url\":\"https://a.com\",\"httpStack\":\"\(stack)\"}"
            XCTAssertEqual(AgentTransactionParser.parse(line)?.httpStack, stack)
        }
    }

    /// An agent built before `httpStack` existed reports nothing. That must read as *unknown*,
    /// not *unsupported* — otherwise upgrading Jaca without rebuilding the agent silently
    /// disables the feature again.
    func test_missingHttpStackDecodesAsNilNotEmpty() {
        let line = "{\"type\":\"txn\",\"method\":\"GET\",\"url\":\"https://a.com\",\"status\":200}"
        let txn = AgentTransactionParser.parse(line)
        XCTAssertNotNil(txn)
        XCTAssertNil(txn?.httpStack)
    }

    // MARK: - Bug 2: a new rule was silently discarded

    /// `update(_:)` no-ops on an unknown id. The popover's "New override" called it directly, so
    /// every rule created that way vanished on save. `save(_:)` must handle both cases.
    @MainActor
    func test_saveAddsARuleThatDoesNotExistYet() {
        let model = OverridesModel()
        let existingCount = model.rules.count

        let fresh = OverrideRule(name: "Fresh",
                                 matcher: OverrideMatcher(pattern: "https://a.com/**"))
        model.save(fresh)

        XCTAssertEqual(model.rules.count, existingCount + 1)
        XCTAssertTrue(model.rules.contains { $0.id == fresh.id }, "a new rule must be added, not dropped")
        model.remove(fresh.id)
    }

    @MainActor
    func test_saveUpdatesARuleThatAlreadyExists() {
        let model = OverridesModel()
        var rule = OverrideRule(name: "Before", matcher: OverrideMatcher(pattern: "https://a.com/**"))
        model.save(rule)
        let countAfterAdd = model.rules.count

        rule.name = "After"
        model.save(rule)

        XCTAssertEqual(model.rules.count, countAfterAdd, "updating must not duplicate")
        XCTAssertEqual(model.rules.first { $0.id == rule.id }?.name, "After")
        model.remove(rule.id)
    }

    /// New rules are enabled by default…
    @MainActor
    func test_newRuleIsEnabledByDefault() {
        let model = OverridesModel()
        let rule = OverrideRule(name: "Default", matcher: OverrideMatcher(pattern: "https://a.com/**"))
        model.save(rule)
        XCTAssertEqual(model.rules.first { $0.id == rule.id }?.enabled, true)
        model.remove(rule.id)
    }

    /// …but an explicit choice in the editor must survive the save. `add` used to force
    /// `enabled = true`, re-enabling a rule the user had just switched off.
    @MainActor
    func test_explicitlyDisabledNewRuleStaysDisabled() {
        let model = OverridesModel()
        var rule = OverrideRule(name: "Off", matcher: OverrideMatcher(pattern: "https://a.com/**"))
        rule.enabled = false
        model.save(rule)
        XCTAssertEqual(model.rules.first { $0.id == rule.id }?.enabled, false,
                       "saving must not override the user's explicit choice")
        model.remove(rule.id)
    }

    /// A rule created by right-clicking must have its routed host derived automatically —
    /// an empty host set arms nothing at all.
    @MainActor
    func test_savingDerivesTheDivertHostFromThePattern() {
        let model = OverridesModel()
        let rule = OverrideRule(name: "Derived",
                                matcher: OverrideMatcher(pattern: "https://api.example.com/v1/**"))
        model.save(rule)
        XCTAssertEqual(model.rules.first { $0.id == rule.id }?.divertHosts, ["api.example.com"])
        model.remove(rule.id)
    }

    // MARK: - Delay must never be stale

    /// Editing a rule's delay has to take effect on the next request. The resolver holds an
    /// immutable snapshot, so the risk is that an edit doesn't get republished.
    @MainActor
    func test_editingDelayIsVisibleToTheResolverImmediately() {
        let model = OverridesModel()
        var rule = OverrideRule(name: "delayed",
                                matcher: OverrideMatcher(pattern: "https://delay.example.com/**"),
                                delayMillis: 2000)
        model.save(rule)

        func decidedDelay() -> Duration? {
            let facts = OverrideMatching.facts(url: "https://delay.example.com/v1")!
            guard let match = model.compiled.firstMatch(facts: facts, method: "GET",
                                                        deviceID: nil, appID: nil) else { return nil }
            return OverrideMatching.decide(match, transport: .agentDivert(package: "p"),
                                           capabilities: .desktopTerminated,
                                           masterEnabled: true).0.delay
        }

        XCTAssertEqual(decidedDelay(), .milliseconds(2000))

        rule.delayMillis = 0
        model.save(rule)
        XCTAssertEqual(decidedDelay(), .zero, "an edited delay must not linger from the old snapshot")

        rule.delayMillis = 250
        model.save(rule)
        XCTAssertEqual(decidedDelay(), .milliseconds(250))

        model.remove(rule.id)
    }

    /// A request that matches no rule must never inherit another rule's delay.
    @MainActor
    func test_unmatchedRequestHasNoDelay() {
        let model = OverridesModel()
        let rule = OverrideRule(name: "slow",
                                matcher: OverrideMatcher(pattern: "https://slow.example.com/**"),
                                delayMillis: 5000)
        model.save(rule)

        let facts = OverrideMatching.facts(url: "https://other.example.com/v1")!
        XCTAssertNil(model.compiled.firstMatch(facts: facts, method: "GET", deviceID: nil, appID: nil))

        let (decision, _) = OverrideMatching.decide(nil, transport: .agentDivert(package: "p"),
                                                    capabilities: .desktopTerminated,
                                                    masterEnabled: true)
        XCTAssertEqual(decision.delay, .zero)
        model.remove(rule.id)
    }

    // MARK: - The applied badge

    /// The badge is driven by the `X-Jaca-Override` stamp the agent captures on the way back.
    /// Correlating by id could never work: `OverrideServer` mints its own request id that no
    /// captured row shares.
    func test_overriddenRuleIDIsRecoveredFromTheResponseStamp() {
        let ruleID = UUID()
        let line = """
        {"type":"txn","method":"GET","url":"https://a.com/v1","status":200,
         "responseHeaders":{"X-Jaca-Override":"\(ruleID.uuidString)","Content-Type":"application/json"}}
        """
        XCTAssertEqual(AgentTransactionParser.parse(line)?.overriddenByRuleID, ruleID)
    }

    func test_unstampedResponseHasNoOverrideID() {
        let line = """
        {"type":"txn","method":"GET","url":"https://a.com/v1","status":200,
         "responseHeaders":{"Content-Type":"application/json"}}
        """
        XCTAssertNil(AgentTransactionParser.parse(line)?.overriddenByRuleID)
    }

    /// Jaca's own markers are plumbing, not traffic — they must not appear in the Headers tab
    /// or in a HAR export.
    func test_internalHeadersAreHiddenFromDisplayAndExport() {
        let line = """
        {"type":"txn","method":"GET","url":"https://a.com/v1","status":200,
         "responseHeaders":{"X-Jaca-Override":"x","Content-Type":"application/json"},
         "requestHeaders":{"X-Jaca-Original-URL":"https://a.com/v1","Accept":"*/*"}}
        """
        let txn = AgentTransactionParser.parse(line)!
        XCTAssertFalse(txn.displayResponseHeaders.contains { $0.name.lowercased().hasPrefix("x-jaca-") })
        XCTAssertFalse(txn.displayRequestHeaders.contains { $0.name.lowercased().hasPrefix("x-jaca-") })
        XCTAssertTrue(txn.displayResponseHeaders.contains { $0.name == "Content-Type" })
        XCTAssertTrue(txn.displayRequestHeaders.contains { $0.name == "Accept" })
    }

    // MARK: - The seeded rule must match the request it came from

    /// The whole right-click flow is pointless if the rule it produces doesn't match the very
    /// request it was seeded from — including when that request carried a query string.
    func test_ruleSeededFromARequestMatchesThatRequest() {
        var txn = NetworkTransaction(method: "GET",
                                     url: "https://api.teya.xyz/lending/v1/state?locale=en&x=1",
                                     host: "api.teya.xyz", scheme: "https")
        txn.statusCode = 200

        let pattern = OverrideSeeding.pattern(for: txn)
        XCTAssertEqual(pattern, "https://api.teya.xyz/lending/v1/state")

        let rule = OverrideRule(matcher: OverrideMatcher(pattern: pattern, methods: ["GET"]))
        let set = OverrideCompiler.compile([rule], masterEnabled: true)
        let facts = OverrideMatching.facts(url: txn.url)

        XCTAssertNotNil(facts)
        XCTAssertNotNil(set.firstMatch(facts: facts!, method: "GET", deviceID: nil, appID: nil),
                        "a rule seeded from a request must match that request")
    }

    func test_seededRuleAlsoMatchesTheSamePathWithADifferentQuery() {
        var txn = NetworkTransaction(method: "GET", url: "https://a.com/v1/state?locale=en",
                                     host: "a.com", scheme: "https")
        txn.statusCode = 200
        let rule = OverrideRule(matcher: OverrideMatcher(pattern: OverrideSeeding.pattern(for: txn)))
        let set = OverrideCompiler.compile([rule], masterEnabled: true)

        let other = OverrideMatching.facts(url: "https://a.com/v1/state?locale=fr&extra=9")!
        XCTAssertNotNil(set.firstMatch(facts: other, method: "GET", deviceID: nil, appID: nil))
    }
}
