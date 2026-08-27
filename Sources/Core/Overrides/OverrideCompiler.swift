import Foundation

/// An immutable, pre-compiled snapshot of the enabled rules. Compiling per edit instead of per
/// request keeps the hot path to a token walk, and makes the snapshot shareable without locking.
struct OverrideRuleSet: Sendable {
    /// Enabled rules in precedence order — **first match wins**, like a firewall table.
    var rules: [CompiledRule] = []
    var masterEnabled: Bool = true
    /// Rules that compiled but can never fire (bad regex, missing body). Surfaced as caution dots.
    var diagnostics: [UUID: String] = [:]

    static let empty = OverrideRuleSet(rules: [], masterEnabled: true)

    /// The first enabled rule matching this request, or nil.
    func firstMatch(facts: URLFacts, method: String, deviceID: String?, appID: String?) -> CompiledRule? {
        rules.first { compiled in
            compiled.rule.scope.matches(deviceID: deviceID, appID: appID)
                && OverrideMatching.matches(compiled, facts, method: method)
        }
    }

    /// Every enabled rule matching this request, in precedence order — the editor's shadow list.
    func allMatches(facts: URLFacts, method: String, deviceID: String?, appID: String?) -> [CompiledRule] {
        rules.filter { compiled in
            compiled.rule.scope.matches(deviceID: deviceID, appID: appID)
                && OverrideMatching.matches(compiled, facts, method: method)
        }
    }

    /// The hosts device transports must route through the Mac. The feature's blast radius, so
    /// it's derived from **enabled** rules only, and empty means "divert nothing".
    func divertHosts(deviceID: String?, appID: String?) -> Set<String> {
        guard masterEnabled else { return [] }
        var hosts: Set<String> = []
        for compiled in rules where compiled.rule.scope.matches(deviceID: deviceID, appID: appID) {
            hosts.formUnion(compiled.rule.divertHosts)
        }
        return hosts
    }
}

/// Turns the user's rule list into an `OverrideRuleSet`.
enum OverrideCompiler {

    static func compile(_ rules: [OverrideRule], masterEnabled: Bool) -> OverrideRuleSet {
        var compiled: [CompiledRule] = []
        var diagnostics: [UUID: String] = [:]

        for rule in rules where rule.enabled {
            switch rule.matcher.kind {
            case .glob:
                switch OverrideMatching.compileGlob(rule.matcher.pattern) {
                case .success(let program):
                    compiled.append(CompiledRule(rule: rule, program: program, regex: nil))
                case .failure(let error):
                    diagnostics[rule.id] = message(for: error)
                }
            case .regex:
                let anchored = anchor(rule.matcher.pattern)
                if let regex = try? NSRegularExpression(pattern: anchored, options: [.caseInsensitive]) {
                    compiled.append(CompiledRule(rule: rule, program: nil, regex: regex))
                } else {
                    diagnostics[rule.id] = "This regular expression isn't valid."
                }
            }
            if let reason = bodyDiagnostic(for: rule) { diagnostics[rule.id] = reason }
        }

        return OverrideRuleSet(rules: compiled, masterEnabled: masterEnabled, diagnostics: diagnostics)
    }

    /// Anchors a regex to the whole URL, so a partial pattern can't match unexpectedly broadly.
    static func anchor(_ pattern: String) -> String {
        var p = pattern
        if !p.hasPrefix("^") { p = "^" + p }
        if !p.hasSuffix("$") { p += "$" }
        return p
    }

    /// The divert hosts a pattern implies, or empty when the host is wildcarded — which makes
    /// the editor *ask*, so Jaca never silently tunnels an app's whole traffic through the Mac.
    static func derivedDivertHosts(for matcher: OverrideMatcher) -> Set<String> {
        guard matcher.kind == .glob else { return [] }
        guard let host = OverrideMatching.literalHost(ofPattern: matcher.pattern) else { return [] }
        return [host]
    }

    private static func bodyDiagnostic(for rule: OverrideRule) -> String? {
        switch rule.action {
        case .respond(let spec):
            return OverrideBodyLoader.unavailableReason(for: spec.body)
        case .editResponse(let edit):
            guard let body = edit.body else { return nil }
            return OverrideBodyLoader.unavailableReason(for: body)
        case .mapRemote:
            return nil
        }
    }

    private static func message(for error: GlobError) -> String {
        switch error {
        case .empty:               return "This override has no URL pattern."
        case .invalidRegex(let m): return m
        }
    }
}
