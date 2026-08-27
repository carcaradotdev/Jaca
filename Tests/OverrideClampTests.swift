import XCTest
@testable import Jaca

/// The clamp is the single place degradation is decided, so it is tested exhaustively: every
/// action against every capability set. This is the guarantee that a rule which can't run in one
/// transport behaves — and explains itself — identically in all of them, which is what makes the
/// engine safe to reuse for HTTPS decryption later.
final class OverrideClampTests: XCTestCase {

    private func compiled(_ action: OverrideActionSpec, delayMillis: Int = 0) -> CompiledRule {
        let rule = OverrideRule(name: "R", enabled: true,
                                matcher: OverrideMatcher(pattern: "https://a.com/**"),
                                action: action, delayMillis: delayMillis)
        return OverrideCompiler.compile([rule], masterEnabled: true).rules[0]
    }

    private func decide(_ action: OverrideActionSpec,
                        _ caps: InterceptCapabilities,
                        masterEnabled: Bool = true,
                        delayMillis: Int = 0)
    -> (InterceptDecision, InterceptSkipReason?) {
        OverrideMatching.decide(compiled(action, delayMillis: delayMillis),
                                transport: .mitmProxy,
                                capabilities: caps,
                                masterEnabled: masterEnabled)
    }

    // MARK: - Master switch

    func test_masterOffAlwaysProceeds_regardlessOfCapabilities() {
        for caps: InterceptCapabilities in [[], .observeOnly, .desktopTerminated] {
            let (decision, skip) = decide(.respond(.init()), caps, masterEnabled: false)
            XCTAssertEqual(decision.action, .proceed)
            XCTAssertEqual(skip, .masterOff)
        }
    }

    func test_disabledRuleIsNeverApplied() {
        var rule = OverrideRule(matcher: OverrideMatcher(pattern: "https://a.com/**"))
        rule.enabled = false
        let c = CompiledRule(rule: rule, program: nil, regex: nil)
        let (decision, skip) = OverrideMatching.decide(c, transport: .mitmProxy,
                                                      capabilities: .desktopTerminated,
                                                      masterEnabled: true)
        XCTAssertEqual(decision.action, .proceed)
        XCTAssertEqual(skip, .noRuleMatched)
    }

    func test_noRuleProceeds() {
        let (decision, skip) = OverrideMatching.decide(nil, transport: .mitmProxy,
                                                      capabilities: .desktopTerminated,
                                                      masterEnabled: true)
        XCTAssertEqual(decision.action, .proceed)
        XCTAssertEqual(skip, .noRuleMatched)
    }

    // MARK: - .respond needs .shortCircuit

    func test_respondRunsOnDesktopTerminatedTransports() {
        let (decision, skip) = decide(.respond(OverrideResponseSpec(statusCode: 418)), .desktopTerminated)
        XCTAssertNil(skip)
        guard case .respond(let response) = decision.action else { return XCTFail("expected .respond") }
        XCTAssertEqual(response.statusCode, 418)
        XCTAssertNotNil(decision.ruleID)
    }

    func test_respondIsBlockedWithoutShortCircuit() {
        let (decision, skip) = decide(.respond(.init()), .observeOnly)
        XCTAssertEqual(decision.action, .proceed)
        guard case .transportUnsupported(_, let missing)? = skip else {
            return XCTFail("expected .transportUnsupported, got \(String(describing: skip))")
        }
        XCTAssertTrue(missing.contains(.shortCircuit))
    }

    // MARK: - .editResponse needs .editResponse + .bodies

    func test_editRunsOnDesktopTerminatedTransports() {
        let (decision, skip) = decide(.editResponse(ResponseEdit(statusCode: 500)), .desktopTerminated)
        XCTAssertNil(skip)
        guard case .edit(let edit) = decision.action else { return XCTFail("expected .edit") }
        XCTAssertEqual(edit.statusCode, 500)
    }

    /// A transport that can rewrite but never sees bodies must refuse, and say why — this is the
    /// exact message the row gutter and the editor render.
    func test_editIsBlockedWhenBodiesAreUnavailable() {
        let (decision, skip) = decide(.editResponse(.init()), [.editResponse, .shortCircuit, .delay])
        XCTAssertEqual(decision.action, .proceed)
        guard case .transportUnsupported(_, let missing)? = skip else {
            return XCTFail("expected .transportUnsupported")
        }
        XCTAssertEqual(missing, [.bodies])
        XCTAssertTrue(skip!.message.contains("response bodies"))
    }

    // MARK: - .mapRemote is modelled but never executable yet

    func test_mapRemoteIsBlockedEverywhere() {
        for caps: InterceptCapabilities in [[], .observeOnly, .desktopTerminated] {
            let (decision, skip) = decide(.mapRemote(url: "https://b.com"), caps)
            XCTAssertEqual(decision.action, .proceed)
            guard case .transportUnsupported(_, let missing)? = skip else {
                return XCTFail("expected .transportUnsupported")
            }
            XCTAssertTrue(missing.contains(.mapRemote))
        }
    }

    // MARK: - Delay is clamped to .delay

    func test_delayIsAppliedWhenSupported() {
        let (decision, _) = decide(.respond(.init()), .desktopTerminated, delayMillis: 250)
        XCTAssertEqual(decision.delay, .milliseconds(250))
    }

    func test_delayIsDroppedWhenUnsupported() {
        let (decision, _) = decide(.respond(.init()), [.shortCircuit], delayMillis: 250)
        XCTAssertEqual(decision.delay, .zero)
    }

    func test_negativeDelayIsClampedToZero() {
        let (decision, _) = decide(.respond(.init()), .desktopTerminated, delayMillis: -5)
        XCTAssertEqual(decision.delay, .zero)
    }

    // MARK: - Every skip reason renders a message

    func test_everySkipReasonHasNonEmptyMessage() {
        let reasons: [InterceptSkipReason] = [
            .masterOff,
            .transportUnsupported(transport: .agentDivert(package: "p"), missing: [.bodies]),
            .transportUnsupported(transport: .companionMetadata, missing: [.shortCircuit]),
            .transportNotArmed("adb reverse failed"),
            .noRuleMatched,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty, "\(reason) rendered an empty message")
        }
    }
}
