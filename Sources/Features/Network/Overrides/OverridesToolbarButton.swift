import SwiftUI
import Lemonade

/// The "Overrides" control in the network toolbar, right of the search field — the entry point
/// that doesn't need a captured request, so you can write a rule for an endpoint the app hasn't
/// called yet. Chrome matches `NetworkAppPicker`.
struct OverridesToolbarButton: View {
    @Bindable var session: NetworkSession
    @State private var showPopover = false

    private var overrides: OverridesModel? { session.overrides }

    var body: some View {
        if let overrides {
            Button(action: { showPopover = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(phase.tint)
                    Text("Overrides")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    if let badge = phase.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(phase.tint)
                            .strikethrough(phase.struckThrough)
                            .contentTransition(.numericText())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(phase.badgeBackground))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            }
            .buttonStyle(.plain)
            .help(phase.tooltip)
            .accessibilityIdentifier("netOverridesButton")
            .animation(.easeInOut(duration: 0.2), value: phase)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                OverridesPopover(session: session, overrides: overrides)
            }
        }
    }

    // MARK: - Phase

    /// Coarse display state, derived once from the shared model rather than per view.
    private enum Phase: Equatable {
        case none
        case notRunning(Int)
        case notWired(Int)
        case armed(Int)
        case blocked(Int, Int, String)
        case failed(String)
        case paused(Int)

        var tint: Color {
            switch self {
            case .none:       return LemonadeTheme.colors.content.contentTertiary
            case .notRunning: return LemonadeTheme.colors.content.contentTertiary
            case .notWired:   return LemonadeTheme.colors.content.contentCaution
            case .armed:   return LemonadeTheme.colors.content.contentBrand
            case .blocked: return LemonadeTheme.colors.content.contentCaution
            case .failed:  return LemonadeTheme.colors.content.contentCritical
            case .paused:  return LemonadeTheme.colors.content.contentTertiary
            }
        }

        var badge: String? {
            switch self {
            case .none:                          return nil
            case .notRunning(let n):             return "\(n)"
            case .notWired(let n):               return "\(n)"
            case .armed(let n):                  return "\(n)"
            case .blocked(let ok, let total, _): return "\(ok) of \(total)"
            case .failed:                        return "!"
            case .paused(let n):                 return "\(n)"
            }
        }

        var struckThrough: Bool { if case .paused = self { return true }; return false }

        var badgeBackground: Color {
            switch self {
            case .armed:   return LemonadeTheme.colors.background.bgBrandSubtle
            case .blocked: return LemonadeTheme.colors.background.bgCautionSubtle
            case .failed:  return LemonadeTheme.colors.background.bgCriticalSubtle
            default:       return LemonadeTheme.colors.background.bgNeutralSubtle
            }
        }

        var tooltip: String {
            switch self {
            case .none:              return "Override any response for any request"
            case .notRunning(let n):
                return "\(n) override\(n == 1 ? "" : "s") saved — start capture to apply them"
            case .notWired(let n):
                return "\(n) override\(n == 1 ? "" : "s") saved, but this capture wasn't started "
                     + "with overrides enabled. Stop and start capture to apply them."
            case .armed(let n):      return "\(n) override\(n == 1 ? "" : "s") active on this tab"
            case .blocked(_, _, let reason): return reason
            case .failed(let detail):        return detail
            case .paused:            return "Overrides paused — resume them in this popover"
            }
        }
    }

    private var phase: Phase {
        guard let overrides else { return .none }
        let enabled = overrides.enabledCount
        guard enabled > 0 else { return .none }
        guard overrides.masterEnabled else { return .paused(enabled) }

        // A stopped tab, or one launched before the flag was on, has nothing armed whatever the
        // rules say.
        guard session.hasRunningSource else { return .notRunning(enabled) }
        guard session.interceptWired else { return .notWired(enabled) }

        // Exhaustive on purpose, so adding an arming state forces a presentation for it here.
        // The wording comes from the state, so tooltip, popover and row badge agree.
        switch armingState {
        case .failed, .agentTooOld:
            return .failed(armingState.blockedMessage ?? "")
        case .waitingForAgent, .waitingForApp, .detached:
            return .blocked(0, enabled, armingState.blockedMessage ?? "")
        case .idle, .active:
            break
        }

        // The same clamp the runtime uses, so the toolbar can't claim an override that won't
        // run.
        let capabilities = session.activeInterceptCapabilities
        let transport = session.interceptTransport
        let honourable = overrides.rules.filter { rule in
            guard rule.enabled else { return false }
            let compiled = CompiledRule(rule: rule, program: nil, regex: nil)
            let (_, skip) = OverrideMatching.decide(compiled, transport: transport,
                                                    capabilities: capabilities,
                                                    masterEnabled: true)
            return skip == nil
        }.count

        if honourable < enabled {
            let reason = InterceptSkipReason
                .transportUnsupported(transport: transport, missing: [.shortCircuit]).message
            return .blocked(honourable, enabled, reason)
        }
        return .armed(enabled)
    }

    private var armingState: InterceptArmingState { session.armingState }
}
