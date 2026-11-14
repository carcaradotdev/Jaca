import Foundation

/// What `jaca` was asked to do, parsed from its arguments. Pure: `CLIParser` reads no state, so
/// the whole command line is unit-tested without a daemon.
struct CLIInvocation: Equatable {
    var command: CLICommand
    /// `--json`: the result as JSON instead of a table.
    var json = false
    /// `--raw`: `Authorization` and cookie headers as captured.
    var raw = false
    /// `--no-spawn`: fail instead of starting the daemon.
    var noSpawn = false
}

enum CLICommand: Equatable {
    case devices
    case logsList
    case logsTail(session: String?, grep: String?, minLevel: LogLevel?, since: Date?, count: Int?, follow: Bool)
    case netList
    case netRequests(session: String?, host: String?, status: [NetworkStatusRange], method: String?, failed: Bool, count: Int?)
    case netShow(request: String)
    /// `set` nil: print the network inspection mode. Otherwise a wire name, "agent" or "mitm".
    case netMode(set: String?)
    case netInstallCA(session: String)
    case overridesList
    case overridesAdd(from: String, name: String?, statusCode: Int?, bodyFile: String?, disabled: Bool, generalize: Bool)
    case overridesGeneralize(rule: String)
    case overridesSetEnabled(rule: String, enabled: Bool)
    case overridesRemove(rule: String)
    case overridesGroups
    case overridesNewGroup(name: String)
    case overridesRemoveGroup(group: String)
    case overridesSetGroupEnabled(group: String, enabled: Bool)
    /// `group` nil: `ungroup`.
    case overridesSetGroup(rule: String, group: String?)
    /// `--help`: usage, then the daemon methods behind the commands under `path`.
    case help(path: [String])
    /// Arguments that don't parse: usage for the commands under `path`, exit status 2.
    case usage(path: [String])
    /// A `jacad` client command (`call`, `watch`, `status`, `stop`, `describe`), run as `jacad` runs it.
    case daemonCommand([String])
}

/// The commands `jaca` has: their arguments for the usage text and the daemon methods they call.
enum CLIUsage {
    struct Entry: Equatable {
        let path: [String]
        let arguments: String
        /// The daemon methods the command calls, described by `--help`.
        let methods: [String]
    }

    static let entries: [Entry] = [
        Entry(path: ["devices"], arguments: "", methods: ["devices.list"]),
        Entry(path: ["logs", "list"], arguments: "", methods: ["logs.list"]),
        Entry(path: ["logs", "tail"],
              arguments: "[SESSION] [-n COUNT] [--grep PATTERN] [--level LEVEL] [--since TIME] [--follow]",
              methods: ["logs.search"]),
        Entry(path: ["net", "list"], arguments: "", methods: ["network.list"]),
        Entry(path: ["net", "requests"],
              arguments: "[SESSION] [-n COUNT] [--host HOST] [--status STATUS] [--method METHOD] [--failed]",
              methods: ["network.search"]),
        Entry(path: ["net", "show"], arguments: "REQUEST", methods: ["network.transaction"]),
        Entry(path: ["net", "mode"], arguments: "[agent | mitm]", methods: ["network.mode", "network.setMode"]),
        Entry(path: ["net", "install-ca"], arguments: "SESSION", methods: ["network.installCA"]),
        Entry(path: ["overrides", "list"], arguments: "", methods: ["overrides.state"]),
        Entry(path: ["overrides", "add"],
              arguments: "--from REQUEST [--name NAME] [--status CODE] [--body-file PATH] [--disabled] [--generalize]",
              methods: ["overrides.createFromTransaction"]),
        Entry(path: ["overrides", "generalize"], arguments: "RULE", methods: ["overrides.save"]),
        Entry(path: ["overrides", "enable"], arguments: "RULE | --group GROUP",
              methods: ["overrides.setEnabled", "overrides.saveGroup"]),
        Entry(path: ["overrides", "disable"], arguments: "RULE | --group GROUP",
              methods: ["overrides.setEnabled", "overrides.saveGroup"]),
        Entry(path: ["overrides", "rm"], arguments: "RULE", methods: ["overrides.remove"]),
        Entry(path: ["overrides", "groups"], arguments: "", methods: ["overrides.state"]),
        Entry(path: ["overrides", "mkgroup"], arguments: "NAME", methods: ["overrides.saveGroup"]),
        Entry(path: ["overrides", "rmgroup"], arguments: "GROUP", methods: ["overrides.removeGroup"]),
        Entry(path: ["overrides", "group"], arguments: "RULE GROUP", methods: ["overrides.setGroup"]),
        Entry(path: ["overrides", "ungroup"], arguments: "RULE", methods: ["overrides.setGroup"]),
    ]

    /// The `jacad` client commands `jaca` also runs.
    static let daemonCommands: Set<String> = ["call", "watch", "status", "stop", "describe"]

    static func entries(under path: [String]) -> [Entry] {
        entries.filter { $0.path.starts(with: path) }
    }

