import Foundation

/// The parsed shape of a URL, computed once per request and reused for every rule. Parsed here
/// rather than via `NetworkTransaction.path`, which returns the whole URL when there's no path —
/// fine for display, wrong for matching.
struct URLFacts: Sendable, Hashable {
    var scheme: String        // lowercased; "" when the URL omitted one
    var host: String          // lowercased
    var port: Int?            // nil unless explicitly present
    var path: String          // case-sensitive, always starts with "/"
    var query: [String: [String]]
    /// `scheme://host[:port]path` — what a pattern is anchored against (no query, no fragment).
    var normalized: String
}

/// A rule with its pattern pre-compiled, so matching N requests doesn't recompile the glob N times.
struct CompiledRule: Sendable {
    var rule: OverrideRule
    var program: GlobProgram?
    var regex: NSRegularExpression?

    var id: UUID { rule.id }
}

/// A compiled glob: the pattern split into literal and wildcard segments.
struct GlobProgram: Sendable, Hashable {
    enum Token: Sendable, Hashable {
        case literal(String)
        /// `*` — any characters except `/`
        case star
        /// `**` — any characters including `/`
        case globstar
    }
    var tokens: [Token]
    /// Whether the pattern named a port, decided at compile time from the host portion — a
    /// token scan for ":" misfires on any pattern with a colon in the *path*.
    var namesPort: Bool = false
    /// Requirements parsed out of the pattern's own query string, if it had one.
    var requiredQuery: [String: String]
    /// The literal host the pattern names, if any — used to derive the divert host set.
    var literalHost: String?
}

enum GlobError: Error, Equatable {
    case empty
    case invalidRegex(String)
}

/// All the pure logic behind response overrides: URL parsing, glob compilation and matching, the
/// capability clamp, and pattern generalization.
enum OverrideMatching {

    // MARK: - URL parsing

    /// Parses a URL into `URLFacts`, or nil when it isn't HTTP(S) — including the companion's
    /// `"host:port"` flow-metadata rows, which carry no HTTP semantics and must never match.
    static func facts(url: String) -> URLFacts? {
        guard !url.isEmpty else { return nil }
        guard let comps = URLComponents(string: url), let host = comps.host, !host.isEmpty else {
            return nil
        }
        let scheme = (comps.scheme ?? "").lowercased()
        guard scheme.isEmpty || scheme == "http" || scheme == "https" else { return nil }

        var query: [String: [String]] = [:]
        for item in comps.queryItems ?? [] {
            query[item.name, default: []].append(item.value ?? "")
        }
        // `comps.path` is percent-DECODED. Patterns are compared decoded too (see compileGlob),
        // so a pattern pasted from an encoded URL still matches.
        let path = comps.path.isEmpty ? "/" : comps.path
        let lowerHost = host.lowercased()
        var normalized = scheme.isEmpty ? "" : "\(scheme)://"
        normalized += lowerHost
        if let port = comps.port { normalized += ":\(port)" }
        normalized += path

        return URLFacts(scheme: scheme, host: lowerHost, port: comps.port,
                        path: path, query: query, normalized: normalized)
    }

    // MARK: - Glob compilation

