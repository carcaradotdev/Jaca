import Foundation

// What `jaca` prints. Each type is one command's `--json` shape (its property names are the
// stable field names) and knows its row for the default table, whose columns carry those names.

// MARK: - Picking by prefix or name

/// What a session, request or rule argument picked.
enum CLIMatch<T> {
    case one(T)
    case none
    /// More than one candidate fits; the caller lists them.
    case many([T])
}

enum CLIResolver {
    /// Picks the candidate `input` names: its whole id, the start of its id, or one of its names
    /// (ids and names compare case-insensitively). An empty `input` picks the only candidate.
    static func resolve<T>(_ input: String, in candidates: [T], id: (T) -> String, names: (T) -> [String] = { _ in [] }) -> CLIMatch<T> {
        let wanted = input.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.isEmpty {
            return candidates.count == 1 ? .one(candidates[0]) : (candidates.isEmpty ? .none : .many(candidates))
        }
        // A whole id wins even when it also starts another candidate's name.
        if let exact = candidates.first(where: { id($0).lowercased() == wanted }) { return .one(exact) }
        let fitting = candidates.filter { candidate in
            id(candidate).lowercased().hasPrefix(wanted) || names(candidate).contains { !$0.isEmpty && $0.lowercased() == wanted }
        }
        switch fitting.count {
        case 0: return .none
        case 1: return .one(fitting[0])
        default: return .many(fitting)
        }
    }
}

// MARK: - Redaction

enum CLIRedaction {
    /// Headers that carry credentials.
    static let sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie"]

    /// What stands in for a redacted value.
    static let placeholder = ""

    struct Header: Encodable, Equatable {
        var name: String
        var value: String
        /// True when `value` was removed (see `sensitive`).
        var redacted: Bool
    }

    static func isSensitive(_ name: String) -> Bool { sensitive.contains(name.lowercased()) }

    /// `headers` with the values of credential headers removed, unless `raw`.
    static func headers(_ headers: [HeaderPair], raw: Bool) -> [Header] {
        headers.map { header in
            let redact = !raw && isSensitive(header.name)
            return Header(name: header.name, value: redact ? placeholder : header.value, redacted: redact)
        }
    }
}

// MARK: - Tables

