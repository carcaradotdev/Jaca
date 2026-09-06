import XCTest
@testable import Jaca

/// The one desktop→device frame producer.
///
/// `OverrideEndpoint` is the entire vocabulary the device is ever given, and `divertFrame` is the
/// only place in the product that encodes it. These tests are the enforcement: if the frame ever
/// grows a key, or "disarm" ever acquires a second spelling, they fail here rather than on a
/// device six weeks later.
final class OverrideEndpointFrameTests: XCTestCase {

    private func object(_ frame: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
    }

    // MARK: - The vocabulary

    /// If this test ever needs changing to add a *rule* concept, the agent has stopped being dumb.
    func test_divertFrameCarriesOnlyOriginHostsAndHeartbeat() throws {
        let frame = OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://localhost:41234", hosts: ["b.com", "a.com"],
                             heartbeatSeconds: 15))
        let obj = try object(frame)

        XCTAssertEqual(Set(obj.keys), ["type", "origin", "hosts", "heartbeatSeconds"],
                       "the device must never learn about patterns, payloads, statuses or ordering")
        XCTAssertEqual(obj["type"] as? String, "divert")
        XCTAssertEqual(obj["origin"] as? String, "http://localhost:41234")
        XCTAssertEqual(obj["heartbeatSeconds"] as? Int, 15)
        // Sorted, so an unchanged rule set produces an identical frame.
        XCTAssertEqual(obj["hosts"] as? [String], ["a.com", "b.com"])
    }

    // MARK: - Disarm has exactly one spelling

    func test_disarmedSendsNullOriginAndNoHosts() throws {
        let endpoint = OverrideEndpoint.disarmed(heartbeatSeconds: 15)
        XCTAssertFalse(endpoint.isArmed)
        XCTAssertEqual(endpoint.hosts, [])

        let frame = OverrideEndpoint.divertFrame(endpoint)
        // The device reads `origin` as a JSON null, and the literal shape is what its parser sees.
        XCTAssertTrue(frame.contains("\"origin\":null"), frame)
        XCTAssertTrue(frame.contains("\"hosts\":[]"), frame)
        let obj = try object(frame)
        XCTAssertTrue(obj["origin"] is NSNull)
        XCTAssertEqual(obj["hosts"] as? [String], [])
    }

    /// An empty host set can never mean "divert everything" — the init clears both fields
    /// together, so there is no way to construct a half-armed endpoint.
    func test_emptyHostSetClearsTheOrigin() {
        let endpoint = OverrideEndpoint(origin: "http://localhost:41234", hosts: [])
        XCTAssertNil(endpoint.origin)
        XCTAssertEqual(endpoint.hosts, [])
        XCTAssertFalse(endpoint.isArmed)
    }

    /// …and the mirror: an absent origin can't leave a stale host list armed on the device.
    func test_missingOriginClearsTheHosts() {
        XCTAssertEqual(OverrideEndpoint(origin: nil, hosts: ["a.com"]).hosts, [])
        XCTAssertEqual(OverrideEndpoint(origin: "", hosts: ["a.com"]).hosts, [])
    }

    // MARK: - Safe to re-send every heartbeat

    /// Re-sending the identical endpoint must be safe — it runs every few seconds, and the
    /// heartbeat is also the repair path, so it has to be byte-stable.
    func test_repeatedEndpointFramesAreIdentical() {
        let a = OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://localhost:1", hosts: ["b.com", "a.com"]))
        let b = OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://localhost:1", hosts: ["a.com", "b.com"]))
        XCTAssertEqual(a, b, "hosts are sorted, so an unchanged rule set produces a byte-identical frame")
    }

    /// The heartbeat sends the *full* endpoint, not a bare ping: a ping can refresh the device's
    /// dead-man timer but can never re-arm a device that already disarmed itself.
    func test_heartbeatFrameCarriesTheFullEndpointSoItCanReArm() throws {
        let obj = try object(OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://localhost:41234", hosts: ["a.com"])))
        XCTAssertEqual(obj["type"] as? String, "divert",
                       "a bare ping can refresh the timer but can never re-arm a disarmed device")
        XCTAssertEqual(obj["origin"] as? String, "http://localhost:41234")
        XCTAssertEqual(obj["hosts"] as? [String], ["a.com"])
    }

    // MARK: - Hosts come from user-authored rules

    func test_hostWithAQuoteIsEscapedAndStillParses() throws {
        let frame = OverrideEndpoint.divertFrame(
            OverrideEndpoint(origin: "http://localhost:1", hosts: ["ev\"il.com"]))
        let obj = try object(frame)      // an unescaped quote would make this unparseable
        XCTAssertEqual(obj["hosts"] as? [String], ["ev\"il.com"])
    }
}
