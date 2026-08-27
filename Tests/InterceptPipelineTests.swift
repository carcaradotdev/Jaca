import XCTest
@testable import Jaca

/// Exercises the shared pipeline with stub collaborators, so short-circuit / edit / passthrough
/// semantics are proven **without a device, a proxy, a socket, or the internet**.
final class InterceptPipelineTests: XCTestCase {

    // MARK: - Stubs

    private final class StubOrigin: OriginRequesting, @unchecked Sendable {
        let lock = NSLock()
        private(set) var callCount = 0
        var response: InterceptedResponse

        init(response: InterceptedResponse) { self.response = response }

        func perform(_ request: InterceptedRequest) async -> InterceptedResponse {
            lock.lock(); callCount += 1; lock.unlock()
            return response
        }
    }

    private struct StubResolver: InterceptResolving {
        var decision: InterceptDecision
        var skip: InterceptSkipReason?
        func resolve(_ request: InterceptedRequest,
                     capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?) {
            (decision, skip)
        }
    }

    private final class StubReporter: InterceptReporting, @unchecked Sendable {
        let lock = NSLock()
        private(set) var applied: [UUID?] = []
        private(set) var skips: [InterceptSkipReason?] = []
        func report(requestID: UUID, appliedRuleID: UUID?, skipped: InterceptSkipReason?) {
            lock.lock(); applied.append(appliedRuleID); skips.append(skipped); lock.unlock()
        }
    }

    private func request() -> InterceptedRequest {
        InterceptedRequest(method: "GET", url: "https://api.example.com/v1/state",
                           headers: [HeaderPair(name: "Accept", value: "application/json")],
                           transport: .mitmProxy)
    }

    private let originResponse = InterceptedResponse(
        statusCode: 200,
        headers: [HeaderPair(name: "Content-Type", value: "application/json")],
        body: Data("{\"real\":true}".utf8)
    )

    // MARK: - .respond never touches the origin

    func test_respondShortCircuits_andNeverCallsTheOrigin() async {
        let origin = StubOrigin(response: originResponse)
        let ruleID = UUID()
        let canned = InterceptedResponse(statusCode: 418,
                                         headers: [HeaderPair(name: "Content-Type", value: "text/plain")],
                                         body: Data("mocked".utf8))
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(action: .respond(canned), ruleID: ruleID)),
            origin: origin)

        let result = await pipeline.run(request(), capabilities: .desktopTerminated)

        XCTAssertEqual(origin.callCount, 0, "a short-circuit must never reach the network")
        XCTAssertEqual(result.response.statusCode, 418)
        XCTAssertEqual(result.response.body, Data("mocked".utf8))
        XCTAssertEqual(result.appliedRuleID, ruleID)
    }

    /// A synthesized response never hit the wire, so it must report no time-to-first-byte —
    /// the UI shows that honestly rather than inventing a duration.
    func test_synthesizedResponseHasNoResponseStart() async {
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(
                action: .respond(InterceptedResponse(statusCode: 200)), ruleID: UUID())),
            origin: StubOrigin(response: originResponse))
        let result = await pipeline.run(request(), capabilities: .desktopTerminated)
        XCTAssertNil(result.response.responseStart)
        XCTAssertNotNil(result.response.responseEnd)
    }

    // MARK: - .edit calls the origin exactly once

    func test_editFetchesOnceAndAppliesTheEdit() async {
        let origin = StubOrigin(response: originResponse)
        let ruleID = UUID()
        let edit = ResponseEdit(statusCode: 503, headerMode: .merge,
                                headers: [HeaderPair(name: "X-Added", value: "yes")],
                                body: .inline("{\"mocked\":true}"))
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(action: .edit(edit), ruleID: ruleID)),
            origin: origin)

        let result = await pipeline.run(request(), capabilities: .desktopTerminated)

        XCTAssertEqual(origin.callCount, 1)
        XCTAssertEqual(result.response.statusCode, 503)
        XCTAssertEqual(result.response.body, Data("{\"mocked\":true}".utf8))
        XCTAssertTrue(result.response.headers.contains { $0.name == "X-Added" })
        XCTAssertTrue(result.response.headers.contains { $0.name == "Content-Type" },
                      "merge keeps the origin's headers")
        XCTAssertEqual(result.appliedRuleID, ruleID)
    }

    // MARK: - .proceed is byte-identical

    func test_proceedIsPassthrough_andCarriesNoOverrideStamp() async {
        let origin = StubOrigin(response: originResponse)
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: .proceed, skip: .noRuleMatched), origin: origin)

        let result = await pipeline.run(request(), capabilities: .desktopTerminated)

        XCTAssertEqual(origin.callCount, 1)
        XCTAssertEqual(result.response, originResponse)
        XCTAssertNil(result.appliedRuleID)
        XCTAssertEqual(result.skipped, .noRuleMatched)
        XCTAssertFalse(result.response.headers.contains { $0.name == OverrideHeaders.override })
    }

    /// The default pipeline must be behaviour-preserving, so wiring it into an existing transport
    /// changes nothing until a resolver is supplied.
    func test_passthroughPipelineWithNoResolverProceeds() async {
        let origin = StubOrigin(response: originResponse)
        var pipeline = InterceptPipeline.passthrough
        pipeline.origin = origin
        let result = await pipeline.run(request(), capabilities: .desktopTerminated)
        XCTAssertEqual(result.response, originResponse)
        XCTAssertNil(result.appliedRuleID)
    }

    // MARK: - Stamping

    func test_overrideHeaderIsStampedOnlyWhenARuleApplied() async {
        let ruleID = UUID()
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(
                action: .respond(InterceptedResponse(statusCode: 200)), ruleID: ruleID)),
            origin: StubOrigin(response: originResponse))

        let result = await pipeline.run(request(), capabilities: .desktopTerminated)
        let stamp = result.response.headers.first { $0.name == OverrideHeaders.override }
        XCTAssertEqual(stamp?.value, ruleID.uuidString)
    }

    // MARK: - Delay

    func test_delayIsHonouredWhenCapable() async {
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(
                action: .respond(InterceptedResponse(statusCode: 200)),
                delay: .milliseconds(120), ruleID: UUID())),
            origin: StubOrigin(response: originResponse))

        let start = ContinuousClock.now
        _ = await pipeline.run(request(), capabilities: .desktopTerminated)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(100))
    }

    func test_delayIsSkippedWhenTransportCannotDelay() async {
        let pipeline = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(
                action: .respond(InterceptedResponse(statusCode: 200)),
                delay: .milliseconds(800), ruleID: UUID())),
            origin: StubOrigin(response: originResponse))

        let start = ContinuousClock.now
        _ = await pipeline.run(request(), capabilities: [.shortCircuit])
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(400))
    }

    // MARK: - Reporting

    func test_reporterSeesAppliedRuleAndSkipReason() async {
        let reporter = StubReporter()
        let ruleID = UUID()

        let applying = InterceptPipeline(
            resolver: StubResolver(decision: InterceptDecision(
                action: .respond(InterceptedResponse(statusCode: 200)), ruleID: ruleID)),
            origin: StubOrigin(response: originResponse), reporter: reporter)
        _ = await applying.run(request(), capabilities: .desktopTerminated)

        let skipping = InterceptPipeline(
            resolver: StubResolver(decision: .proceed, skip: .masterOff),
            origin: StubOrigin(response: originResponse), reporter: reporter)
        _ = await skipping.run(request(), capabilities: .desktopTerminated)

        XCTAssertEqual(reporter.applied, [ruleID, nil])
        XCTAssertEqual(reporter.skips, [nil, .masterOff])
    }
}
