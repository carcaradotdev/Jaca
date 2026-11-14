import XCTest
@testable import Jaca

/// `jaca`'s command line: every command, and what happens to arguments that don't parse.
final class CLIParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ line: String) -> CLIInvocation {
        CLIParser.parse(line.split(separator: " ").map(String.init), now: now)
    }

    // MARK: - Commands

    func test_plainCommands() {
        XCTAssertEqual(parse("devices").command, .devices)
        XCTAssertEqual(parse("logs list").command, .logsList)
        XCTAssertEqual(parse("net list").command, .netList)
        XCTAssertEqual(parse("overrides list").command, .overridesList)
    }

    func test_logsTail_readsEveryOption() {
        XCTAssertEqual(parse("logs tail").command,
                       .logsTail(session: nil, grep: nil, minLevel: nil, since: nil, count: nil, follow: false))
        XCTAssertEqual(parse("logs tail pixel -n 20 --grep time.?out --level error --since 5m --follow").command,
                       .logsTail(session: "pixel", grep: "time.?out", minLevel: .error,
                                 since: now.addingTimeInterval(-300), count: 20, follow: true))
        XCTAssertEqual(parse("logs tail --grep=a=b -f").command,
                       .logsTail(session: nil, grep: "a=b", minLevel: nil, since: nil, count: nil, follow: true))
    }

    func test_netRequests_readsEveryOption() {
        XCTAssertEqual(parse("net requests").command,
                       .netRequests(session: nil, host: nil, status: [], method: nil, failed: false, count: nil))
        XCTAssertEqual(parse("net requests 3fa2 --host api.example.com --status 404,5xx --method post --failed -n 5").command,
                       .netRequests(session: "3fa2", host: "api.example.com",
                                    status: [NetworkStatusRange(min: 404, max: 404), NetworkStatusRange(min: 500, max: 599)],
                                    method: "post", failed: true, count: 5))
    }

    func test_netShow_andOverrides() {
        XCTAssertEqual(parse("net show 3fa2").command, .netShow(request: "3fa2"))
        XCTAssertEqual(parse("overrides add --from 3fa2").command,
                       .overridesAdd(from: "3fa2", name: nil, statusCode: nil, bodyFile: nil, disabled: false, generalize: false))
        XCTAssertEqual(parse("overrides add --from 3fa2 --name Stub --status 503 --body-file - --disabled --generalize").command,
                       .overridesAdd(from: "3fa2", name: "Stub", statusCode: 503, bodyFile: "-", disabled: true, generalize: true))
        XCTAssertEqual(parse("overrides generalize Stub").command, .overridesGeneralize(rule: "Stub"))
        XCTAssertEqual(parse("overrides enable Stub").command, .overridesSetEnabled(rule: "Stub", enabled: true))
        XCTAssertEqual(parse("overrides disable 9c").command, .overridesSetEnabled(rule: "9c", enabled: false))
        XCTAssertEqual(parse("overrides rm 9c").command, .overridesRemove(rule: "9c"))
        XCTAssertEqual(parse("overrides groups").command, .overridesGroups)
        XCTAssertEqual(parse("overrides mkgroup Deals").command, .overridesNewGroup(name: "Deals"))
        XCTAssertEqual(parse("overrides rmgroup Deals").command, .overridesRemoveGroup(group: "Deals"))
        XCTAssertEqual(parse("overrides enable --group Deals").command, .overridesSetGroupEnabled(group: "Deals", enabled: true))
        XCTAssertEqual(parse("overrides disable --group=Deals").command, .overridesSetGroupEnabled(group: "Deals", enabled: false))
        XCTAssertEqual(parse("overrides group 9c Deals").command, .overridesSetGroup(rule: "9c", group: "Deals"))
        XCTAssertEqual(parse("overrides ungroup 9c").command, .overridesSetGroup(rule: "9c", group: nil))
    }

    func test_netMode_readsOrSetsAWireName() {
        XCTAssertEqual(parse("net mode").command, .netMode(set: nil))
        XCTAssertEqual(parse("net mode mitm").command, .netMode(set: "mitm"))
        XCTAssertEqual(parse("net mode agent --json").command, .netMode(set: "agent"))
        XCTAssertTrue(parse("net mode agent --json").json)
    }

    /// `jaca net mode bogus` is a usage error, which `jaca` exits with status 2.
    func test_netMode_anUnknownModeIsUsage() {
        for line in ["net mode bogus", "net mode MITM", "net mode agent mitm", "net mode --mode mitm"] {
            XCTAssertEqual(parse(line).command, .usage(path: ["net", "mode"]), line)
        }
    }

    func test_netInstallCA_namesACapture() {
        XCTAssertEqual(parse("net install-ca 3fa2").command, .netInstallCA(session: "3fa2"))
        XCTAssertEqual(parse("net install-ca").command, .usage(path: ["net", "install-ca"]))
        XCTAssertEqual(parse("net install-ca a b").command, .usage(path: ["net", "install-ca"]))
    }

    /// A value with spaces arrives as one argument; a name that starts with a dash goes after `--`.
    func test_valuesWithSpacesAndDashes() {
        XCTAssertEqual(CLIParser.parse(["overrides", "enable", "GET users"]).command,
                       .overridesSetEnabled(rule: "GET users", enabled: true))
        XCTAssertEqual(CLIParser.parse(["overrides", "rm", "--", "-odd"]).command, .overridesRemove(rule: "-odd"))
        XCTAssertEqual(CLIParser.parse(["logs", "tail", "--grep", "--weird"], now: now).command,
                       .logsTail(session: nil, grep: "--weird", minLevel: nil, since: nil, count: nil, follow: false))
    }

    // MARK: - Global flags

    func test_globalFlags_areReadAnywhere() {
        let a = parse("--json net requests --raw --no-spawn")
        XCTAssertEqual(a.command, .netRequests(session: nil, host: nil, status: [], method: nil, failed: false, count: nil))
        XCTAssertTrue(a.json && a.raw && a.noSpawn)
        let b = parse("devices")
        XCTAssertFalse(b.json || b.raw || b.noSpawn)
    }

    func test_daemonCommands_passThroughUntouched() {
        XCTAssertEqual(parse("call network.list {} --no-spawn"),
                       CLIInvocation(command: .daemonCommand(["call", "network.list", "{}", "--no-spawn"]), noSpawn: true))
        XCTAssertEqual(parse("status").command, .daemonCommand(["status"]))
        XCTAssertEqual(parse("watch overrides.state").command, .daemonCommand(["watch", "overrides.state"]))
    }

    // MARK: - Help and usage

    func test_help_namesTheDeepestKnownCommand() {
        XCTAssertEqual(parse("--help").command, .help(path: []))
        XCTAssertEqual(parse("help").command, .help(path: []))
        XCTAssertEqual(parse("net --help").command, .help(path: ["net"]))
        XCTAssertEqual(parse("help overrides add").command, .help(path: ["overrides", "add"]))
        XCTAssertEqual(parse("overrides add -h --from x").command, .help(path: ["overrides", "add"]))
        XCTAssertEqual(parse("bogus --help").command, .help(path: []))
    }

    func test_badInput_becomesUsage_neverACrash() {
        let bad: [(String, [String])] = [
            ("", []), ("bogus", []), ("logs", ["logs"]), ("logs bogus", ["logs"]), ("--verbose devices", []),
            ("devices extra", ["devices"]),
            ("logs tail a b", ["logs", "tail"]), ("logs tail -n", ["logs", "tail"]), ("logs tail -n 0", ["logs", "tail"]),
            ("logs tail -n x", ["logs", "tail"]), ("logs tail --level loud", ["logs", "tail"]),
            ("logs tail --since yesterday", ["logs", "tail"]), ("logs tail --grep a --grep b", ["logs", "tail"]),
            ("logs tail --follow=yes", ["logs", "tail"]), ("logs tail --bogus", ["logs", "tail"]),
            ("net requests --status 9xx", ["net", "requests"]), ("net requests --status", ["net", "requests"]),
            ("net show", ["net", "show"]), ("net show a b", ["net", "show"]),
            ("overrides add", ["overrides", "add"]), ("overrides add --from", ["overrides", "add"]),
            ("overrides add --from x --status 99", ["overrides", "add"]), ("overrides add x", ["overrides", "add"]),
            ("overrides enable", ["overrides", "enable"]), ("overrides rm", ["overrides", "rm"]),
            ("overrides generalize", ["overrides", "generalize"]),
            ("overrides enable 9c --group Deals", ["overrides", "enable"]), ("overrides mkgroup", ["overrides", "mkgroup"]),
            ("overrides group 9c", ["overrides", "group"]), ("overrides ungroup", ["overrides", "ungroup"]),
            ("overrides groups x", ["overrides", "groups"]),
        ]
        for (line, path) in bad {
            XCTAssertEqual(parse(line).command, .usage(path: path), line)
        }
    }

    // MARK: - Values

    func test_level_byNameOrLetter() {
        XCTAssertEqual(CLIParser.level("error"), .error)
        XCTAssertEqual(CLIParser.level("WARN"), .warn)
        XCTAssertEqual(CLIParser.level("e"), .error)
        XCTAssertEqual(CLIParser.level("V"), .verbose)
        XCTAssertNil(CLIParser.level("x"))
        XCTAssertNil(CLIParser.level(""))
    }

    func test_time_agesAndDates() {
        XCTAssertEqual(CLIParser.time("30s", now: now), now.addingTimeInterval(-30))
        XCTAssertEqual(CLIParser.time("2h", now: now), now.addingTimeInterval(-7200))
        XCTAssertEqual(CLIParser.time("1d", now: now), now.addingTimeInterval(-86400))
        XCTAssertEqual(CLIParser.time("2026-10-07T09:00:00Z", now: now), DaemonDates.parse("2026-10-07T09:00:00Z"))
        for bad in ["", "m", "5", "-5m", "5w", "1.5h", "soon"] {
            XCTAssertNil(CLIParser.time(bad, now: now), bad)
        }
    }

    func test_statusRanges() {
        XCTAssertEqual(NetworkStatusRange(token: "404"), NetworkStatusRange(min: 404, max: 404))
        XCTAssertEqual(NetworkStatusRange(token: "5XX"), NetworkStatusRange(min: 500, max: 599))
        XCTAssertEqual(NetworkStatusRange(token: "400-499"), NetworkStatusRange(min: 400, max: 499))
        for bad in ["", "40", "4040", "6xx", "0xx", "499-400", "abc", "4x4", "400-", "-"] {
            XCTAssertNil(NetworkStatusRange(token: bad), bad)
        }
        XCTAssertEqual(NetworkStatusRange.parse("404, 5xx")?.count, 2)
        XCTAssertNil(NetworkStatusRange.parse("404,"))
        XCTAssertNil(NetworkStatusRange.parse(""))
    }

    // MARK: - Usage text

    func test_usage_listsTheCommandsUnderAPath() {
        let all = CLIUsage.text(under: [], program: "jaca")
        XCTAssertTrue(all.hasPrefix("usage: jaca devices\n       jaca logs list\n"), all)
        for entry in CLIUsage.entries {
            XCTAssertTrue(all.contains("jaca " + entry.path.joined(separator: " ")), entry.path.joined(separator: " "))
        }
        XCTAssertEqual(CLIUsage.text(under: ["net", "show"], program: "jaca"),
                       "usage: jaca net show REQUEST\n       jaca ... [--json] [--raw] [--no-spawn] [--help]")
        XCTAssertEqual(CLIUsage.text(under: ["net", "mode"], program: "jaca"),
                       "usage: jaca net mode [agent | mitm]\n       jaca ... [--json] [--raw] [--no-spawn] [--help]")
        XCTAssertEqual(CLIUsage.methods(under: ["net", "mode"]), ["network.mode", "network.setMode"])
        XCTAssertEqual(CLIUsage.methods(under: ["net", "install-ca"]), ["network.installCA"])
        XCTAssertEqual(CLIUsage.methods(under: ["overrides"]),
                       ["overrides.state", "overrides.createFromTransaction", "overrides.save",
                        "overrides.setEnabled", "overrides.saveGroup", "overrides.remove",
                        "overrides.removeGroup", "overrides.setGroup"])
    }
}
