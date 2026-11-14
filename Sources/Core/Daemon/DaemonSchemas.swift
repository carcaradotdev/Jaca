import Foundation

/// The wire shapes of the devices, logs, network and overrides areas, for `api.describe`.
/// Written by hand, so `DaemonSchemaTests` encodes a value of
/// each type and fails when it carries a key its schema does not list.
extension DaemonSchema {
    /// `{id}`: the params of every method that acts on one session.
    static let sessionID = DaemonSchema.object(["id": .uuid])

    static let headerPair = DaemonSchema.object(["name": .string, "value": .string])

    // MARK: Devices

    static let device = DaemonSchema.object(["id": .string], optional: [
        "platform": .enumeration(["android", "iosSimulator", "iosDevice", "mac"]),
        "model": .string,
        "state": .enumeration(["connected", "unauthorized", "offline", "booted", "shutdown", "unknown"]),
    ])

    // MARK: Logs

    /// `LogLevel.rawValue`: 0 verbose, 1 debug, 2 info, 3 warn, 4 error, 5 fatal.
    static let logLevel = DaemonSchema.integer

    static let logStreamState = DaemonSchema.object(optional: [
        "isRunning": .boolean, "isConnecting": .boolean, "statusMessage": .string,
        "package": .string, "pids": .array(.integer),
    ])

    static let logSession = DaemonSchema.object(["id": .uuid, "device": .device], optional: [
        "displayName": .string, "state": .logStreamState, "lastSeq": .integer, "existed": .boolean,
    ])

    /// `LogLine` shortens its keys (lines are most of the traffic); `title` is the property.
    static let logLine = DaemonSchema.object(["s": DaemonSchema.integer.titled("seq")], optional: [
        "t": DaemonSchema.number.titled("timestamp"),
        "l": logLevel.titled("level"),
        "g": DaemonSchema.string.titled("tag"),
        "p": DaemonSchema.integer.titled("pid"),
        "i": DaemonSchema.integer.titled("tid"),
        "m": DaemonSchema.string.titled("message"),
        "r": DaemonSchema.string.titled("raw"),
        "n": DaemonSchema.string.titled("processName"),
        "mk": DaemonSchema.boolean.titled("isMarker"),
        "mc": DaemonSchema.boolean.titled("markerCritical"),
        "co": DaemonSchema.boolean.titled("isConsoleOutput"),
        "bc": DaemonSchema.string.titled("bodyCompact"),
    ])

    // MARK: Network

    static let interceptArmingState = DaemonSchema.object(optional: [
        "state": .enumeration(["idle", "waitingForAgent", "agentTooOld", "waitingForApp", "detached", "active", "failed"]),
        "appID": .string, "port": .integer, "hosts": .array(.string), "message": .string,
    ])

    static let networkCaptureState = DaemonSchema.object(optional: [
        "isRunning": .boolean, "isConnecting": .boolean, "statusMessage": .string, "boundPort": .integer,
        "proxyNeedsSetup": .boolean, "caReady": .boolean, "selectedSourceID": .string,
        "hasSelectedMode": .boolean, "targetPackage": .string, "attachState": .interceptArmingState,
        "interceptWired": .boolean, "interceptCapabilities": .integer, "hasRunningSource": .boolean,
        "offeredSourceIDs": .array(.string),
    ])

    /// `network.mode`, the method and the retained topic.
    static let networkMode = DaemonSchema.object(["mode": .enumeration(["agent", "mitm"]), "switching": .boolean])

    static let networkInstallCAResult = DaemonSchema.object(
        ["outcome": .enumeration(["installed", "needsUser", "failed"])],
        optional: ["message": .string, "rebootAdvised": .boolean])

    static let networkSession = DaemonSchema.object(["id": .uuid, "device": .device], optional: [
        "name": .string, "state": .networkCaptureState, "transactionCount": .integer,
    ])

    static let networkStatusRange = DaemonSchema.object(optional: ["min": .integer, "max": .integer])

    static let networkRow = DaemonSchema.object(["id": .uuid, "session": .uuid], optional: [
        "method": .string, "url": .string, "host": .string, "statusCode": .integer, "error": .string,
        "startedAt": .date, "durationMs": .integer, "requestBytes": .integer, "responseBytes": .integer,
        "overriddenByRuleID": .uuid,
    ])

    static let networkTransaction = DaemonSchema.object(["id": .uuid], optional: [
        "method": .string, "url": .string, "host": .string, "scheme": .string,
        "requestHeaders": .array(.headerPair), "requestBody": .bytes,
        "statusCode": .integer, "responseHeaders": .array(.headerPair), "responseBody": .bytes,
        "responseContentType": .string, "startedAt": .date, "responseReceivedAt": .date, "finishedAt": .date,
        "requestBytes": .integer, "responseBytes": .integer, "error": .string, "callStack": .array(.string),
        "bodiesEvicted": .boolean, "overriddenByRuleID": .uuid, "httpStack": .string,
    ])

    // MARK: Overrides

    static let overrideBodyRef = DaemonSchema.oneOf([
        .object(["kind": .enumeration(["none"])]),
        .object(["kind": .enumeration(["inline"]), "text": .string]),
        .object(["kind": .enumeration(["blob"]), "filename": .string]),
        .object(["kind": .enumeration(["file"]), "path": .string], optional: ["watch": .boolean]),
    ])

    static let overrideAction = DaemonSchema.oneOf([
        .object(["kind": .enumeration(["respond"])], optional: [
            "respond": .object(optional: [
                "statusCode": .integer, "headers": .array(.headerPair), "body": .overrideBodyRef,
            ]),
        ]),
        .object(["kind": .enumeration(["editResponse"])], optional: [
            "editResponse": .object(optional: [
                "statusCode": .integer, "headerMode": .enumeration(["merge", "replace"]),
                "headers": .array(.headerPair), "removeHeaders": .array(.string), "body": .overrideBodyRef,
            ]),
        ]),
        .object(["kind": .enumeration(["mapRemote"])], optional: ["mapRemote": .string]),
    ])

    static let overrideRule = DaemonSchema.object(["id": .uuid], optional: [
        "name": .string,
        "enabled": .boolean,
        "matcher": .object(optional: [
            "pattern": .string, "kind": .enumeration(["glob", "regex"]), "methods": .array(.string),
        ]),
        "scope": .object(optional: ["deviceIDs": .array(.string), "appIDs": .array(.string)]),
        "action": .overrideAction,
        "delayMillis": .integer,
        // The key `routedHosts` is saved under.
        "divertHosts": DaemonSchema.array(.string).titled("routedHosts"),
        "createdAt": .date,
        "groupID": .uuid,
    ])

    static let overrideGroup = DaemonSchema.object(["id": .uuid], optional: [
        "name": .string, "enabled": .boolean, "createdAt": .date,
    ])

    static let overridesState = DaemonSchema.object(optional: [
        "rules": .array(.overrideRule),
        "groups": .array(.overrideGroup),
        "masterEnabled": .boolean,
        "hitCounts": .map(.integer),
        "lastHitAt": .map(.date),
        "armings": .array(.object(optional: [
            "target": .object(optional: ["deviceID": .string, "package": .string]),
            "state": .interceptArmingState,
        ])),
        "lastActivity": .string,
        "reclaimedTunnelCount": .integer,
    ])
}
