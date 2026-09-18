import AppKit

/// The persisted Dock icon + ⌘-Tab preference — macOS ties both to the activation policy.
/// Off by default (menu-bar only); the status item stays in either mode.
enum DockVisibility {
    static let defaultsKey = "showInDock"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }
}

/// KVO surface for the app delegate; the property name must equal `defaultsKey`.
extension UserDefaults {
    @objc dynamic var showInDock: Bool { bool(forKey: DockVisibility.defaultsKey) }
}