    /// The methods behind the commands under `path`, each once, in command order.
    static func methods(under path: [String]) -> [String] {
        var seen: Set<String> = []
        return entries(under: path).flatMap(\.methods).filter { seen.insert($0).inserted }
    }

    /// The usage block for the commands under `path` (all of them for `[]`), in the layout of
    /// `jacad`'s: `usage:` on the first line, the rest aligned under it.
    static func text(under path: [String], program: String) -> String {
        var lines = entries(under: path).map { entry in
            ([program] + entry.path + (entry.arguments.isEmpty ? [] : [entry.arguments])).joined(separator: " ")
        }
        if path.isEmpty {
            lines += [
                "\(program) call METHOD [PARAMS_JSON]",
                "\(program) watch TOPIC...",
                "\(program) status | stop | describe",
            ]
        }
        lines.append("\(program) ... [--json] [--raw] [--no-spawn] [--help]")
        return lines.enumerated().map { ($0.offset == 0 ? "usage: " : "       ") + $0.element }.joined(separator: "\n")
    }
}

enum CLIParser {
    /// Never fails: arguments that don't parse become `.usage`. `now` anchors `--since 5m`.
    static func parse(_ arguments: [String], now: Date = Date()) -> CLIInvocation {
        if let first = arguments.first, CLIUsage.daemonCommands.contains(first) {
            return CLIInvocation(command: .daemonCommand(arguments), noSpawn: arguments.contains("--no-spawn"))
        }
        var invocation = CLIInvocation(command: .usage(path: []))
        var help = false
        var rest: [String] = []
        var literal = false
        for argument in arguments {
            if literal { rest.append(argument); continue }
            switch argument {
            case "--": literal = true; rest.append(argument)
            case "--json": invocation.json = true
            case "--raw": invocation.raw = true
            case "--no-spawn": invocation.noSpawn = true
            case "--help", "-h": help = true
            default: rest.append(argument)
            }
        }
        if rest.first == "help" {
            help = true
            rest.removeFirst()
        }
        // The command is the leading words that name one: `logs tail`, `devices`.
        let words = Array(rest.prefix { !$0.hasPrefix("-") }.prefix(2))
        let entry = CLIUsage.entries.first { words.starts(with: $0.path) }
        // The deepest known prefix, so `jaca logs bogus` shows the `logs` commands.
        let group = Array(words.prefix(1))
        let known = entry?.path ?? (CLIUsage.entries(under: group).isEmpty ? [] : group)
        if help {
            invocation.command = .help(path: known)
            return invocation
        }
        guard let entry else {
            invocation.command = .usage(path: known)
            return invocation
        }
        invocation.command = command(entry.path, Array(rest.dropFirst(entry.path.count)), now: now) ?? .usage(path: entry.path)
        return invocation
    }

    // MARK: - Commands

