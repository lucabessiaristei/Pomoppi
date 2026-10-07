import XCTest
import PomoppiCore
@testable import PomoppiRender

final class QRRenderTests: XCTestCase {
    func testCanvasSizeAndModulePlacement() throws {
        let code = try XCTUnwrap(QRCode.encode(Data("hi".utf8)))
        let canvas = PixelCanvas.qrCanvas(code, scale: 3)
        XCTAssertEqual(canvas.width, (code.size + 8) * 3)
        XCTAssertEqual(canvas.height, canvas.width)
        // Quiet zone is paper; the top-left finder corner module is ink.
        XCTAssertEqual(canvas.pixel(x: 0, y: 0)?.r, 255)
        let ink = canvas.pixel(x: 4 * 3, y: 4 * 3)
        XCTAssertEqual(ink?.r, 0)
        XCTAssertEqual(ink?.b, 0)
        XCTAssertEqual(canvas.pixel(x: 4 * 3 + 2, y: 4 * 3 + 2)?.g, 0)
    }
}
