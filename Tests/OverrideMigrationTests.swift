import XCTest
@testable import Jaca

/// Guards the override library against the data-loss trap CLAUDE.md documents: Swift's synthesized
/// `Codable` ignores default values for missing keys, so a new field would make every existing
/// `rules.json` throw `keyNotFound` — and the next save would overwrite the user's rules with
/// nothing. Every model in `OverrideRule.swift` therefore has a tolerant `init(from:)`, and these
/// tests are what keep it that way.
final class OverrideMigrationTests: XCTestCase {

    private let id = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    /// The regression that matters: a rules.json written before `divertHosts`/`scope`/`delayMillis`
    /// existed must still load, with those fields defaulted rather than the record dropped.
    func test_decodeOldSchemaMissingNewerFields_defaultsRatherThanDropping() {
        let old = """
        [{"id":"\(id)","name":"Stub","enabled":true,
          "matcher":{"pattern":"https://a.com/**","kind":"glob"},
          "action":{"kind":"respond","respond":{"statusCode":200}}}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(old.utf8))

        XCTAssertEqual(rules.count, 1, "the record must survive, not be skipped")
        XCTAssertEqual(rules[0].name, "Stub")
        XCTAssertEqual(rules[0].divertHosts, [])
        XCTAssertEqual(rules[0].scope, OverrideScope())
        XCTAssertEqual(rules[0].delayMillis, 0)
        XCTAssertEqual(rules[0].matcher.methods, [])
    }

    /// A rule with nothing but an id must load, and must come back **enabled** — the product
    /// requirement that a new rule is on by default is also the decode default.
    func test_minimalRecordLoadsAndIsEnabled() {
        let json = """
        [{"id":"\(id)"}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].enabled)
        XCTAssertEqual(rules[0].matcher.pattern, "")
        if case .respond = rules[0].action {} else { XCTFail("expected .respond default") }
    }

    /// A file written by a *newer* Jaca carrying keys this build doesn't know must still load.
    func test_unknownFutureKeysAreIgnored() {
        let json = """
        [{"id":"\(id)","name":"Future","enabled":false,
          "somethingAddedLater":{"nested":true},"anotherNewField":[1,2,3]}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].name, "Future")
        XCTAssertFalse(rules[0].enabled)
    }

    /// One unreadable record must not wipe the library.
    func test_oneCorruptRecordIsSkippedWithoutLosingTheRest() {
        let json = """
        [{"id":"\(id)","name":"Good"},
         {"noIdAtAll":true},
         {"id":"11111111-2222-3333-4444-555555555555","name":"AlsoGood"}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.map(\.name), ["Good", "AlsoGood"])
    }

    /// An action kind from a newer release degrades to a safe default instead of throwing.
    func test_unknownActionKindFallsBackToRespond() {
        let json = """
        [{"id":"\(id)","action":{"kind":"teleport","teleport":{"x":1}}}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        if case .respond = rules[0].action {} else { XCTFail("expected fallback to .respond") }
    }

    /// A body ref whose payload reference is empty degrades to `.none` rather than a broken rule.
    func test_emptyBodyRefsDegradeToNone() {
        let json = """
        [{"id":"\(id)","action":{"kind":"respond","respond":{"body":{"kind":"blob","filename":""}}}}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        guard case .respond(let spec) = rules[0].action else { return XCTFail("expected .respond") }
        XCTAssertEqual(spec.body, .none)
    }

    /// A header missing a key must not take the whole enclosing rule down with it — this is the
    /// specific reason `HeaderPair` needed a tolerant decoder once it became persisted.
    func test_partialHeaderDoesNotDropTheRule() {
        let json = """
        [{"id":"\(id)","name":"Headers",
          "action":{"kind":"respond","respond":{"headers":[{"name":"X-A"},{"value":"only-value"}]}}}]
        """
        let rules = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1, "a partial header must not skip the rule")
        guard case .respond(let spec) = rules[0].action else { return XCTFail("expected .respond") }
        XCTAssertEqual(spec.headers.count, 2)
        XCTAssertEqual(spec.headers[0].name, "X-A")
        XCTAssertEqual(spec.headers[0].value, "")
        XCTAssertEqual(spec.headers[1].value, "only-value")
    }

    /// Everything survives a save/load cycle unchanged.
    func test_roundTripPreservesEveryField() throws {
        let original = OverrideRule(
            id: UUID(),
            name: "Round trip",
            enabled: false,
            matcher: OverrideMatcher(pattern: "https://a.com/**", kind: .regex, methods: ["GET", "POST"]),
            scope: OverrideScope(deviceIDs: ["emulator-5554"], appIDs: ["com.example"]),
            action: .editResponse(ResponseEdit(statusCode: 503, headerMode: .replace,
                                               headers: [HeaderPair(name: "X-A", value: "1")],
                                               removeHeaders: ["Set-Cookie"],
                                               body: .inline("{}"))),
            delayMillis: 750,
            divertHosts: ["a.com", "b.com"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([original])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([OverrideRule].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        let r = decoded[0]
        XCTAssertEqual(r.id, original.id)
        XCTAssertEqual(r.name, original.name)
        XCTAssertEqual(r.enabled, false)
        XCTAssertEqual(r.matcher, original.matcher)
        XCTAssertEqual(r.scope, original.scope)
        XCTAssertEqual(r.action, original.action)
        XCTAssertEqual(r.delayMillis, 750)
        XCTAssertEqual(r.divertHosts, ["a.com", "b.com"])
    }
}

/// The persistence round-trip through the **real store encoder/decoder pair**.
///
/// The original bug lived exactly in the gap these tests now cover: `save` wrote ISO-8601 dates
/// while `load` decoded with a bare `JSONDecoder` (numeric strategy), so every record threw
/// `typeMismatch`, the library loaded empty on every launch, and the next save overwrote
/// `rules.json` and garbage-collected every body blob. The older tests missed it because they
/// configured *both* sides to ISO-8601 by hand — a pairing production never used.
final class OverrideStoreRoundTripTests: XCTestCase {

    /// Encodes exactly as `OverrideRuleStore.save` does.
    private func encodeLikeStore(_ rules: [OverrideRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(rules)
    }

    func test_savedRulesSurviveAReload() throws {
        let rule = OverrideRule(name: "persisted",
                                matcher: OverrideMatcher(pattern: "https://a.com/**"),
                                divertHosts: ["a.com"])
        let data = try encodeLikeStore([rule])

        let loaded = CloudPersistence.decodeArray(OverrideRule.self, from: data,
                                                  decoder: OverrideRuleStore.makeDecoder())

        XCTAssertEqual(loaded.count, 1, "a saved rule must still be there on the next launch")
        XCTAssertEqual(loaded.first?.id, rule.id)
        XCTAssertEqual(loaded.first?.name, "persisted")
        XCTAssertEqual(loaded.first?.divertHosts, ["a.com"])
    }

    func test_createdAtIsWrittenAsAStringAndReadBack() throws {
        let rule = OverrideRule(name: "dated", matcher: OverrideMatcher(pattern: "https://a.com/**"))
        let text = String(data: try encodeLikeStore([rule]), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"createdAt\" : \""),
                      "rules.json is documented as hand-editable — dates stay ISO-8601 strings")

        let loaded = CloudPersistence.decodeArray(OverrideRule.self, from: Data(text.utf8),
                                                  decoder: OverrideRuleStore.makeDecoder())
        XCTAssertEqual(loaded.count, 1)
    }

    /// A file written by the *other* strategy must still load — createdAt is cosmetic and must
    /// never be the reason a rule is dropped.
    func test_numericCreatedAtStillLoads() {
        let json = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"numeric","createdAt":776000000.5}]
        """
        let loaded = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8),
                                                  decoder: OverrideRuleStore.makeDecoder())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "numeric")
    }

    func test_garbledCreatedAtDefaultsRatherThanDroppingTheRule() {
        let json = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"garbled","createdAt":"not-a-date"}]
        """
        let loaded = CloudPersistence.decodeArray(OverrideRule.self, from: Data(json.utf8),
                                                  decoder: OverrideRuleStore.makeDecoder())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "garbled")
    }
}
