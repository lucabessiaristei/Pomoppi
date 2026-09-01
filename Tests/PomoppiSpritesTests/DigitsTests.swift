import XCTest
@testable import PomoppiSprites

final class DigitsTests: XCTestCase {
    func testZeroGlyphMatchesExpectedSevenSegmentPattern() {
        let expected = [
            "0111110",
            "1000001",
            "1000001",
            "1000001",
            "1000001",
            "0000000",
            "1000001",
            "1000001",
            "1000001",
            "1000001",
            "0111110",
        ]
        XCTAssertEqual(Digits.glyphs["0"], expected)
    }

    func testOneGlyphOnlyLightsTheRightVerticals() {
        let expected = [
            "0000000",
            "0000001",
            "0000001",
            "0000001",
            "0000001",
            "0000000",
            "0000001",
            "0000001",
            "0000001",
            "0000001",
            "0000000",
        ]
        XCTAssertEqual(Digits.glyphs["1"], expected)
    }

    func testColonAndSpaceGlyphsAreTheLiteralExceptions() {
        XCTAssertEqual(Digits.glyphs[":"], ["00", "00", "11", "11", "00", "00", "00", "11", "11", "00", "00"])
        XCTAssertEqual(Digits.glyphs[" "], Array(repeating: "000", count: Digits.glyphHeight))
    }
}
