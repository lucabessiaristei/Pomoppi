import XCTest
@testable import PomoppiSprites

final class WindowFrameTests: XCTestCase {
    func testGridHasRequestedDimensionsForEveryStyle() {
        for style in FrameStyle.allCases {
            let grid = WindowFrame.grid(style: style, w: 110, h: 124)
            XCTAssertEqual(grid.count, 124, "\(style) row count")
            for row in grid {
                XCTAssertEqual(row.count, 110, "\(style) row width")
            }
        }
    }

    func testGridContainsBothInkAndPaperCells() {
        let grid = WindowFrame.grid(style: .scallopy, w: 110, h: 124)
        let joined = grid.joined()
        XCTAssertTrue(joined.contains("#"), "expected at least one ink (edge) pixel")
        XCTAssertTrue(joined.contains("w"), "expected at least one paper (interior) pixel")
    }

    func testRepeatedCallsReturnTheSameCachedGrid() {
        let first = WindowFrame.grid(style: .ziggy, w: 110, h: 124)
        let second = WindowFrame.grid(style: .ziggy, w: 110, h: 124)
        XCTAssertEqual(first, second)
    }
}