enum CLITable {
    /// Left-aligned columns padded to their widest cell, two spaces apart, with no trailing
    /// spaces. A cell's newlines and tabs become spaces so a row stays one line.
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let table = ([header] + rows).map { $0.map(flat) }
        var widths = [Int](repeating: 0, count: header.count)
        for row in table {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) }
        }
        return table.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 || i >= widths.count ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func flat(_ cell: String) -> String {
        cell.contains(where: \.isNewline) || cell.contains("\t")
            ? String(cell.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            : cell
    }

    /// The start of an id, enough to tell rows apart and to pass back as an argument.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func cell(_ value: Int?) -> String { value.map(String.init) ?? "" }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// A row of a `jaca` table.
protocol CLIRow: Encodable {
    static var header: [String] { get }
    var cells: [String] { get }
}

// MARK: - Rows

extension Device: CLIRow {
    static let header = ["id", "platform", "state", "model"]
    var cells: [String] { [id, platform.rawValue, state.rawValue, model] }
}

struct CLILogSession: CLIRow, Equatable {
    var id: UUID
    var name: String
    var deviceID: String
    var platform: String
    var package: String
    var isRunning: Bool
    var statusMessage: String?
    var lastSeq: UInt64?

    init(_ info: LogsArea.SessionInfo) {
        id = info.id
        name = info.displayName
        deviceID = info.device.id
        platform = info.device.platform.rawValue
        package = info.state.package
        isRunning = info.state.isRunning
        statusMessage = info.state.statusMessage
        lastSeq = info.lastSeq
    }

    static let header = ["id", "name", "deviceID", "package", "isRunning", "lastSeq", "statusMessage"]
    var cells: [String] {
        [CLITable.short(id), name, deviceID, package, String(isRunning), lastSeq.map { String($0) } ?? "", statusMessage ?? ""]
    }
}

struct CLILogLine: Encodable, Equatable {
    var seq: UInt64
    var timestamp: Date
    /// `verbose`, `debug`, `info`, `warn`, `error` or `fatal`.
    var level: String
    var tag: String
    var pid: Int32
    var process: String?
    var message: String
    /// A line Jaca added (the app died, the stream reconnected).
    var marker: Bool

    init(_ line: LogLine) {
        seq = line.seq
        timestamp = line.timestamp
        level = String(describing: line.level)
        tag = line.tag
        pid = line.pid
        process = line.processName
        message = line.message
        marker = line.isMarker
    }
}

struct CLINetworkSession: CLIRow, Equatable {
    var id: UUID
    var name: String
    var deviceID: String
    var platform: String
    var package: String?
    var sourceID: String?
    var isRunning: Bool
    var statusMessage: String?
    var transactionCount: Int

    init(_ session: NetworkArea.Session) {
        id = session.id
        name = session.name
        deviceID = session.device.id
        platform = session.device.platform.rawValue
        package = session.state.targetPackage
        sourceID = session.state.selectedSourceID
        isRunning = session.state.isRunning
        statusMessage = session.state.statusMessage
        transactionCount = session.transactionCount
    }

    static let header = ["id", "name", "deviceID", "package", "isRunning", "transactionCount", "statusMessage"]
    var cells: [String] {
        [CLITable.short(id), name, deviceID, package ?? "", String(isRunning), String(transactionCount), statusMessage ?? ""]
    }
}

extension NetworkArea.Row: CLIRow {
    static let header = ["id", "startedAt", "method", "statusCode", "durationMs", "responseBytes", "url", "error"]
    var cells: [String] {
        [CLITable.short(id), CLITable.time(startedAt), method, CLITable.cell(statusCode), CLITable.cell(durationMs),
         String(responseBytes), url, error ?? ""]
    }
}

/// `jaca net mode`.
struct CLINetworkMode: CLIRow, Equatable {
    /// The wire name: "agent" or "mitm".
    var mode: String

    init(_ state: NetworkModeController.State) { mode = state.mode }

    static let header = ["mode"]
    var cells: [String] { [mode] }
}

/// `jaca net install-ca`: the `network.installCA` result as the daemon returns it.
extension NetworkArea.InstallCAResult: CLIRow {
    static let header = ["outcome", "rebootAdvised", "message"]
    var cells: [String] { [outcome.rawValue, rebootAdvised.map { String($0) } ?? "", message ?? ""] }
}

/// One request in full, for `jaca net show`.
struct CLIRequest: Encodable, Equatable {
    var id: UUID
    var session: UUID
    var method: String
    var url: String
    var statusCode: Int?
    var error: String?
    var startedAt: Date
    var durationMs: Int?
    var overriddenByRuleID: UUID?
    var requestHeaders: [CLIRedaction.Header]
    /// The body as text. A body that isn't UTF-8 is in `requestBodyBase64` instead.
    var requestBody: String?
    var requestBodyBase64: String?
    var responseHeaders: [CLIRedaction.Header]
    var responseBody: String?
    var responseBodyBase64: String?
    var callStack: [String]?

    init(_ txn: NetworkTransaction, session: UUID, raw: Bool) {
        id = txn.id
        self.session = session
        method = txn.method
        url = txn.url
        statusCode = txn.statusCode
        error = txn.error
        startedAt = txn.startedAt
        durationMs = txn.duration.map { Int(($0 * 1000).rounded()) }
        overriddenByRuleID = txn.overriddenByRuleID
        requestHeaders = CLIRedaction.headers(txn.displayRequestHeaders, raw: raw)
        responseHeaders = CLIRedaction.headers(txn.displayResponseHeaders, raw: raw)
        callStack = txn.callStack
        (requestBody, requestBodyBase64) = Self.body(txn.requestBody)
        (responseBody, responseBodyBase64) = Self.body(txn.responseBody)
    }

    private static func body(_ data: Data?) -> (text: String?, base64: String?) {
        guard let data, !data.isEmpty else { return (nil, nil) }
        if let text = String(data: data, encoding: .utf8) { return (text, nil) }
        return (nil, data.base64EncodedString())
    }

    /// `field: value` lines, then each header list and body under its field name.
    var text: String {
        var lines = ["id: \(id.uuidString)", "session: \(session.uuidString)", "method: \(method)", "url: \(url)"]
        if let statusCode { lines.append("statusCode: \(statusCode)") }
        if let error { lines.append("error: \(error)") }
        lines.append("startedAt: \(DaemonDates.format(startedAt))")
        if let durationMs { lines.append("durationMs: \(durationMs)") }
        if let overriddenByRuleID { lines.append("overriddenByRuleID: \(overriddenByRuleID.uuidString)") }
        func section(_ name: String, _ body: [String]) {
            guard !body.isEmpty else { return }
            lines.append("")
            lines.append("\(name):")
            lines.append(contentsOf: body)
        }
        func headers(_ list: [CLIRedaction.Header]) -> [String] { list.map { "\($0.name): \($0.value)" } }
        section("requestHeaders", headers(requestHeaders))
        section("requestBody", requestBody.map { [$0] } ?? [])
        section("requestBodyBase64", requestBodyBase64.map { [$0] } ?? [])
        section("responseHeaders", headers(responseHeaders))
        section("responseBody", responseBody.map { [$0] } ?? [])
        section("responseBodyBase64", responseBodyBase64.map { [$0] } ?? [])
        section("callStack", callStack ?? [])
        return lines.joined(separator: "\n")
    }
}

struct CLIRule: CLIRow, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var pattern: String
    var methods: [String]
    /// `respond`, `editResponse` or `mapRemote`.
    var action: String
    /// The status the rule answers with, when it sets one.
    var statusCode: Int?
    var hitCount: Int
    /// The name of the group the rule is in.
    var group: String?
    /// The rule as the daemon holds it.
    var rule: OverrideRule

    init(_ rule: OverrideRule, hitCount: Int, group: OverrideGroup? = nil) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        pattern = rule.matcher.pattern
        methods = rule.matcher.methods.sorted()
        switch rule.action {
        case .respond(let spec):
            action = "respond"
            statusCode = spec.statusCode
        case .editResponse(let edit):
            action = "editResponse"
            statusCode = edit.statusCode
        case .mapRemote:
            action = "mapRemote"
        }
        self.hitCount = hitCount
        self.group = group?.name
        self.rule = rule
    }

    static let header = ["id", "enabled", "hitCount", "action", "statusCode", "methods", "group", "pattern", "name"]
    var cells: [String] {
        [CLITable.short(id), String(enabled), String(hitCount), action, CLITable.cell(statusCode),
         methods.joined(separator: ","), group ?? "", pattern, name]
    }
}

struct CLIGroup: CLIRow, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    /// How many rules are in the group.
    var rules: Int

    init(_ group: OverrideGroup, rules: Int) {
        id = group.id
        name = group.name
        enabled = group.enabled
        self.rules = rules
    }

    static let header = ["id", "enabled", "rules", "name"]
    var cells: [String] { [CLITable.short(id), String(enabled), String(rules), name] }
}

struct CLIOverrides: Encodable, Equatable {
    var masterEnabled: Bool
    var groups: [CLIGroup]
    var rules: [CLIRule]

    init(_ state: OverridesState) {
        masterEnabled = state.masterEnabled
        groups = OverrideGrouping.sections(state.rules, groups: state.groups).compactMap { section in
            section.group.map { CLIGroup($0, rules: section.rules.count) }
        }
        rules = state.rules.map {
            CLIRule($0, hitCount: state.hitCounts[$0.id.uuidString] ?? 0,
                    group: OverrideGrouping.group(of: $0, in: state.groups))
        }
    }
}
