import Foundation

/// Keeps a rule's routed hosts in step with its match pattern while it's being edited.
///
/// `divertHosts` is the blast radius: every host in it is sent through the Mac. When the pattern
/// names a literal host the set is derived from it; when it doesn't (a wildcarded host, any regex)
/// the user types it. The editor used to only ever *add* derived hosts, so changing
/// `https://api.example.com/*` to `https://*.other.com/*` left `api.example.com` in the hosts field.
/// That satisfied the "at least one host" check, and the rule saved routing traffic it could never
/// match. Remembering whether the current set was derived is what lets a stale one be dropped
/// without discarding hosts the user typed.
enum DivertHostSync {
    struct State: Equatable {
        var hosts: Set<String>
        /// The hosts came from the pattern rather than from the user.
        var isDerived: Bool
    }

    /// How a rule opens: derived only if its saved hosts are exactly what its pattern implies.
    static func initial(hosts: Set<String>, derived: Set<String>) -> State {
        State(hosts: hosts, isDerived: !derived.isEmpty && hosts == derived)
    }

    /// After the pattern or the glob/regex choice changes. `derived` is what the new matcher implies.
    static func afterMatcherChange(_ state: State, derived: Set<String>) -> State {
        if !derived.isEmpty { return State(hosts: derived, isDerived: true) }
        // The pattern no longer names a host. Hosts derived from an earlier pattern are stale;
        // hosts the user typed are still theirs.
        guard state.isDerived else { return state }
        return State(hosts: [], isDerived: false)
    }

    /// The user typed into the hosts field, so the set is theirs from now on.
    static func afterUserEdit(hosts: Set<String>) -> State {
        State(hosts: hosts, isDerived: false)
    }
}
