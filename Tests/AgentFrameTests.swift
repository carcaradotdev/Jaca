import XCTest
@testable import Jaca

/// One agent line, classified. Both controllers switch on `AgentFrame`, so this is the only place
/// the wire format is interpreted — and the hello literals below are copied **verbatim** from the
/// agents, so the test breaks if either side's format drifts.
final class AgentFrameTests: XCTestCase {

    func test_txnLineIsATransaction() {
        let line = #"{"type":"txn","method":"POST","url":"https://id.example.com/oauth/v2/oauth-token","status":200}"#
        guard case .transaction(let txn) = AgentFrame.classify(line) else {
            return XCTFail("expected a transaction, got \(AgentFrame.classify(line))")
        }
        XCTAssertEqual(txn.method, "POST")
        XCTAssertEqual(txn.host, "id.example.com")
    }

    /// Verbatim from `agent/kotlin/com/squeeze/capture/SqueezeReporter.kt`:
    /// `emit("{\"type\":\"hello\",\"pid\":${Process.myPid()},\"stage\":4,\"caps\":[$CAPS]}")`
    /// with `CAPS = "\"override/1\""`.
    func test_androidHelloAdvertisingOverrideSupportIsRecognised() {
        XCTAssertEqual(AgentFrame.classify(#"{"type":"hello","pid":4211,"stage":4,"caps":["override/1"]}"#),
                       .hello(supportsOverride: true))
    }

    /// Verbatim from `agent/iOS/JacaNetChannel.m`:
    /// `NSString *const kJacaHelloFrame = @"{\"type\":\"hello\",\"stage\":1,\"caps\":[\"override/1\"]}";`
    ///
    /// The two agents send *different* hello shapes — the Android one carries a pid and stage 4,
    /// this one has no pid and stage 1 — so recognising one is no evidence the other is understood.
    /// Both literals are pinned here because a silently-unrecognised hello is the exact failure this
    /// feature cannot afford: the desktop would stay quiet, and the app would never arm.
    func test_iosHelloAdvertisingOverrideSupportIsRecognised() {
        XCTAssertEqual(AgentFrame.classify(#"{"type":"hello","stage":1,"caps":["override/1"]}"#),
                       .hello(supportsOverride: true))
    }

    /// An agent built before this feature never reads its socket, so the desktop must stay silent
    /// rather than arming something that can't disarm itself.
    func test_helloWithoutOverrideCapIsNotOverrideCapable() {
        XCTAssertEqual(AgentFrame.classify(#"{"type":"hello","pid":1,"stage":4}"#),
                       .hello(supportsOverride: false))
        XCTAssertEqual(AgentFrame.classify(#"{"type":"hello","caps":["something-else"]}"#),
                       .hello(supportsOverride: false))
        XCTAssertEqual(AgentFrame.classify(#"{"type":"hello","caps":[]}"#),
                       .hello(supportsOverride: false))
    }

    /// Unknown frame types are ignored by design — forward compatibility with a newer agent.
    func test_unknownAndUnparseableLinesAreUnrecognised() {
        XCTAssertEqual(AgentFrame.classify(#"{"type":"future"}"#), .unrecognised(#"{"type":"future"}"#))
        XCTAssertEqual(AgentFrame.classify("not json"), .unrecognised("not json"))
        XCTAssertEqual(AgentFrame.classify(""), .unrecognised(""))
    }
}
