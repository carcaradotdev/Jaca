import Foundation

/// The entire vocabulary the device is ever given: where to send traffic, which hosts, and how
/// long that permission lasts. No patterns, payloads, statuses or ordering.
///
/// **The tripwire for review:** a field added here is a field the device learned about. Teaching
/// it a path, method, header, body, status, ordering or rule-id crosses the line that keeps the
/// agent dumb — and shows up in a diff of this struct.
///
/// Twins to keep in sync: `agent/iOS/JacaAgentHTTP.m`,
/// `agent/kotlin/com/squeeze/capture/AgentHttp.kt`. See `docs/agent-http-contract.md`.
struct AgentHTTPRoute: Sendable, Equatable {
    /// `nil` means route **nothing** — never "route everything".
    private(set) var origin: String?
    private(set) var hosts: Set<String>
    var heartbeatSeconds: Int

    /// Clears `origin` and `hosts` **together**, so an empty host set can never arm the device
    /// and an absent origin can never leave a stale host list behind.
    init(origin: String?, hosts: Set<String>, heartbeatSeconds: Int = 15) {
        let armed = !(origin ?? "").isEmpty && !hosts.isEmpty
        self.origin = armed ? origin : nil
        self.hosts = armed ? hosts : []
        self.heartbeatSeconds = heartbeatSeconds
    }

    /// The single spelling of "stop". Carries the heartbeat window so the value survives teardown.
    static func disarmed(heartbeatSeconds: Int = 15) -> AgentHTTPRoute {
        AgentHTTPRoute(origin: nil, hosts: [], heartbeatSeconds: heartbeatSeconds)
    }

    var isArmed: Bool { origin != nil }

    /// The **only** desktop→device frame in the product. Newline-free (the wire is NDJSON), and
    /// hosts are sorted so an unchanged rule set frames identically every heartbeat.
    ///
    /// The frame type on the wire is still `"divert"`: an older agent can still be loaded in a
    /// running app, and only understands that spelling. See `docs/agent-http-contract.md`.
    static func routeFrame(_ endpoint: AgentHTTPRoute) -> String {
        let hostList = endpoint.hosts.sorted().map(quoted).joined(separator: ",")
        let originJSON = endpoint.origin.map(quoted) ?? "null"
        return "{\"type\":\"divert\",\"origin\":\(originJSON),\"hosts\":[\(hostList)]," +
               "\"heartbeatSeconds\":\(endpoint.heartbeatSeconds)}"
    }

    /// Hosts come from user-authored rules, so a stray quote must not produce an unparsable
    /// frame.
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":     out += "\\\""
            case "\\":     out += "\\\\"
            case "\n":     out += "\\n"
            case "\r":     out += "\\r"
            case "\t":     out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