    /// Compiles a glob pattern.
    ///
    /// Semantics (frozen — these are the test table):
    /// - `*` matches any run of characters **except** `/` (one path segment)
    /// - `**` matches any characters **including** `/`
    /// - the pattern must match the **whole** URL (anchored)
    /// - an omitted scheme matches either; a port is compared only if the pattern names one
    /// - scheme and host are case-insensitive; path and query are case-sensitive
    /// - the query is **ignored** unless the pattern contains `?`, in which case every `k=v` in
    ///   the pattern must be present (values may use `*`), extra request params are allowed, and
    ///   order is irrelevant
    static func compileGlob(_ pattern: String) -> Result<GlobProgram, GlobError> {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        // Split off the pattern's own query requirements.
        var head = trimmed
        var requiredQuery: [String: String] = [:]
        if let qIndex = trimmed.firstIndex(of: "?") {
            head = String(trimmed[trimmed.startIndex..<qIndex])
            let qs = String(trimmed[trimmed.index(after: qIndex)...])
            for pair in qs.split(separator: "&") {
                let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(bits.first ?? "")
                guard !key.isEmpty else { continue }
                requiredQuery[key] = bits.count > 1 ? String(bits[1]) : ""
            }
        }
        // A fragment is never sent, so it can never be matched.
        if let hash = head.firstIndex(of: "#") { head = String(head[head.startIndex..<hash]) }

        // Normalize the scheme so "api.x.com/**" behaves as "*://api.x.com/**".
        var body = head
        var schemePrefix = ""
        if let range = body.range(of: "://") {
            schemePrefix = String(body[body.startIndex..<range.lowerBound]).lowercased()
            body = String(body[range.upperBound...])
        }

        var tokens: [GlobProgram.Token] = []
        if schemePrefix.isEmpty || schemePrefix == "*" {
            tokens.append(.globstar)          // any scheme (or none)
            tokens.append(.literal("://"))
        } else {
            tokens.append(.literal("\(schemePrefix)://"))
        }
        // Decode the pattern's path the same way `facts` decodes the URL's, so a pattern pasted
        // from a browser (with %20, %2F…) compares like-for-like instead of never matching.
        tokens.append(contentsOf: tokenize(percentDecodedPath(of: body.lowercasedHostPrefix())))

        return .success(GlobProgram(tokens: coalesce(tokens),
                                    namesPort: hostPortionNamesPort(body),
                                    requiredQuery: requiredQuery,
                                    literalHost: literalHost(of: body)))
    }

    /// True when the pattern's **host portion** (everything before the first `/`) names a port.
    /// Only the host portion is inspected, so a colon inside the path can't be mistaken for one.
    static func hostPortionNamesPort(_ patternBody: String) -> Bool {
        var body = patternBody
        if let range = body.range(of: "://") { body = String(body[range.upperBound...]) }
        let hostPart = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return hostPart.contains(":")
    }

