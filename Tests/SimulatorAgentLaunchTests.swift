import XCTest
@testable import Jaca

/// The `simctl launch` injection recipe.
///
/// Every assertion here guards a failure that produces no error at runtime: `simctl` forwards only
/// `SIMCTL_CHILD_`-prefixed variables, drops an unrecognised flag placement onto the app instead of
/// the launcher, and `xcrun` without `DEVELOPER_DIR` finds no `simctl` at all when `xcode-select`
/// points at the CommandLineTools. Each of those launches the app perfectly and captures nothing.
final class SimulatorAgentLaunchTests: XCTestCase {

    private let dylib = URL(fileURLWithPath: "/Applications/Jaca.app/Contents/Resources/JacaNetAgent.dylib")

    func test_childEnvironmentIsExactlyTheTwoPrefixedKeys() {
        let env = SimulatorAgentLaunch.childEnvironment(agentDylib: dylib, port: 41234)

        XCTAssertEqual(Set(env.keys),
                       ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES", "SIMCTL_CHILD_JACA_NET_PORT"],
                       "the SIMCTL_CHILD_ prefix is the entire injection mechanism")
        XCTAssertEqual(env["SIMCTL_CHILD_JACA_NET_PORT"], "41234", "decimal, not hex or a description")
        XCTAssertEqual(env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"], dylib.path)
        XCTAssertTrue(dylib.path.hasPrefix("/"), "dyld resolves the insert list from the app's cwd, not ours")
    }

    func test_terminateRunningProcessPrecedesTheUdid() throws {
        let args = SimulatorAgentLaunch.arguments(udid: "UDID", bundleID: "com.example.App",
                                                  terminateRunning: true)

        XCTAssertEqual(args, ["simctl", "launch", "--terminate-running-process", "UDID", "com.example.App"])
        let flag = try XCTUnwrap(args.firstIndex(of: "--terminate-running-process"))
        let udid = try XCTUnwrap(args.firstIndex(of: "UDID"))
        XCTAssertLessThan(flag, udid,
                          "after the udid it stops being a flag of `launch`, and the app is only foregrounded")
    }

    func test_argumentsWithoutTerminateOmitTheFlag() {
        XCTAssertEqual(
            SimulatorAgentLaunch.arguments(udid: "UDID", bundleID: "com.example.App",
                                           terminateRunning: false),
            ["simctl", "launch", "UDID", "com.example.App"])
    }

    func test_developerDirSurvivesTheChildEnvironmentMerge() {
        let child = SimulatorAgentLaunch.childEnvironment(agentDylib: dylib, port: 41234)

        let merged = SimulatorAgentLaunch.launchEnvironment(
            base: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "PATH": "/usr/bin"],
            childEnvironment: child)
        XCTAssertEqual(merged["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(merged["PATH"], "/usr/bin")
        XCTAssertEqual(merged["SIMCTL_CHILD_JACA_NET_PORT"], "41234")

        // And with the real toolchain environment this file actually ships with.
        let base = AppleToolchain.environment()
        let real = SimulatorAgentLaunch.launchEnvironment(base: base, childEnvironment: child)
        XCTAssertEqual(real["DEVELOPER_DIR"], base["DEVELOPER_DIR"])
        XCTAssertEqual(real["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"], dylib.path)
    }
}
