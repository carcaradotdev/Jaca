import XCTest
import AppKit
@testable import Jaca

final class DockVisibilityTests: XCTestCase {
    func testPolicyMapping() {
        XCTAssertEqual(DockVisibility.policy(showInDock: true), .regular)
        XCTAssertEqual(DockVisibility.policy(showInDock: false), .accessory)
    }

    func testDefaultsToMenuBarOnlyWhenUnset() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DockVisibility.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: DockVisibility.defaultsKey) }
            else { defaults.removeObject(forKey: DockVisibility.defaultsKey) }
        }

        defaults.removeObject(forKey: DockVisibility.defaultsKey)
        XCTAssertFalse(DockVisibility.isEnabled)    // fresh install → menu-bar only

        defaults.set(true, forKey: DockVisibility.defaultsKey)
        XCTAssertTrue(DockVisibility.isEnabled)     // choice survives relaunch
    }
}
