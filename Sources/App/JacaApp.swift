import SwiftUI
import AppKit
import Lemonade
import os

private let dockLog = Logger(subsystem: "dev.srsouza.jaca", category: "dock")

/// Owns the menu-bar status item. Left-click opens/focuses the window; right-click (or
/// control-click) shows a menu (Open / Quit). Menu-bar only by default (`DockVisibility` is
/// the Dock/⌘-Tab opt-in); closing the window just hides it, so the app stays running.
final class JacaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var dockPreferenceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showInDock = DockVisibility.isEnabled
        if !NSApp.setActivationPolicy(DockVisibility.policy(showInDock: showInDock)) {
            dockLog.error("AppKit refused the launch activation policy (showInDock: \(showInDock))")
        }
        // React when Settings toggles the preference. KVO, not SwiftUI forwarding: the
        // delegate owns the side effect, and it fires in the same runloop pass as the write.
        dockPreferenceObservation = UserDefaults.standard.observe(\.showInDock) { [weak self] _, _ in
            self?.applyDockVisibility(DockVisibility.isEnabled)
        }
        installStatusItem()
        adoptMainWindow()
    }

    /// Applies the Dock/⌘-Tab preference live. Changing the policy hides the window and
    /// deactivates the app, so re-show in the same runloop pass — deferring reads as a blink.
    func applyDockVisibility(_ showInDock: Bool) {
        let policy = DockVisibility.policy(showInDock: showInDock)
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.setActivationPolicy(policy) else {
            // Roll back the already-written preference so the Toggle matches reality;
            // the guard above stops the observer re-fire loop.
            dockLog.error("AppKit refused the activation policy change (showInDock: \(showInDock)) — reverting the preference")
            DockVisibility.isEnabled = !showInDock
            return
        }
        openWindow()

        // AppKit can settle the transition asynchronously and pull the app back down —
        // re-assert once, but only if it landed wrong (a redundant re-order flickers).
        DispatchQueue.main.async { [weak self] in
            // Not `isKeyWindow`: the Settings sheet holds key, so that would always re-fire.
            guard let self, let window = self.mainWindow,
                  !NSApp.isActive || !window.isVisible else { return }
            self.openWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Closing only hides the window, so a Dock click / ⌘-Tab reopen must re-show it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyCleanup.revertAll()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage)
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = false
            button.image = icon
            button.toolTip = "Jaca"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            openWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Jaca", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        addUpdateItem(to: menu)
        let quit = NSMenuItem(title: "Quit Jaca", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach transiently so this click pops the menu, then detach so the next
        // left-click runs the action instead of opening the menu.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Adds an "Update Jaca" item when one is available, or a disabled progress line
    /// while an update runs. Nothing when up to date or the feature is off.
    private func addUpdateItem(to menu: NSMenu) {
        MainActor.assumeIsolated {
            let update = UpdateModel.shared
            guard update.enabled else { return }
            let item: NSMenuItem
            if let phase = update.phase {
                item = NSMenuItem(title: "Updating — \(phase.label)", action: nil, keyEquivalent: "")
                item.isEnabled = false
            } else if update.isWorktreeBuild {
                // Can't update from a linked worktree (main is held elsewhere) — offer to
                // switch to the primary checkout, with a confirm.
                item = NSMenuItem(title: "Switch to Main Checkout & Update…", action: #selector(switchAndUpdate), keyEquivalent: "")
                item.target = self
            } else if update.updateAvailable {
                item = NSMenuItem(title: "Update Jaca", action: #selector(runUpdate), keyEquivalent: "")
                item.target = self
            } else if update.isChecking {
                item = NSMenuItem(title: "Checking for updates…", action: nil, keyEquivalent: "")
                item.isEnabled = false
            } else {
                item = NSMenuItem(title: "Check for Updates", action: #selector(checkUpdate), keyEquivalent: "")
                item.target = self
            }
            menu.addItem(item)
            menu.addItem(.separator())
        }
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func runUpdate() {
        MainActor.assumeIsolated { UpdateModel.shared.runUpdate() }
    }

    /// Worktree build: confirm, then rebuild/reinstall from the primary (main) checkout.
    @objc private func switchAndUpdate() {
        MainActor.assumeIsolated {
            let update = UpdateModel.shared
            let alert = NSAlert()
            alert.messageText = "Switch to the main checkout?"
            alert.informativeText = "This build runs from the worktree “\(update.worktreeName ?? "")”. In-app updates can't run there because main is checked out elsewhere. Jaca will rebuild and reinstall from the main checkout, then relaunch."
            alert.addButton(withTitle: "Switch & Update")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                update.runUpdate(switchToPrimary: true)
            }
        }
    }

    @objc private func checkUpdate() {
        MainActor.assumeIsolated { UpdateModel.shared.check() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Keep the window alive (hide on close)

    /// Grab the WindowGroup's window once it exists, become its delegate so the red
    /// close button hides it (kept alive) instead of destroying it.
    private func adoptMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            mainWindow = window
            window.isReleasedWhenClosed = false
            window.delegate = self
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.adoptMainWindow() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)   // hide instead of close, so left-click can bring it back
        return false
    }
}

@main
struct JacaApp: App {
    @NSApplicationDelegateAdaptor(JacaAppDelegate.self) private var appDelegate
    @AppStorage("colorScheme") private var colorScheme = "dark"

    init() {
        // Register the Figtree faces bundled with the Lemonade design system so
        // LemonadeUi.Text renders in the brand typeface instead of the system font.
        LemonadeFonts.registerFonts()
        // Show hover tooltips (e.g. the tab context tooltip) quickly instead of after the long
        // ~1.5s system default. App-wide and harmless for a developer tool. Milliseconds.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Projects") {
                    NotificationCenter.default.post(name: .openProjects, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Format…") {
                    NotificationCenter.default.post(name: .openLogCopyFormat, object: nil)
                }
            }
        }
    }

    private var preferredScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
