import XCTest
@testable import Jaca

/// A macOS sheet can't be resized, so its frame is the dialog. These clamps are what keep Save on
/// screen on a small display.
final class OverrideEditorLayoutTests: XCTestCase {

    func test_sheetFitsAShortDisplay() {
        XCTAssertEqual(OverrideEditorLayout.sheetHeight(visibleHeight: 700), 620)
    }

    func test_sheetNeverExceedsTheIdealOnALargeDisplay() {
        XCTAssertEqual(OverrideEditorLayout.sheetHeight(visibleHeight: 2000), OverrideEditorLayout.idealSheetHeight)
        XCTAssertEqual(OverrideEditorLayout.sheetWidth(visibleWidth: 3000), OverrideEditorLayout.idealSheetWidth)
    }

    func test_sheetHasAFloorOnATinyDisplay() {
        XCTAssertEqual(OverrideEditorLayout.sheetHeight(visibleHeight: 400), OverrideEditorLayout.minSheetHeight)
        XCTAssertEqual(OverrideEditorLayout.sheetWidth(visibleWidth: 800), OverrideEditorLayout.minSheetWidth)
    }

    func test_narrowDisplayShrinksTheWidth() {
        XCTAssertEqual(OverrideEditorLayout.sheetWidth(visibleWidth: 1140), 1060)
    }

    func test_unreadableScreenFallsBackToTheIdeal() {
        XCTAssertEqual(OverrideEditorLayout.sheetHeight(visibleHeight: nil), OverrideEditorLayout.idealSheetHeight)
        XCTAssertEqual(OverrideEditorLayout.sheetHeight(visibleHeight: 0), OverrideEditorLayout.idealSheetHeight)
        XCTAssertEqual(OverrideEditorLayout.sheetWidth(visibleWidth: .nan), OverrideEditorLayout.idealSheetWidth)
    }

    /// The response pane has to keep a usable width even in the narrowest sheet.
    func test_responsePaneKeepsRoomAtTheMinimumWidth() {
        XCTAssertGreaterThan(OverrideEditorLayout.minSheetWidth - OverrideEditorLayout.settingsWidth, 300)
    }
}
