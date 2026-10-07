// PixelCanvas+QR.swift — draws a QRCode (PomoppiCore) into a PixelCanvas as
// plain square modules, always black on white (never themed, scanners want
// the contrast) with a 4-module quiet zone. No decoration: scanability first. Platform-neutral like PixelCanvas itself.
import Foundation
import PomoppiCore

extension PixelCanvas {
    public static let qrQuietZone = 4

    // Canvas side in pixels for a code of `side` modules at `scale`.
    public static func qrCanvasSide(modules side: Int, scale: Int) -> Int {
        (side + 2 * qrQuietZone) * scale
    }

    public func drawQR(_ code: QRCode, x: Int = 0, y: Int = 0, scale: Int) {
        let quiet = Self.qrQuietZone
        let full = Self.qrCanvasSide(modules: code.size, scale: scale)
        fillRect(x, y, full, full, "#FFFFFF")
        for row in 0..<code.size {
            for col in 0..<code.size where code[col, row] {
                fillRect(x + (col + quiet) * scale, y + (row + quiet) * scale, scale, scale, "#000000")
            }
        }
    }

    public static func qrCanvas(_ code: QRCode, scale: Int) -> PixelCanvas {
        let side = qrCanvasSide(modules: code.size, scale: scale)
        let canvas = PixelCanvas(width: side, height: side)
        canvas.drawQR(code, scale: scale)
        return canvas
    }
}
