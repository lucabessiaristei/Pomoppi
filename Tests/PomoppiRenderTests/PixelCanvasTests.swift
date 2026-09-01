import XCTest
@testable import PomoppiRender

final class PixelCanvasTests: XCTestCase {
    func testFillRectPlacesColorAtExactTopLeftPixel() {
        let canvas = PixelCanvas(width: 4, height: 4)
        canvas.fillRect(0, 0, 1, 1, "#FF0000")

        let topLeft = canvas.pixel(x: 0, y: 0)
        XCTAssertEqual(topLeft?.r, 255)
        XCTAssertEqual(topLeft?.g, 0)
        XCTAssertEqual(topLeft?.b, 0)

        // Everything else stays untouched (transparent).
        XCTAssertEqual(canvas.pixel(x: 3, y: 3)?.a, 0)
    }

    // The canvas is y-flipped internally (CGContext is bottom-left/y-up
    // natively; the widget's layout math is top-left/y-down) — this is the
    // one place a sign error would silently render everything upside down.
    func testTopAndBottomRowsAreNotSwapped() {
        let canvas = PixelCanvas(width: 4, height: 4)
        canvas.fillRect(0, 0, 1, 1, "#FF0000")   // logical top row
        canvas.fillRect(0, 3, 1, 1, "#0000FF")   // logical bottom row

        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.r, 255)
        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.b, 0)
        XCTAssertEqual(canvas.pixel(x: 0, y: 3)?.b, 255)
        XCTAssertEqual(canvas.pixel(x: 0, y: 3)?.r, 0)
    }

    func testDrawBorderOnlyPaintsTheEdgeNotTheInterior() {
        let canvas = PixelCanvas(width: 5, height: 5)
        canvas.drawBorder(0, 0, 5, 5, "#000000")

        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.a, 255)
        XCTAssertEqual(canvas.pixel(x: 4, y: 4)?.a, 255)
        XCTAssertEqual(canvas.pixel(x: 2, y: 2)?.a, 0, "interior pixel should be untouched")
    }

    func testDrawGridSkipsTransparentCellsAndUsesColorMap() {
        let canvas = PixelCanvas(width: 3, height: 1)
        canvas.drawGrid(["#.w"], 0, 0, colorMap: ["#": "#111111", "w": "#EEEEEE"])

        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.r, 0x11)
        XCTAssertEqual(canvas.pixel(x: 1, y: 0)?.a, 0, "'.' cell should stay transparent")
        XCTAssertEqual(canvas.pixel(x: 2, y: 0)?.r, 0xEE)
    }

    func testMeasureAndDrawTextUseEachGlyphsOwnWidth() {
        // A 1px-wide "1" and a 2px-wide "0", both 1 row tall, gap 1.
        let glyphs: [Character: [String]] = ["1": ["1"], "0": ["10"]]
        let width = PixelCanvas.measureText("10", scale: 1, glyphs: glyphs, gap: 1)
        XCTAssertEqual(width, 1 + 1 + 2) // '1' (1px) + gap (1px) + '0' (2px)

        let canvas = PixelCanvas(width: 10, height: 1)
        let advance = canvas.drawText("10", 0, 0, scale: 1, "#000000", glyphs: glyphs, gap: 1)
        XCTAssertEqual(advance, width)
        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.a, 255) // '1' glyph pixel
        XCTAssertEqual(canvas.pixel(x: 1, y: 0)?.a, 0)   // the gap
        XCTAssertEqual(canvas.pixel(x: 2, y: 0)?.a, 255) // '0' glyph starts
    }
}