    /// Splits a pattern body into literal / `*` / `**` tokens.
    private static func tokenize(_ s: String) -> [GlobProgram.Token] {
        var tokens: [GlobProgram.Token] = []
        var literal = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "*" {
                if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "*" {
                    tokens.append(.globstar)
                    i = s.index(after: next)
                } else {
                    tokens.append(.star)
                    i = next
                }
            } else {
                literal.append(s[i])
                i = s.index(after: i)
            }
        }
        if !literal.isEmpty { tokens.append(.literal(literal)) }
        return tokens
    }

    /// Percent-decodes only the path portion of a pattern body, leaving the host alone.
    /// Wildcards survive decoding because `*` is never percent-encoded.
    static func percentDecodedPath(of body: String) -> String {
        guard let slash = body.firstIndex(of: "/") else { return body }
        let host = String(body[body.startIndex..<slash])
        let path = String(body[slash...])
        return host + (path.removingPercentEncoding ?? path)
    }

    /// Merges adjacent wildcards so `***` and `**/**` don't blow up the matcher.
    private static func coalesce(_ tokens: [GlobProgram.Token]) -> [GlobProgram.Token] {
        var out: [GlobProgram.Token] = []
        for t in tokens {
            if case .globstar = t, case .globstar = out.last { continue }
            out.append(t)
        }
        return out
    }

    /// The literal hostname a pattern names, or nil when the host is wildcarded. Populates a
    /// rule's `divertHosts`; nil makes the editor *ask*, so Jaca never routes everything.
    static func literalHost(of patternBody: String) -> String? {
        var body = patternBody
        if let range = body.range(of: "://") { body = String(body[range.upperBound...]) }
        let hostPart = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if host.isEmpty || host.contains("*") { return nil }
        return host.lowercased()
    }

    /// The literal host of a whole pattern (including any scheme), or nil.
    static func literalHost(ofPattern pattern: String) -> String? {
        literalHost(of: pattern.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Matching

    /// True when this compiled rule matches the request.
    static func matches(_ compiled: CompiledRule, _ facts: URLFacts, method: String) -> Bool {
        let methods = compiled.rule.matcher.methods
        if !methods.isEmpty, !methods.contains(method.uppercased()) { return false }

        switch compiled.rule.matcher.kind {
        case .regex:
            guard let regex = compiled.regex else { return false }
            let subject = facts.normalized
            let range = NSRange(subject.startIndex..., in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil

        case .glob:
            guard let program = compiled.program else { return false }
            guard matchesQuery(program.requiredQuery, facts.query) else { return false }
            return matchTokens(program.tokens, against: matchSubject(facts, program: program))
        }
    }

    /// What a glob is matched against. When the pattern named no port we compare against a URL
    /// without one, so `api.x.com/**` matches `https://api.x.com:443/v1` too.
    private static func matchSubject(_ facts: URLFacts, program: GlobProgram) -> String {
        var subject = facts.scheme.isEmpty ? "" : "\(facts.scheme)://"
        subject += facts.host
        if program.namesPort, let port = facts.port { subject += ":\(port)" }
        subject += facts.path
        return subject
    }

    /// Every `k=v` the pattern required must be present, with `*` allowed in the value. Extra
    /// params in the request are fine, and order never matters.
    private static func matchesQuery(_ required: [String: String], _ actual: [String: [String]]) -> Bool {
        guard !required.isEmpty else { return true }
        for (key, wanted) in required {
            guard let values = actual[key] else { return false }
            if wanted == "*" || wanted.isEmpty { continue }
            let ok = values.contains { value in
                wanted.contains("*") ? matchTokens(tokenize(wanted), against: value) : value == wanted
            }
            if !ok { return false }
        }
        return true
    }

    /// Anchored token match with backtracking on `**`. Iterative, so a pathological pattern
    /// can't blow the stack on a path that runs per request.
    /// One wildcard's resumption point, so an exhausted wildcard can hand back to the one before
    /// it instead of failing the whole match.
    private struct GlobBacktrack {
        let tokenIndex: Int
        var subjectIndex: Int
        let isGlobstar: Bool
    }

    private static func matchTokens(_ tokens: [GlobProgram.Token], against subject: String) -> Bool {
        let s = Array(subject)
        var ti = 0, si = 0
        // A **stack**, not a single slot.
        //
        // With one slot, a later `*` overwrote the `**` before it — and because `*` may not cross
        // `/`, it could never make up the difference, so the matcher gave up while a valid match
        // existed. `**/api/*` vs `https://x.com/api/v2/api/thing` returned false: the globstar
        // committed to the *first* `/api/`, the `*` then hit the `/` after `v2`, and there was
        // nothing left to fall back to. The rule silently never fired, and the editor's preview
        // agreed with it. Bounded by the number of wildcards in the pattern, so still no stack
        // growth proportional to the subject.
        var stack: [GlobBacktrack] = []

        // Failed `(tokenIndex, subjectIndex)` states.
        //
        // The stack fixed correctness but restored classic catastrophic backtracking: when an
        // outer wildcard advances, every inner one restarts from the new position. A randomised
        // hunt over 40k patterns found ~11,800 steps *per character* on a 300-character subject
        // (≈3.5M steps for one URL) — and this runs per rule per request on a NIO event loop, so
        // a pattern the user typed into the editor could stall it.
        //
        // Whether `tokens[ti...]` matches `s[si...]` depends only on that pair, never on how we
        // reached it, so remembering the failures is sound. Measured on the same hunt: identical
        // answers on 200k differential pairs, worst case down ~9× and no longer growing with
        // subject length (it tops out around 10^6 steps for a deliberately adversarial pattern —
        // low milliseconds, and far beyond anything a real URL pattern looks like).
        var failed = Set<Int>()
        let width = s.count + 1

        while si < s.count {
            let state = ti * width + si
            if !failed.contains(state), ti < tokens.count {
                switch tokens[ti] {
                case .literal(let lit):
                    let chars = Array(lit)
                    if si + chars.count <= s.count, Array(s[si..<(si + chars.count)]) == chars {
                        si += chars.count
                        ti += 1
                        continue
                    }
                case .star, .globstar:
                    let isGlobstar: Bool
                    if case .globstar = tokens[ti] { isGlobstar = true } else { isGlobstar = false }
                    stack.append(GlobBacktrack(tokenIndex: ti, subjectIndex: si, isGlobstar: isGlobstar))
                    ti += 1
                    continue
                }
            }
            // Mismatch: let the most recent wildcard take one more character. If it can't, drop it
            // and ask the one before it — that fall-through is the whole point of the stack.
            failed.insert(state)
            guard Self.resumeGlob(stack: &stack, ti: &ti, si: &si, subject: s) else { return false }
        }
        // Trailing wildcards may match empty.
        while ti < tokens.count {
            switch tokens[ti] {
            case .star, .globstar: ti += 1
            case .literal: return false
            }
        }
        return true
    }

    /// Advances the innermost wildcard that still has room, discarding those that don't.
    /// Returns `false` when every wildcard is exhausted — a genuine non-match.
    private static func resumeGlob(stack: inout [GlobBacktrack], ti: inout Int, si: inout Int,
                                   subject s: [Character]) -> Bool {
        while var top = stack.popLast() {
            let next = top.subjectIndex + 1
            guard next <= s.count else { continue }
            // `*` must not cross a path separator; `**` may.
            if !top.isGlobstar, s[next - 1] == "/" { continue }
            top.subjectIndex = next
            stack.append(top)
            ti = top.tokenIndex + 1
            si = next
            return true
        }
        return false
    }

    // MARK: - The clamp

    /// **The single place degradation is decided.** Every transport calls it, so a rule that
    /// can't run somewhere explains itself identically everywhere — and the editor can run it
    /// speculatively to warn before a request ever fails.
    static func decide(_ compiled: CompiledRule?,
                       transport: InterceptTransportID,
                       capabilities: InterceptCapabilities,
                       masterEnabled: Bool) -> (InterceptDecision, InterceptSkipReason?) {
        guard masterEnabled else { return (.proceed, .masterOff) }
        guard let compiled, compiled.rule.enabled else { return (.proceed, .noRuleMatched) }

        let required = compiled.rule.action.requiredCapabilities
        let missing = required.subtracting(capabilities)
        guard missing.isEmpty else {
            return (.proceed, .transportUnsupported(transport: transport, missing: missing))
        }

        let delay: Duration = capabilities.contains(.delay)
            ? .milliseconds(max(0, compiled.rule.delayMillis))
            : .zero

        switch compiled.rule.action {
        case .respond(let spec):
            return (InterceptDecision(action: .respond(InterceptedResponse(
                statusCode: spec.statusCode,
                headers: spec.headers,
                body: Data()          // filled in by the resolver, which can read blobs
            )), delay: delay, ruleID: compiled.id), nil)

        case .editResponse(let edit):
            return (InterceptDecision(action: .edit(edit), delay: delay, ruleID: compiled.id), nil)

        case .mapRemote:
            // Modelled but not executable yet; the clamp above already rejects it for every
            // transport that doesn't declare .mapRemote, and none do.
            return (.proceed, .transportUnsupported(transport: transport, missing: [.mapRemote]))
        }
    }

    // MARK: - Generalize

    /// Replaces UUID-shaped and all-digit path segments with `*`, so "this one company's
    /// product-state" becomes "every company's" without learning glob syntax.
    static func generalize(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return url }
        let origin = String(url[url.startIndex..<range.upperBound])
        let rest = String(url[range.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return url }
        let host = String(rest[rest.startIndex..<slash])
        let path = String(rest[slash...])

        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
            let s = String(seg)
            return isVariable(s) ? "*" : s
        }
        return origin + host + segments.joined(separator: "/")
    }

    /// A path segment that looks like an identifier rather than a route.
    private static func isVariable(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.allSatisfy(\.isNumber) { return true }
        // UUID, with or without dashes.
        if UUID(uuidString: s) != nil { return true }
        if s.count == 32, s.allSatisfy({ $0.isHexDigit }) { return true }
        // Long opaque tokens (ids, hashes) that contain both letters and digits.
        if s.count >= 16, s.contains(where: \.isNumber), s.contains(where: \.isLetter),
           s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return true
        }
        return false
    }
}

private extension String {
    /// Lowercases only the host portion of a pattern body, leaving the case-sensitive path alone.
    func lowercasedHostPrefix() -> String {
        guard let slash = firstIndex(of: "/") else { return lowercased() }
        return String(self[startIndex..<slash]).lowercased() + String(self[slash...])
    }
}
