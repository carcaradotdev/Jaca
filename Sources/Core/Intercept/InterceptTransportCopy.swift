import Foundation

/// The single owner of every user-facing string that is only true for *one* interception point.
///
/// Written inline in views, this copy hard-coded adb, okhttp3 and "the device's own network" —
/// all false on the iOS Simulator, where the Mac *is* the app's network. A transport-keyed lookup
/// in `Core/` can be unit-tested; a view can't.
///
/// Rule for adding here: if a sentence names a tunnel, a stack, or where the bytes physically go,
/// it belongs in this file with one arm per transport.
extension InterceptTransportID {

    /// The popover's "what is actually being routed" help: what leaves the device and what tears
    /// it down — the blast-radius contract.
    var divertScopeHelp: String {
        switch self {
        case .agentDivert:
            return "Only these hosts leave the device's own network. Everything else is untouched. "
                 + "The adb reverse tunnel is removed when this tab stops, and the agent disarms "
                 + "itself if Jaca goes away."
        case .iosSimulatorDivert:
            // No tunnel to promise the removal of — the Simulator shares the Mac's loopback.
            return "Only these hosts are diverted to Jaca. Everything else the app requests goes "
                 + "straight out, untouched. The agent disarms itself if Jaca goes away."
        case .mitmProxy:
            return "While this tab is capturing, the device sends everything through Jaca's proxy."
        case .companionMetadata:
            return "The companion app reports flow metadata only — there is nothing here to divert."
        }
    }

    /// How the device reaches the override server. Android only sees `localhost:port` because
    /// `adb reverse` put it there, so saying "127.0.0.1" sends people looking for a Mac-side
    /// listener the phone can't see.
    func portLabel(port: Int) -> String {
        switch self {
        case .agentDivert:        return "via adb reverse :\(port)"
        case .iosSimulatorDivert: return "127.0.0.1:\(port)"
        case .mitmProxy:          return "127.0.0.1:\(port)"
        case .companionMetadata:  return "port \(port)"
        }
    }

    /// The editor's caution under "Send and override": Jaca fetches the real response, so an
    /// origin only the device can resolve (VPN, corp network, emulator alias) won't work. Empty on
    /// the Simulator, where the Mac *is* the app's network.
    var originExplainer: String {
        switch self {
        case .agentDivert, .mitmProxy:
            return "Jaca fetches this URL from your Mac, not from the device. Origins reachable "
                 + "only from the device won't work."
        case .iosSimulatorDivert, .companionMetadata:
            return ""
        }
    }

    /// The editor's notice when a pattern doesn't name a host — we never route "everything".
    var hostsNotice: String {
        switch self {
        case .agentDivert:
            return "This pattern doesn't name a host. Tell Jaca which hosts to route through your "
                 + "Mac — only these leave the device's own network."
        case .iosSimulatorDivert:
            return "This pattern doesn't name a host. Tell Jaca which hosts to divert — only these "
                 + "are answered by Jaca; everything else the app requests is untouched."
        case .mitmProxy, .companionMetadata:
            return "This pattern doesn't name a host. Tell Jaca which hosts this rule applies to."
        }
    }

    /// The capture-chooser detail, which names what each transport *cannot* see: call stacks are
    /// Android-only, and `NSURLProtocol` never sees `WKWebView`, background `URLSession`s, bundled
    /// stacks or raw sockets. An unnamed blind spot becomes a bug report.
    var captureDetail: String {
        switch self {
        case .agentDivert:
            return "Inspect one debuggable Android app in-process — no proxy or CA, with call stacks."
        case .iosSimulatorDivert:
            return "Inspect one Simulator app in-process — no proxy or CA. URLSession only: "
                 + "WKWebView, background sessions and raw sockets aren't seen."
        case .mitmProxy:
            return "Decrypt HTTPS device-wide through a proxy the device is set to trust."
        case .companionMetadata:
            return "Receive per-app traffic from the Jaca mobile agent over the network."
        }
    }

    /// One chooser row covers two transports and is drawn before the platform is known, so this
    /// is the honest intersection. Per-platform truth is in `captureDetail`.
    static let agentChooserDetail =
        "Inspect one app in-process — no proxy or CA. Android: call stacks included. "
      + "iOS Simulator: URLSession only."

    /// Human name for an agent-reported HTTP stack. Android-only: nothing else reports one.
    static func stackLabel(_ stack: String) -> String {
        switch stack {
        case "okhttp3":       return "okhttp3"
        case "okhttp2":       return "okhttp2"
        case "urlconnection": return "HttpURLConnection"
        default:              return stack
        }
    }
}

/// The one sentence each "armed, but silently doing nothing" state gets. Copy-pasted across the
/// row badge, popover and toolbar, it drifted into three wordings for one state. Each surface
/// still picks its own presentation, but the words come from here.
extension InterceptArmingState {
    /// Nil for the two states that aren't blocking anything: `.idle` (nothing is wired) and
    /// `.active` (it works).
    var blockedMessage: String? {
        switch self {
        case .failed(let detail):
            return detail
        case .agentTooOld:
            return "This app has an older Jaca agent — rebuild it and restart capture."
        case .waitingForAgent:
            return "Arming — waiting for the agent to load in the app."
        case .waitingForApp(let appID):
            return "Open \(appID) to resume capturing."
        case .detached(let appID):
            return "\(appID) is running without the Jaca agent — relaunch it to resume."
        case .idle, .active:
            return nil
        }
    }
}
