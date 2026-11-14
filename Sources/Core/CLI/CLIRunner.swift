import Foundation

/// Runs one `jaca` command against a connected daemon. Output goes through `out` and `err` (one
/// call per line or block), so tests run commands against an in-process daemon and read what
/// was printed. Never throws and never exits: `run` returns the exit status.
struct CLIRunner {
    let client: DaemonClient
    var program = "jaca"
    var json = false
    var raw = false
    var out: (String) -> Void
    var err: (String) -> Void
    /// Reads `--body-file` (`-` is standard input).
    var readFile: (String) throws -> Data = { path in
        path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// How many candidates a request prefix is checked against: enough to list an ambiguous one.
    static let requestCandidates = 50

    func run(_ command: CLICommand) async -> Int32 {
        do {
            return try await perform(command)
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    private func perform(_ command: CLICommand) async throws -> Int32 {
        switch command {
        case .devices:
            let devices: [Device] = try await client.call("devices.list")
            printRows(devices)
            return 0

        case .logsList:
            printRows(try await logSessions().map(CLILogSession.init))
            return 0

        case .logsTail(let session, let grep, let minLevel, let since, let count, let follow):
            let sessions = try await logSessions()
            guard let picked = pick(session ?? "", from: sessions, id: \.id.uuidString,
                                    names: { [$0.displayName, $0.device.id] }, rows: { $0.map(CLILogSession.init) },
                                    missing: { "No log session \($0)." }) else { return 1 }
            return try await tail(picked.id, search: LogSearch(pattern: grep ?? "", minLevel: minLevel ?? .verbose, since: since),
                                  count: count, follow: follow)

        case .netList:
            printRows(try await networkSessions().map(CLINetworkSession.init))
            return 0

        case .netRequests(let session, let host, let status, let method, let failed, let count):
            var id: UUID?
            if let session {
                guard let picked = pickNetworkSession(session, from: try await networkSessions()) else { return 1 }
                id = picked.id
            }
            let params = NetworkArea.SearchParams(id: id, host: host, method: method, status: status.isEmpty ? nil : status,
                                                  failed: failed ? true : nil, idPrefix: nil, limit: count)
            printRows(try await client.call("network.search", params, as: [NetworkArea.Row].self))
            return 0

        case .netShow(let request):
            guard let row = try await pickRequest(request),
                  let txn = try await transaction(row) else { return 1 }
            let detail = CLIRequest(txn, session: row.session, raw: raw)
            json ? printJSON(detail) : out(detail.text)
            return 0

        case .netMode(let set):
            if let set {
                let _: RPCEmpty = try await client.call("network.setMode", NetworkArea.SetModeParams(mode: set))
            }
            // As the daemon holds it now.
            let state: NetworkModeController.State = try await client.call("network.mode")
            let mode = CLINetworkMode(state)
            json ? printJSON(mode) : printRows([mode])
            return 0

        case .netInstallCA(let session):
            guard let picked = pickNetworkSession(session, from: try await networkSessions()) else { return 1 }
            let result = try await client.call("network.installCA", NetworkArea.IDParams(id: picked.id),
                                               as: NetworkArea.InstallCAResult.self)
            json ? printJSON(result) : printRows([result])
            return result.outcome == .failed ? 1 : 0

        case .overridesList:
            let overrides = CLIOverrides(try await overridesState())
            if json {
                printJSON(overrides)
            } else {
                out("masterEnabled: \(overrides.masterEnabled)")
                out(CLITable.render(CLIRule.header, overrides.rules.map(\.cells)))
            }
            return 0

        case .overridesAdd(let from, let name, let statusCode, let bodyFile, let disabled, let generalize):
            let body = try bodyFile.map(readFile)
            guard let row = try await pickRequest(from) else { return 1 }
            let params = OverridesArea.FromTransactionParams(id: row.session, transaction: row.id, name: name,
                                                             statusCode: statusCode, body: body, enabled: disabled ? false : nil,
                                                             anyBaseURL: generalize ? true : nil)
            guard let created = try await client.call("overrides.createFromTransaction", params, as: OverridesArea.Created?.self) else {
                // The capture closed or was cleared after the request was found.
                printRows([NetworkArea.Row](), to: err)
                return 1
            }
            if let warning = created.warning { fail(warning) }
            printRows([CLIRule(created.rule, hitCount: 0)])
            return 0

        case .overridesGeneralize(let rule):
            guard let picked = pickRule(rule, from: try await overridesState()) else { return 1 }
            let rewritten = OverrideSeeding.onAnyBaseURL(picked.rule)
            let _: RPCEmpty = try await client.call("overrides.save", OverridesArea.RuleParams(rule: rewritten))
            // As the daemon holds it now.
            let rules = CLIOverrides(try await overridesState()).rules
            printRows(rules.filter { $0.id == picked.id })
            return 0

        case .overridesSetEnabled(let rule, let enabled):
            guard let picked = pickRule(rule, from: try await overridesState()) else { return 1 }
            let _: RPCEmpty = try await client.call("overrides.setEnabled", OverridesArea.EnabledParams(id: picked.id, enabled: enabled))
            // As the daemon holds it now.
            let rules = CLIOverrides(try await overridesState()).rules
            printRows(rules.filter { $0.id == picked.id })
            return 0

        case .overridesRemove(let rule):
            guard let picked = pickRule(rule, from: try await overridesState()) else { return 1 }
            let _: RPCEmpty = try await client.call("overrides.remove", OverridesArea.IDParams(id: picked.id))
            printRows([picked])
            return 0

        case .overridesGroups:
            printRows(CLIOverrides(try await overridesState()).groups)
            return 0

        case .overridesNewGroup(let name):
            let group = OverrideGroup(name: name)
            let _: RPCEmpty = try await client.call("overrides.saveGroup", OverridesArea.GroupParams(group: group))
            // As the daemon holds it now.
            printRows(CLIOverrides(try await overridesState()).groups.filter { $0.id == group.id })
            return 0

        case .overridesRemoveGroup(let group):
            let state = try await overridesState()
            guard let picked = pickGroup(group, from: state) else { return 1 }
            let _: RPCEmpty = try await client.call("overrides.removeGroup", OverridesArea.IDParams(id: picked.id))
            printRows([picked])
            return 0

        case .overridesSetGroupEnabled(let group, let enabled):
            let state = try await overridesState()
            guard let picked = pickGroup(group, from: state),
                  var saved = state.groups.first(where: { $0.id == picked.id }) else { return 1 }
            saved.enabled = enabled
            let _: RPCEmpty = try await client.call("overrides.saveGroup", OverridesArea.GroupParams(group: saved))
            printRows(CLIOverrides(try await overridesState()).groups.filter { $0.id == picked.id })
            return 0

        case .overridesSetGroup(let rule, let group):
            let state = try await overridesState()
            guard let pickedRule = pickRule(rule, from: state) else { return 1 }
            var groupID: UUID?
            if let group {
                guard let picked = pickGroup(group, from: state) else { return 1 }
                groupID = picked.id
            }
            let _: RPCEmpty = try await client.call("overrides.setGroup", OverridesArea.SetGroupParams(id: pickedRule.id, group: groupID))
            printRows(CLIOverrides(try await overridesState()).rules.filter { $0.id == pickedRule.id })
            return 0

        case .help(let path):
            return try await describe(CLIUsage.methods(under: path))

        case .usage, .daemonCommand:
            // Handled before a daemon is involved (`Sources/Daemon/main.swift`).
            return 2
        }
    }

    // MARK: - Logs

    private func tail(_ id: UUID, search: LogSearch, count: Int?, follow: Bool) async throws -> Int32 {
        // Subscribed before the search so no line falls between the two; `seq` drops the overlap.
        let live = follow ? try await client.subscribe([LogsArea.linesTopic(id)]) : nil
        let params = LogsArea.SearchParams(id: id, grep: search.pattern.isEmpty ? nil : search.pattern,
                                           minLevel: search.minLevel, since: search.since, limit: count)
        let lines = try await client.call("logs.search", params, as: [LogLine].self)
        guard let live else {
            json ? printJSON(lines.map(CLILogLine.init)) : lines.forEach(printLine)
            return 0
        }
        // Following prints a line at a time in both modes: JSON is one object per line.
        lines.forEach(printLine)
        var lastSeq = lines.last?.seq
        for await event in live {
            guard let batch = try? event.decode([LogLine].self) else { continue }
            for line in batch where search.matches(line) && lastSeq.map({ line.seq > $0 }) != false {
                printLine(line)
                lastSeq = line.seq
            }
        }
        // The stream ends when the connection does.
        throw RPCError.disconnected
    }

    private func printLine(_ line: LogLine) {
        json ? printJSON(CLILogLine(line)) : out(LogCopyFormat.default.render(line.copyFields))
    }

    // MARK: - Lookups

    private func logSessions() async throws -> [LogsArea.SessionInfo] { try await client.call("logs.list") }
    private func networkSessions() async throws -> [NetworkArea.Session] { try await client.call("network.list") }
    private func overridesState() async throws -> OverridesState { try await client.call("overrides.state") }

    private func pickNetworkSession(_ input: String, from sessions: [NetworkArea.Session]) -> NetworkArea.Session? {
        pick(input, from: sessions, id: \.id.uuidString,
             names: { [$0.name, $0.device.id, $0.state.targetPackage ?? ""] }, rows: { $0.map(CLINetworkSession.init) },
             missing: { "No network capture \($0)." })
    }

    private func pickRule(_ input: String, from state: OverridesState) -> CLIRule? {
        pick(input, from: CLIOverrides(state).rules, id: \.id.uuidString, names: { [$0.name] }, rows: { $0 }, missing: nil)
    }

    private func pickGroup(_ input: String, from state: OverridesState) -> CLIGroup? {
        pick(input, from: CLIOverrides(state).groups, id: \.id.uuidString, names: { [$0.name] }, rows: { $0 }, missing: nil)
    }

    /// The request whose id starts with `input`, looked up in every open capture.
    private func pickRequest(_ input: String) async throws -> NetworkArea.Row? {
        // An empty prefix would pick "the only request"; a request is always named.
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            printRows([NetworkArea.Row](), to: err)
            return nil
        }
        let params = NetworkArea.SearchParams(id: nil, host: nil, method: nil, status: nil, failed: nil,
                                              idPrefix: input, limit: Self.requestCandidates)
        let rows = try await client.call("network.search", params, as: [NetworkArea.Row].self)
        return pick(input, from: rows, id: \.id.uuidString, names: { _ in [] }, rows: { $0 }, missing: nil)
    }

    private func transaction(_ row: NetworkArea.Row) async throws -> NetworkTransaction? {
        let found = try await client.call("network.transaction", NetworkArea.BodyParams(id: row.session, transaction: row.id),
                                          as: NetworkTransaction?.self)
        // Cleared or closed since the search: nothing fits any more.
        if found == nil { printRows([NetworkArea.Row](), to: err) }
        return found
    }

    /// The one candidate `input` names. Otherwise reports on `err` and returns nil: `missing`'s
    /// message when nothing fits and there is one, else the candidates that fit (none, or the
    /// several an ambiguous `input` could mean), as the command's own table.
    private func pick<T, Row: CLIRow>(_ input: String, from candidates: [T], id: (T) -> String, names: (T) -> [String],
                                      rows: ([T]) -> [Row], missing: ((String) -> String)?) -> T? {
        switch CLIResolver.resolve(input, in: candidates, id: id, names: names) {
        case .one(let found):
            return found
        case .none:
            if let missing, !input.isEmpty { fail(missing(input)) } else { printRows(rows([]), to: err) }
        case .many(let fitting):
            printRows(rows(fitting), to: err)
        }
        return nil
    }

    // MARK: - Help

    /// Prints each method's summary and the shapes of its params and result, from `api.describe`.
    private func describe(_ methods: [String]) async throws -> Int32 {
        let catalog: DaemonServer.Catalog = try await client.call("api.describe")
        let described = methods.compactMap { name in catalog.methods.first { $0.name == name } }
        if json {
            printJSON(described)
            return 0
        }
        for method in described {
            out("")
            out(method.summary.isEmpty ? method.name : "\(method.name)  \(method.summary)")
            for (label, schema) in [("params", method.params), ("result", method.result)] {
                guard let schema else { continue }
                let lines = schema.rendered(indent: 2)
                out(lines.isEmpty ? "  \(label): \(schema.summary)" : "  \(label): \(schema.summary)\n" + lines.joined(separator: "\n"))
            }
        }
        return 0
    }

    // MARK: - Printing

    private func fail(_ message: String) { err("\(program): \(message)") }

    private func printRows<Row: CLIRow>(_ rows: [Row], to sink: ((String) -> Void)? = nil) {
        let sink = sink ?? out
        if json {
            printJSON(rows, to: sink)
        } else {
            sink(CLITable.render(Row.header, rows.map(\.cells)))
        }
    }

    private func printJSON<T: Encodable>(_ value: T, to sink: ((String) -> Void)? = nil) {
        guard let data = try? JSONEncoder.daemon.encode(value), let text = String(data: data, encoding: .utf8) else { return }
        (sink ?? out)(text)
    }
}
