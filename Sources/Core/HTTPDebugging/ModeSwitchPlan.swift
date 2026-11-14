import Foundation

/// What a mode switch does to each open network tab. A switch never starts a capture, because a
/// start can relaunch the user's app.
enum ModeSwitchPlan {
    enum Action: Sendable, Hashable {
        /// The tab's source is still offered: leave it as it is, running or not.
        case keep
        /// The new mode does not offer the tab's source: stop it and show the chooser.
        case stopAndReopenChooser
    }

    /// One open tab.
    struct Capture: Sendable {
        let id: UUID
        let device: Device
        /// The chosen source. nil when the tab already shows the chooser.
        let sourceID: String?

        init(id: UUID, device: Device, sourceID: String?) {
            self.id = id
            self.device = device
            self.sourceID = sourceID
        }
    }

    static func make(captures: [Capture], to strategy: any HTTPDebuggingStrategy) -> [UUID: Action] {
        var plan: [UUID: Action] = [:]
        for capture in captures {
            plan[capture.id] = action(for: capture, to: strategy)
        }
        return plan
    }

    static func action(for capture: Capture, to strategy: any HTTPDebuggingStrategy) -> Action {
        guard let sourceID = capture.sourceID else { return .keep }
        return strategy.sourceIDs(for: capture.device).contains(sourceID) ? .keep : .stopAndReopenChooser
    }
}
