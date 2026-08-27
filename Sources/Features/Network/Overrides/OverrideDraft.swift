import Foundation

/// What the editor sheet is editing, and whether saving should **add** or **update**.
///
/// The add-vs-update decision travels with the item rather than in a second `@State` flag: when
/// they were separate, "New override" left the flag unset and `update(_:)` silently discarded
/// every brand-new rule.
struct OverrideDraft: Identifiable {
    /// Identifies the *presentation*, not the rule — so re-opening the same rule gives the sheet
    /// fresh `@State` instead of reusing a stale draft.
    let id = UUID()
    var rule: OverrideRule
    var isNew: Bool
    /// Why a rule seeded from a captured response may not reproduce it faithfully (truncated at
    /// the 1 MB cap, binary, streamed). Travels with the draft for the same reason `isNew` does.
    var seedWarning: String? = nil

    static func new(_ rule: OverrideRule, warning: String? = nil) -> OverrideDraft {
        OverrideDraft(rule: rule, isNew: true, seedWarning: warning)
    }
    static func existing(_ rule: OverrideRule) -> OverrideDraft { OverrideDraft(rule: rule, isNew: false) }
}
