import XCTest
@testable import Jaca

/// Find-in-body. Ranges are UTF-16 because they go straight to an `NSTextView`, and the search is
/// literal because a JSON body is full of regex metacharacters someone will type meaning themselves.
final class TextSearchTests: XCTestCase {

    // MARK: - matches

    func test_emptyInputsFindNothing() {
        XCTAssertEqual(TextSearch.matches(in: "abc", query: ""), .none)
        XCTAssertEqual(TextSearch.matches(in: "", query: "a"), .none)
        XCTAssertEqual(TextSearch.matches(in: "ab", query: "abc"), .none)
    }

    func test_findsASingleMatchAtItsOffset() {
        let result = TextSearch.matches(in: #"{"name":"bob"}"#, query: "bob")
        XCTAssertEqual(result.ranges, [NSRange(location: 9, length: 3)])
    }

    func test_matchesDoNotOverlap() {
        XCTAssertEqual(TextSearch.matches(in: "aaaa", query: "aa").ranges,
                       [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    func test_caseInsensitiveByDefault() {
        XCTAssertEqual(TextSearch.matches(in: "Bob bob", query: "bob").count, 2)
        XCTAssertEqual(TextSearch.matches(in: "Bob bob", query: "bob", caseSensitive: true).count, 1)
    }

    func test_regexMetacharactersAreLiteral() {
        let body = #"{"re":".*","n":1}"#
        XCTAssertEqual(TextSearch.matches(in: body, query: ".*").count, 1)
        XCTAssertEqual(TextSearch.matches(in: body, query: "[a-z]").count, 0)
    }

    /// A decision, pinned: `.literal` turns off canonical equivalence, because a body is bytes.
    func test_decomposedAndPrecomposedAreDifferent() {
        XCTAssertEqual(TextSearch.matches(in: "caf\u{E9}", query: "e\u{301}").count, 0)
    }

    /// An emoji is two UTF-16 units. `String.Index` arithmetic would put this at 2.
    func test_offsetsAreUTF16() {
        XCTAssertEqual(TextSearch.matches(in: "🎉 token", query: "token").ranges.first?.location, 3)
    }

    func test_queryCanSpanLines() {
        XCTAssertEqual(TextSearch.matches(in: "{\n  \"a\"", query: "{\n").count, 1)
    }

    func test_capTruncatesAndSaysSo() {
        let ten = String(repeating: "x,", count: 10)
        let capped = TextSearch.matches(in: ten, query: "x", limit: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertTrue(capped.truncated)
    }

    /// Exactly at the cap with nothing beyond must not read "3+".
    func test_capWithNothingBeyondIsNotTruncated() {
        let exact = TextSearch.matches(in: "x,x,x", query: "x", limit: 3)
        XCTAssertEqual(exact.count, 3)
        XCTAssertFalse(exact.truncated)
    }

    func test_largeBodyIsCappedRatherThanEnumerated() {
        let big = String(repeating: "{\"k\":1}", count: 150_000)   // ~1 MB
        let result = TextSearch.matches(in: big, query: "k")
        XCTAssertEqual(result.count, TextSearch.defaultLimit)
        XCTAssertTrue(result.truncated)
    }

    // MARK: - index / step

    func test_indexLandsOnTheFirstMatchAtOrAfterTheAnchor() {
        let result = TextSearch.Result(ranges: [NSRange(location: 2, length: 1),
                                                NSRange(location: 8, length: 1)])
        XCTAssertEqual(TextSearch.index(in: result, atOrAfter: 0), 0)
        XCTAssertEqual(TextSearch.index(in: result, atOrAfter: 2), 0)
        XCTAssertEqual(TextSearch.index(in: result, atOrAfter: 5), 1)
        XCTAssertEqual(TextSearch.index(in: result, atOrAfter: 20), 0, "past the last match wraps")
        XCTAssertEqual(TextSearch.index(in: .none, atOrAfter: 5), 0)
    }

    func test_stepWrapsBothWays() {
        XCTAssertEqual(TextSearch.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(TextSearch.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(TextSearch.step(from: 1, by: 7, count: 3), 2)
        XCTAssertEqual(TextSearch.step(from: 0, by: 1, count: 0), 0, "no modulo by zero")
    }

    // MARK: - label

    func test_label() {
        let seventeen = TextSearch.Result(ranges: Array(repeating: NSRange(location: 0, length: 1), count: 17))
        XCTAssertEqual(TextSearch.label(index: 2, result: seventeen), "3 of 17")
        var truncated = seventeen
        truncated.truncated = true
        XCTAssertEqual(TextSearch.label(index: 2, result: truncated), "3 of 17+")
        XCTAssertEqual(TextSearch.label(index: 0, result: .none), "No matches")
    }
}
