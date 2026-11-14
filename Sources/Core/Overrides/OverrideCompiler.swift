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
    ///
    /// `transport` is where the request was intercepted. Under `.mitmProxy` on a device a rule
    /// fires only on its routed hosts (see `OverrideHostFilter`). A nil transport applies no
    /// host filter.
    func firstMatch(facts: URLFacts, method: String, deviceID: String?, appID: String?,
                    transport: InterceptTransportID? = nil) -> CompiledRule? {
        rules.first { applies($0, facts: facts, method: method, deviceID: deviceID, appID: appID,
                              transport: transport) }
    }

    /// Every enabled rule matching this request, in precedence order — the editor's shadow list.
    /// `transport` filters as in `firstMatch`.
    func allMatches(facts: URLFacts, method: String, deviceID: String?, appID: String?,
                    transport: InterceptTransportID? = nil) -> [CompiledRule] {
        rules.filter { applies($0, facts: facts, method: method, deviceID: deviceID, appID: appID,
                               transport: transport) }
    }

    private func applies(_ compiled: CompiledRule, facts: URLFacts, method: String, deviceID: String?,
                         appID: String?, transport: InterceptTransportID?) -> Bool {
        compiled.rule.scope.matches(deviceID: deviceID, appID: appID)
            && OverrideHostFilter.allows(routedHosts: compiled.rule.routedHosts, host: facts.host,
                                         transport: transport, deviceID: deviceID)
            && OverrideMatching.matches(compiled, facts, method: method)
    }

    /// The hosts device transports must route through the Mac. The feature's blast radius, so
    /// it's derived from **enabled** rules only, and empty means "route nothing".
    func routedHosts(deviceID: String?, appID: String?) -> Set<String> {
        guard masterEnabled else { return [] }
        var hosts: Set<String> = []
        for compiled in rules where compiled.rule.scope.matches(deviceID: deviceID, appID: appID) {
            hosts.formUnion(compiled.rule.routedHosts)
        }
        return hosts
    }
}

/// Limits a rule to its routed hosts under MITM.
///
/// An agent transport sends only the routed hosts to the Mac, so the agent needs no filter. A
/// per-rule filter there would also change which rule wins. The MITM proxy of a device (Android
/// device proxy, iOS Simulator) sees every host, so there a rule with routed hosts fires only on
/// those hosts. A rule with no routed hosts fires on every host.
///
/// This Mac's Chrome capture also uses `.mitmProxy`, but is not filtered: a generalized rule
/// (`**/lending/v1/…`) keeps the device's host as its routed host and must still answer the
/// browser's request to a dev server on another host (`localhost:3000`).
enum OverrideHostFilter {

    static func allows(routedHosts: Set<String>, host: String,
                       transport: InterceptTransportID?, deviceID: String?) -> Bool {
        guard applies(transport: transport, deviceID: deviceID), !routedHosts.isEmpty else { return true }
        let requestHost = normalize(host)
        return routedHosts.contains { normalize($0) == requestHost }
    }

    /// Whether the routed-host filter runs for a request intercepted at `transport` from
    /// `deviceID`.
    static func applies(transport: InterceptTransportID?, deviceID: String?) -> Bool {
        transport == .mitmProxy && deviceID != Device.thisMac.id
    }

    /// Lower-cases a host and removes a `:port` suffix. An IPv6 literal keeps its colons; only a
    /// bracketed form (`[::1]:8080`) loses its port and brackets.
    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            return String(h[h.index(after: h.startIndex)..<close])
        }
        if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") {
            h = String(h[..<colon])
        }
        return h
    }
}

/// Turns the user's rule list into an `OverrideRuleSet`.
enum OverrideCompiler {

    /// A rule in a group that is off is left out, like a rule that is off itself.
    static func compile(_ rules: [OverrideRule], masterEnabled: Bool,
                        groups: [OverrideGroup] = []) -> OverrideRuleSet {
        var compiled: [CompiledRule] = []
        var diagnostics: [UUID: String] = [:]

        for rule in rules where OverrideGrouping.isActive(rule, groups: groups) {
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

    /// The routed hosts a pattern implies, or empty when the host is wildcarded — which makes
    /// the editor *ask*, so Jaca never silently tunnels an app's whole traffic through the Mac.
    static func derivedRoutedHosts(for matcher: OverrideMatcher) -> Set<String> {
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
