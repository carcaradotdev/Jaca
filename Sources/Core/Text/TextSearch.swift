import Foundation

/// Literal (non-regex) substring search, in UTF-16 offsets so the ranges go straight to an
/// `NSTextView`.
///
/// Literal is deliberate. A response body is full of `.`, `*`, `[` and `\`, and someone searching
/// JSON for `.*` means those two characters, so there is no regex mode and nothing to escape.
/// `.literal` also turns off canonical equivalence: `e` + combining acute does not find a
/// precomposed `é`. A body is bytes, and the editor it searches exists to keep them that way.
enum TextSearch {
    /// A one-character query against a megabyte of JSON has tens of thousands of hits. Nobody steps
    /// through those, and the array is the expensive part rather than the scan. `truncated` is what
    /// turns "2000" into "2000+".
    static let defaultLimit = 2_000

    struct Result: Equatable, Sendable {
        var ranges: [NSRange] = []
        var truncated = false

        static let none = Result()
        var isEmpty: Bool { ranges.isEmpty }
        var count: Int { ranges.count }
    }

    static func matches(in text: String, query: String,
                        caseSensitive: Bool = false,
                        limit: Int = defaultLimit) -> Result {
        guard !query.isEmpty, limit > 0 else { return .none }
        let haystack = text as NSString
        let needleLength = (query as NSString).length
        guard needleLength > 0, haystack.length >= needleLength else { return .none }

        var options: NSString.CompareOptions = [.literal]
        if !caseSensitive { options.insert(.caseInsensitive) }

        var ranges: [NSRange] = []
        var cursor = 0
        while cursor <= haystack.length - needleLength {
            let found = haystack.range(of: query, options: options,
                                       range: NSRange(location: cursor, length: haystack.length - cursor))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            // Past the whole match, so `aa` finds two matches in `aaaa` rather than three. The
            // match's length rather than the query's: a case-insensitive fold can differ.
            cursor = found.location + max(found.length, 1)
            if ranges.count == limit {
                return Result(ranges: ranges,
                              truncated: hasMatch(in: haystack, query: query, options: options,
                                                  from: cursor, needleLength: needleLength))
            }
        }
        return Result(ranges: ranges, truncated: false)
    }

    /// One probe past the cap, only to learn whether the count should read "2000+".
    private static func hasMatch(in haystack: NSString, query: String,
                                 options: NSString.CompareOptions,
                                 from cursor: Int, needleLength: Int) -> Bool {
        guard cursor <= haystack.length - needleLength else { return false }
        return haystack.range(of: query, options: options,
                              range: NSRange(location: cursor, length: haystack.length - cursor))
            .location != NSNotFound
    }

    /// The match to land on after a recompute: the first one at or after `anchor`, so typing another
    /// character walks forward from where you are instead of jumping back to the top. Past the last
    /// match it wraps to the first.
    static func index(in result: Result, atOrAfter anchor: Int) -> Int {
        guard !result.isEmpty else { return 0 }
        return result.ranges.firstIndex { $0.location >= anchor } ?? 0
    }

    /// Wraps in both directions: next from the last match is the first.
    static func step(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// The counter. Callers show it only once there is a query.
    static func label(index: Int, result: Result) -> String {
        guard !result.isEmpty else { return "No matches" }
        return "\(index + 1) of \(result.count)\(result.truncated ? "+" : "")"
    }
}
