import XCTest
@testable import Jaca

/// The network list used to recompute everything it shows from the whole capture on every
/// arriving row: `filtered` scanned all transactions (twice per `body` pass), the timeline
/// derived its domain with three more full passes, and it filled one rounded rect per
/// transaction. That cost grows with the session, which is why a long capture — not a busy one —
/// is what pegged the CPU.
///
/// These pin the replacements: the cached/extended filter must agree with the naive one, the
/// span must be maintained as rows land, and the timeline's bucketing must not hide a failure
/// behind a success that landed on the same pixel.
@MainActor
final class NetworkListPerformanceTests: XCTestCase {

    private func makeSession() -> NetworkSession {
        let device = Device(id: "sim-1", platform: .iosSimulator, model: "iPhone 16", state: .connected)
        return NetworkSession(device: device, ca: try! CertificateAuthority(), adbURL: nil)
    }

    private func txn(_ url: String, method: String = "GET", status: Int? = 200,
                     start: Date = Date(), duration: TimeInterval = 0.1,
                     error: String? = nil) -> NetworkTransaction {
        var t = NetworkTransaction(method: method, url: url,
                                   host: URLComponents(string: url)?.host ?? "",
                                   scheme: "https", requestHeaders: [], requestBody: nil,
                                   startedAt: start)
        t.statusCode = status
        t.finishedAt = start.addingTimeInterval(duration)
        t.error = error
        return t
    }

    /// The naive predicate the cache replaced, kept here as the oracle.
    private func naive(_ all: [NetworkTransaction], _ query: String,
                       _ range: ClosedRange<Date>?) -> [NetworkTransaction] {
        all.filter { NetworkSession.matches($0, query: query, range: range) }
    }

    // MARK: - filtered

    func test_filtered_extendingTheCacheAgreesWithAFullPass() {
        let session = makeSession()
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<50 {
            session.upsert(txn("https://api.example.com/v1/item/\(i)", start: base.addingTimeInterval(Double(i))))
            _ = session.filtered   // force the cache to exist at every length
        }
        session.filterText = "item/1"
        let firstPass = session.filtered
        // Appending must extend, not invalidate — and still match a from-scratch filter.
        session.upsert(txn("https://api.example.com/v1/item/100", start: base.addingTimeInterval(100)))
        session.upsert(txn("https://api.example.com/v1/other", start: base.addingTimeInterval(101)))
        XCTAssertEqual(session.filtered.map(\.url), naive(session.transactions, "item/1", nil).map(\.url))
        XCTAssertGreaterThan(session.filtered.count, firstPass.count)
    }

    func test_filtered_changingTheQueryRebuildsRatherThanExtends() {
        let session = makeSession()
        session.upsert(txn("https://a.example.com/one"))
        session.upsert(txn("https://b.example.com/two"))
        session.filterText = "a.example"
        XCTAssertEqual(session.filtered.count, 1)
        session.filterText = "b.example"
        XCTAssertEqual(session.filtered.map(\.url), ["https://b.example.com/two"])
        session.filterText = ""
        XCTAssertEqual(session.filtered.count, 2)
    }

    /// A row rewritten in place changes what the filter should say about it, so it must not be
    /// served from a cache built before the rewrite.
    func test_filtered_rowRewrittenInPlaceInvalidatesTheCache() {
        let session = makeSession()
        var row = txn("https://a.example.com/one", status: nil)
        session.upsert(row)
        session.filterText = "POST"
        XCTAssertEqual(session.filtered.count, 0)
        row.method = "POST"
        session.upsert(row)                       // same id → in-place rewrite
        XCTAssertEqual(session.filtered.count, 1)
    }

    func test_filtered_timeRangeSelectionIsHonoured() {
        let session = makeSession()
        let base = Date(timeIntervalSince1970: 2_000)
        for i in 0..<10 { session.upsert(txn("https://a.example.com/\(i)", start: base.addingTimeInterval(Double(i)))) }
        _ = session.filtered
        session.selectedTimeRange = base.addingTimeInterval(3)...base.addingTimeInterval(5)
        XCTAssertEqual(session.filtered.map(\.url),
                       naive(session.transactions, "", session.selectedTimeRange).map(\.url))
        XCTAssertFalse(session.filtered.isEmpty)
    }

    func test_clear_resetsTheCacheAndTheSpan() {
        let session = makeSession()
        session.upsert(txn("https://a.example.com/one"))
        _ = session.filtered
        session.clear()
        XCTAssertTrue(session.filtered.isEmpty)
        XCTAssertNil(session.timeSpan)
    }

    // MARK: - span

    func test_timeSpan_isMaintainedAsRowsLand() {
        let session = makeSession()
        let base = Date(timeIntervalSince1970: 3_000)
        session.upsert(txn("https://a.example.com/mid", start: base.addingTimeInterval(10), duration: 1))
        session.upsert(txn("https://a.example.com/early", start: base, duration: 0.5))
        session.upsert(txn("https://a.example.com/late", start: base.addingTimeInterval(20), duration: 5))
        let span = try? XCTUnwrap(session.timeSpan)
        XCTAssertEqual(span?.lowerBound, base)
        XCTAssertEqual(span?.upperBound, base.addingTimeInterval(25))
    }

    /// A single row must still produce a non-degenerate domain, or the timeline divides by zero.
    func test_timeSpan_isAtLeastOneSecondWide() {
        let session = makeSession()
        let base = Date(timeIntervalSince1970: 4_000)
        session.upsert(txn("https://a.example.com/x", start: base, duration: 0))
        XCTAssertEqual(session.timeSpan?.upperBound.timeIntervalSince(base), 1)
    }

    // MARK: - timeline bucketing

    func test_severity_ordersWorstLastSoBucketingKeepsFailures() {
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: 204)), 1)
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: 302)), 2)
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: 404)), 3)
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: 500)), 4)
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: nil)), 0)
        // An error outranks whatever status came with it.
        XCTAssertEqual(NetworkTimelineView.severity(txn("https://a/x", status: 200, error: "timeout")), 4)
    }

    func test_severity_aFailureBeatsASuccessInTheSameBucket() {
        let ok = NetworkTimelineView.severity(txn("https://a/x", status: 200))
        let bad = NetworkTimelineView.severity(txn("https://a/x", status: 503))
        XCTAssertGreaterThan(bad, ok)
    }
}
