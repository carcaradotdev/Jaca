import Foundation

/// The `InterceptResolving` implementation backed by the user's rule library. Holds an immutable
/// `OverrideRuleSet` behind a lock and swaps it wholesale on every edit, so `resolve` — on NIO
/// event loops and the agent's reader thread — never touches the main actor.
final class OverrideResolver: InterceptResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var ruleSet: OverrideRuleSet = .empty

    init(ruleSet: OverrideRuleSet = .empty) {
        self.ruleSet = ruleSet
    }

    /// Publishes a new snapshot. Called from the model on every rule edit or master-switch flip.
    func publish(_ newValue: OverrideRuleSet) {
        lock.lock(); ruleSet = newValue; lock.unlock()
    }

    var current: OverrideRuleSet {
        lock.lock(); defer { lock.unlock() }
        return ruleSet
    }

    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?) {
        let snapshot = current

        guard snapshot.masterEnabled else { return (.proceed, .masterOff) }
        // No parseable URL (companion flow metadata is "host:port") — nothing to match against.
        guard let facts = request.facts else { return (.proceed, .noRuleMatched) }

        guard let matched = snapshot.firstMatch(facts: facts, method: request.method,
                                                deviceID: request.deviceID, appID: request.appID)
        else {
            return (.proceed, .noRuleMatched)
        }

        var (decision, skip) = OverrideMatching.decide(matched,
                                                       transport: request.transport,
                                                       capabilities: capabilities,
                                                       masterEnabled: snapshot.masterEnabled)

        // The clamp builds the response shell; fill in the body here, where blobs can be read.
        if case .respond(var canned) = decision.action,
           case .respond(let spec) = matched.rule.action {
            canned.body = OverrideBodyLoader.data(for: spec.body) ?? Data()
            decision.action = .respond(canned)
        }
        return (decision, skip)
    }
}
