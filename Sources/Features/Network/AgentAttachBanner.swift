import SwiftUI
import Lemonade

/// The pane-top notice for a tab still capturing on paper but with the agent gone from the app —
/// the user reopened it themselves, so `DYLD_INSERT_LIBRARIES` no longer applies.
///
/// Otherwise invisible: rows just stop arriving while the toolbar says "capturing". So it sits
/// above the content, carries the one action that fixes it, and animates in — appearing
/// mid-session without a transition reads as the layout glitching.
struct AgentAttachBanner: View {
    @Bindable var session: NetworkSession

    var body: some View {
        VStack(spacing: 0) {
            if session.showsAttachBanner {
                notice
                    .padding(.horizontal, LemonadeTheme.spaces.spacing300)
                    .padding(.vertical, LemonadeTheme.spaces.spacing200)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("netAttachBanner")
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: session.showsAttachBanner)
        .animation(.easeInOut(duration: 0.2), value: session.armingState)
    }

    @ViewBuilder
    private var notice: some View {
        // Wording comes from the arming state, so the banner, tooltip and row badges agree.
        LemonadeUi.Notice(content: session.armingState.blockedMessage ?? "",
                          voice: .warning,
                          title: title,
                          actionLabel: actionLabel,
                          onActionClick: actionLabel == nil ? nil : { session.relaunchToAttach() })
    }

    private var title: String {
        if case .waitingForApp = session.armingState { return "Capture paused" }
        return "Capture detached"
    }

    /// **Only for `.detached`.** If the app isn't running the user closed it, and Jaca doesn't
    /// offer to reopen an app somebody quit — the notice just says what would resume capture.
    private var actionLabel: String? {
        if case .detached = session.armingState { return "Relaunch & re-attach" }
        return nil
    }
}
