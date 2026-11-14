import XCTest
@testable import Jaca

/// A host that rejects Jaca's certificate twice, and never accepted it, is relayed raw.
final class TLSPassthroughPolicyTests: XCTestCase {
    func test_aHostIsPassedThrough_atTheThreshold_once() {
        let policy = TLSPassthroughPolicy()
        XCTAssertTrue(policy.shouldDecrypt("pinned.example"))
        XCTAssertEqual(policy.record(host: "pinned.example", ok: false), .unchanged)
        XCTAssertTrue(policy.shouldDecrypt("pinned.example"))
        XCTAssertEqual(policy.record(host: "pinned.example", ok: false), .passthroughAdded("pinned.example"))
        XCTAssertFalse(policy.shouldDecrypt("pinned.example"))
        XCTAssertEqual(policy.record(host: "pinned.example", ok: false), .unchanged)
        XCTAssertEqual(policy.passthroughHosts, ["pinned.example"])
    }

    func test_theThresholdIsAnInitParameter() {
        let policy = TLSPassthroughPolicy(threshold: 3)
        XCTAssertEqual(policy.record(host: "a.example", ok: false), .unchanged)
        XCTAssertEqual(policy.record(host: "a.example", ok: false), .unchanged)
        XCTAssertEqual(policy.record(host: "a.example", ok: false), .passthroughAdded("a.example"))
    }

    func test_aHostThatSucceededOnce_isNeverPassedThrough() {
        let policy = TLSPassthroughPolicy()
        policy.record(host: "api.example", ok: true)
        XCTAssertEqual(policy.record(host: "api.example", ok: false), .unchanged)
        XCTAssertEqual(policy.record(host: "api.example", ok: false), .unchanged)
        XCTAssertTrue(policy.shouldDecrypt("api.example"))
    }

    func test_aSuccessOnOneHost_resetsNothingForOtherHosts() {
        let policy = TLSPassthroughPolicy()
        policy.record(host: "pinned.example", ok: false)
        policy.record(host: "api.example", ok: true)
        XCTAssertEqual(policy.record(host: "pinned.example", ok: false), .passthroughAdded("pinned.example"))
        XCTAssertFalse(policy.shouldDecrypt("pinned.example"))
        XCTAssertTrue(policy.shouldDecrypt("api.example"))
    }

    func test_anySuccess() {
        let policy = TLSPassthroughPolicy()
        XCTAssertFalse(policy.anySuccess)
        policy.record(host: "a.example", ok: false)
        XCTAssertFalse(policy.anySuccess)
        policy.record(host: "b.example", ok: true)
        XCTAssertTrue(policy.anySuccess)
    }

    func test_hostsCompareWithoutCase() {
        let policy = TLSPassthroughPolicy()
        policy.record(host: "Pinned.Example", ok: false)
        policy.record(host: "pinned.example", ok: false)
        XCTAssertFalse(policy.shouldDecrypt("PINNED.example"))
    }

    /// A host that failed before the CA install is decrypted again after it.
    func test_reset_decryptsAPassedThroughHostAgain() {
        let policy = TLSPassthroughPolicy()
        policy.record(host: "api.example", ok: false)
        policy.record(host: "api.example", ok: false)
        XCTAssertFalse(policy.shouldDecrypt("api.example"))
        policy.reset()
        XCTAssertTrue(policy.shouldDecrypt("api.example"))
        XCTAssertEqual(policy.passthroughHosts, [])
        XCTAssertEqual(policy.record(host: "api.example", ok: false), .unchanged, "the count starts again")
    }
}