    private static func command(_ path: [String], _ arguments: [String], now: Date) -> CLICommand? {
        switch path {
        case ["devices"]:
            guard scan(arguments, positionals: 0) != nil else { return nil }
            return .devices
        case ["logs", "list"]:
            guard scan(arguments, positionals: 0) != nil else { return nil }
            return .logsList
        case ["logs", "tail"]:
            guard let a = scan(arguments, valued: ["-n", "--grep", "--level", "--since"], flags: ["--follow", "-f"], positionals: 1),
                  let count = positive(a.values["-n"]) else { return nil }
            var minLevel: LogLevel?
            if let text = a.values["--level"] {
                guard let parsed = level(text) else { return nil }
                minLevel = parsed
            }
            var since: Date?
            if let text = a.values["--since"] {
                guard let parsed = time(text, now: now) else { return nil }
                since = parsed
            }
            return .logsTail(session: a.positionals.first, grep: a.values["--grep"], minLevel: minLevel, since: since,
                             count: count, follow: !a.flags.isDisjoint(with: ["--follow", "-f"]))
        case ["net", "list"]:
            guard scan(arguments, positionals: 0) != nil else { return nil }
            return .netList
        case ["net", "requests"]:
            guard let a = scan(arguments, valued: ["-n", "--host", "--status", "--method"], flags: ["--failed"], positionals: 1),
                  let count = positive(a.values["-n"]) else { return nil }
            var status: [NetworkStatusRange] = []
            if let text = a.values["--status"] {
                guard let parsed = NetworkStatusRange.parse(text) else { return nil }
                status = parsed
            }
            return .netRequests(session: a.positionals.first, host: a.values["--host"], status: status,
                                method: a.values["--method"], failed: a.flags.contains("--failed"), count: count)
        case ["net", "show"]:
            guard let a = scan(arguments, positionals: 1), let request = a.positionals.first else { return nil }
            return .netShow(request: request)
        case ["net", "mode"]:
            guard let a = scan(arguments, positionals: 1) else { return nil }
            guard let mode = a.positionals.first else { return .netMode(set: nil) }
            guard NetworkInspectionMode(wireName: mode) != nil else { return nil }
            return .netMode(set: mode)
        case ["net", "install-ca"]:
            guard let a = scan(arguments, positionals: 1), let session = a.positionals.first else { return nil }
            return .netInstallCA(session: session)
        case ["overrides", "list"]:
            guard scan(arguments, positionals: 0) != nil else { return nil }
            return .overridesList
        case ["overrides", "add"]:
            guard let a = scan(arguments, valued: ["--from", "--name", "--status", "--body-file"],
                               flags: ["--disabled", "--generalize"], positionals: 0),
                  let from = a.values["--from"], !from.isEmpty else { return nil }
            var statusCode: Int?
            if let text = a.values["--status"] {
                guard let code = Int(text), (100...599).contains(code) else { return nil }
                statusCode = code
            }
            return .overridesAdd(from: from, name: a.values["--name"], statusCode: statusCode,
                                 bodyFile: a.values["--body-file"], disabled: a.flags.contains("--disabled"),
                                 generalize: a.flags.contains("--generalize"))
        case ["overrides", "generalize"]:
            guard let a = scan(arguments, positionals: 1), let rule = a.positionals.first else { return nil }
            return .overridesGeneralize(rule: rule)
        case ["overrides", "enable"], ["overrides", "disable"]:
            let enabled = path[1] == "enable"
            guard let a = scan(arguments, valued: ["--group"], positionals: 1) else { return nil }
            switch (a.positionals.first, a.values["--group"]) {
            case (let rule?, nil): return .overridesSetEnabled(rule: rule, enabled: enabled)
            case (nil, let group?): return .overridesSetGroupEnabled(group: group, enabled: enabled)
            default: return nil
            }
        case ["overrides", "groups"]:
            guard scan(arguments, positionals: 0) != nil else { return nil }
            return .overridesGroups
        case ["overrides", "mkgroup"]:
            guard let a = scan(arguments, positionals: 1), let name = a.positionals.first,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .overridesNewGroup(name: name)
        case ["overrides", "rmgroup"]:
            guard let a = scan(arguments, positionals: 1), let group = a.positionals.first else { return nil }
            return .overridesRemoveGroup(group: group)
        case ["overrides", "group"]:
            guard let a = scan(arguments, positionals: 2), a.positionals.count == 2 else { return nil }
            return .overridesSetGroup(rule: a.positionals[0], group: a.positionals[1])
        case ["overrides", "ungroup"]:
            guard let a = scan(arguments, positionals: 1), let rule = a.positionals.first else { return nil }
            return .overridesSetGroup(rule: rule, group: nil)
        case ["overrides", "rm"]:
            guard let a = scan(arguments, positionals: 1), let rule = a.positionals.first else { return nil }
            return .overridesRemove(rule: rule)
        default:
            return nil
        }
    }

    // MARK: - Values

    /// A level by name (`error`, any case) or by its logcat letter (`E`).
    static func level(_ text: String) -> LogLevel? {
        if let named = LogLevel.allCases.first(where: { String(describing: $0).caseInsensitiveCompare(text) == .orderedSame }) {
            return named
        }
        guard text.count == 1, let letter = text.uppercased().first else { return nil }
        return LogLevel(threadtimeChar: letter)
    }

    /// A moment: an age (`30s`, `5m`, `2h`, `1d`, counted back from `now`) or an ISO-8601 date.
    static func time(_ text: String, now: Date) -> Date? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last.flatMap({ units[$0] }), let amount = Int(text.dropLast()), amount >= 0,
           text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
            return now.addingTimeInterval(-TimeInterval(amount) * unit)
        }
        return DaemonDates.parse(text)
    }

    /// `-n`: absent is fine (`.some(nil)`); present must be a positive number (nil otherwise).
    private static func positive(_ text: String?) -> Int?? {
        guard let text else { return .some(nil) }
        guard let count = Int(text), count > 0 else { return nil }
        return count
    }

    // MARK: - Scanning

    private struct Scanned {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
    }

    /// Splits a command's arguments into options and positionals. nil for an unknown option, an
    /// option without its value, an option given twice, or more positionals than `positionals`.
    /// `--name=value` and `--name value` are the same; everything after `--` is positional.
    private static func scan(_ arguments: [String], valued: Set<String> = [], flags: Set<String> = [],
                             positionals limit: Int) -> Scanned? {
        var scanned = Scanned()
        var literal = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if literal || !argument.hasPrefix("-") || argument == "-" {
                scanned.positionals.append(argument)
                continue
            }
            if argument == "--" { literal = true; continue }
            var name = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }
            if flags.contains(name), inline == nil {
                scanned.flags.insert(name)
            } else if valued.contains(name), scanned.values[name] == nil {
                if let inline {
                    scanned.values[name] = inline
                } else if index < arguments.count {
                    scanned.values[name] = arguments[index]
                    index += 1
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return scanned.positionals.count <= limit ? scanned : nil
    }
}
