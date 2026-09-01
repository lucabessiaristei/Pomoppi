import XCTest
@testable import PomoppiCore

final class ShortcutsTests: XCTestCase {
    func testNormalizeIsCaseInsensitiveAndOrdersModifiers() {
        XCTAssertEqual(Shortcuts.normalize("shift+alt+p"), "Alt+Shift+P")
        XCTAssertEqual(Shortcuts.normalize("cmd+k"), "Command+K")
    }

    func testNormalizeRejectsABareKeyWithNoModifier() {
        XCTAssertEqual(Shortcuts.normalize("P"), "")
        XCTAssertEqual(Shortcuts.normalize("Space"), "")
    }

    func testNormalizeHandlesATrailingPlusKey() {
        // "Alt+Shift++" is what capturing Option-Shift-Equals sends on a US
        // layout — the trailing '+' is the bindable Plus key, not a stray
        // separator.
        XCTAssertEqual(Shortcuts.normalize("Alt+Shift++"), "Alt+Shift+Plus")
    }

    func testNormalizeRejectsMoreThanOneNonModifierKey() {
        XCTAssertEqual(Shortcuts.normalize("Alt+P+K"), "")
    }

    func testValidateFillsMissingActionsFromDefaultsAndKeepsValidCustomOnes() {
        let raw = ["skip": "Command+Shift+K"]
        let result = Shortcuts.validate(raw)
        XCTAssertEqual(result["skip"], "Command+Shift+K")
        XCTAssertEqual(result["toggleWidget"], Shortcuts.defaults["toggleWidget"])
    }

    func testValidateResolvesConflictsInActionTableOrder() {
        // toggleWidget comes before startPause in the action table, so if
        // both end up bound to the same combo, startPause loses it.
        let raw = ["toggleWidget": "Command+K", "startPause": "Command+K"]
        let result = Shortcuts.validate(raw)
        XCTAssertEqual(result["toggleWidget"], "Command+K")
        XCTAssertEqual(result["startPause"], "")
    }
}
