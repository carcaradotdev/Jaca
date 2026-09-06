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
            .transportUnsupported(transport: .iosSimulatorDivert(bundleID: "b"), missing: [.bodies]),
            .transportUnsupported(transport: .mitmProxy, missing: [.mapRemote]),
            .transportUnsupported(transport: .companionMetadata, missing: [.shortCircuit]),
            .transportNotArmed("adb reverse failed"),
            .noRuleMatched,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty, "\(reason) rendered an empty message")
        }
    }

    // MARK: - The declared capability and the clamped one are the same value

    /// The clamp is only honest if the capability the toolbar shows is the capability the pipeline
    /// applies. `AgentCaptureSource.nativeCapabilities` is that single constant: the source reads
    /// it to answer the UI, and hands the *same* constant to `AgentController`, which passes it to
    /// `DivertCoordinator` and on into `OverrideServer`. `capabilities:` has no default anywhere
    /// along that chain, so there is no second value for the two to drift apart into.
    @MainActor
    func test_declaredCapabilitiesAreTheOnesHandedToOverrideServer() {
        let wired = AgentCaptureSource(adbURL: URL(fileURLWithPath: "/nonexistent/adb"),
                                       serial: "s", package: "p", intercept: Self.stubServices())
        XCTAssertEqual(wired.interceptCapabilities, AgentCaptureSource.nativeCapabilities)
        XCTAssertEqual(AgentCaptureSource.nativeCapabilities, .desktopTerminated)

        // The iOS Simulator runs the same chain — source constant → controller → coordinator →
        // OverrideServer — so it gets the same guarantee, not a hard-coded capability of its own.
        let wiredIOS = IOSSimulatorAgentCaptureSource(device: Self.simulator, bundleID: "com.example.App",
                                                      intercept: Self.stubServices())
        XCTAssertEqual(wiredIOS.interceptCapabilities, IOSSimulatorAgentCaptureSource.nativeCapabilities)
        XCTAssertEqual(IOSSimulatorAgentCaptureSource.nativeCapabilities, .desktopTerminated)
    }

    /// An unwired source declares nothing, so the UI can never offer an override the runtime has
    /// no path to honour.
    @MainActor
    func test_anUnwiredSourceDeclaresNoCapabilities() {
        let unwired = AgentCaptureSource(adbURL: URL(fileURLWithPath: "/nonexistent/adb"),
                                         serial: "s", package: "p")
        XCTAssertEqual(unwired.interceptCapabilities, [])

        let unwiredIOS = IOSSimulatorAgentCaptureSource(device: Self.simulator, bundleID: "com.example.App")
        XCTAssertEqual(unwiredIOS.interceptCapabilities, [])
        XCTAssertNil(unwiredIOS.arming)
    }

    private static let simulator = Device(id: "UDID", platform: .iosSimulator,
                                          model: "iPhone 16", state: .connected)

    // MARK: - Redirect policy per transport

    /// A diverted app must have redirects followed on the Mac, or it leaves the tunnel chasing a
    /// 3xx; the MITM proxy must not, because the client re-requests each hop through us and
    /// following here would hide hops from capture.
    func test_divertTransportsFollowRedirectsAndTheProxyDoesNot() {
        XCTAssertEqual(InterceptServices.redirectPolicy(for: .agentDivert(package: "p")),
                       .follow(max: 5))
        XCTAssertEqual(InterceptServices.redirectPolicy(for: .iosSimulatorDivert(bundleID: "b")),
                       .follow(max: 5))
        XCTAssertEqual(InterceptServices.redirectPolicy(for: .mitmProxy), .doNotFollow)
        XCTAssertEqual(InterceptServices.redirectPolicy(for: .companionMetadata), .doNotFollow)
    }

    /// 307/308 are the two redirects defined to preserve the method **and** the body. Following
    /// one as a bodiless GET turns a diverted POST into whatever the origin answers a GET with —
    /// usually a 404/405, handed back to the app as if it were its own response.
    func test_307And308PreserveTheMethodAndBody() {
        XCTAssertFalse(OriginClient.downgradesToGET(status: 307, method: "POST"))
        XCTAssertFalse(OriginClient.downgradesToGET(status: 308, method: "POST"))
        XCTAssertFalse(OriginClient.downgradesToGET(status: 308, method: "PUT"))
    }

    /// The historical downgrades, kept because that is what `URLSession` does.
    func test_303AlwaysDowngradesAnd301And302DowngradeOnlyNonGET() {
        XCTAssertTrue(OriginClient.downgradesToGET(status: 303, method: "POST"))
        XCTAssertTrue(OriginClient.downgradesToGET(status: 303, method: "GET"))
        XCTAssertTrue(OriginClient.downgradesToGET(status: 301, method: "POST"))
        XCTAssertTrue(OriginClient.downgradesToGET(status: 302, method: "POST"))
        XCTAssertFalse(OriginClient.downgradesToGET(status: 301, method: "GET"))
        XCTAssertFalse(OriginClient.downgradesToGET(status: 302, method: "HEAD"))
    }

    /// Enough of an `InterceptServices` to make a source count as wired. Nothing here is called.
    private static func stubServices() -> InterceptServices {
        struct NoResolver: InterceptResolving {
            func resolve(_ request: InterceptedRequest, capabilities: InterceptCapabilities)
            -> (InterceptDecision, InterceptSkipReason?) { (.proceed, .noRuleMatched) }
        }
        struct NoReporter: InterceptReporting {
            func report(requestID: UUID, appliedRuleID: UUID?, skipped: InterceptSkipReason?) {}
        }
        return InterceptServices(resolver: NoResolver(), reporter: NoReporter(),
                                 onArmingChange: { _, _, _ in }, onRegisterCoordinator: { _, _ in },
                                 onDeregisterCoordinator: { _, _ in })
    }
}
