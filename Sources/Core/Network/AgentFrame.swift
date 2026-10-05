import Foundation

/// One agent line, classified. Both controllers switch on this, so their readers cannot drift.
enum AgentFrame: Equatable {
    case transaction(NetworkTransaction)
    /// The agent's greeting, and the only proof it can read control frames. The desktop pushes an
    /// endpoint only after seeing `override/1`, so a pre-feature agent is never spoken to.
    case hello(supportsOverride: Bool)
    /// Unknown frame types are ignored by design — forward compatibility with a newer agent.
    case unrecognised(String)

    static func classify(_ line: String) -> AgentFrame {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .unrecognised(line) }
        switch type {
        case "txn":
            // Handed the object we already decoded: re-parsing the line was a second full JSON
            // decode of every captured transaction, on the reader thread, for nothing.
            guard let txn = AgentTransactionParser.parse(object: obj) else { return .unrecognised(line) }
            return .transaction(txn)
        case "hello":
            let caps = (obj["caps"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .hello(supportsOverride: caps.contains("override/1"))
        default:
            return .unrecognised(line)
        }
    }
}
