// PixelCanvas.swift — port of renderer/draw.js's 1px drawing kit. Renders
// into an offscreen bitmap at exact logical-pixel size, with no
// antialiasing and no interpolation, so the widget looks the same hard-edge
// way at any integer scale — the caller blits the resulting CGImage scaled
// up with nearest-neighbor, it never draws pre-scaled itself.
import Foundation

public final class PixelCanvas {
    public let width: Int
    public let height: Int
    let bytesPerRow: Int
    // Plain zero-initialized byte buffer, RGBA per pixel — no platform
    // drawing API involved. Kept internal (not private): the CoreGraphics
    // adapter (PixelCanvas+CoreGraphics.swift) is a different file in the
    // same module that reads this directly to build a CGImage.
    var buffer: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        // A CGContext(data: nil, ...) didn't guarantee a zeroed buffer, and
        // CGContext.fill() runs every solid-color rect through Core
        // Graphics's color-managed painting pipeline — small enough to be
        // invisible for photos, but not byte-exact, which matters when a
        // user's chosen ink/paper hex is supposed to render verbatim. Every
        // fill below writes raw RGBA bytes straight into this buffer
        // instead (see fillRect); a fresh Swift array is already
        // zero-filled, so there's nothing left to clear explicitly.
        self.buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    }

    // Every other drawing method bottoms out here. Writes raw bytes directly
    // into the backing buffer — see the note in init() for why this skips
    // CGContext's own fill(). Buffer row 0 is defined to be logical row 0
    // (top), so x/y here are already in the top-left/y-down space every
    // layout constant in this port (ported from a browser canvas 2D
    // context) uses — no coordinate flip needed anywhere.
    public func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hexColor: String) {
        guard w > 0, h > 0 else { return }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }

        let (r, g, b) = Self.rgb(hex: hexColor)
        for row in y0..<y1 {
            var offset = row * bytesPerRow + x0 * 4
            for _ in x0..<x1 {
                buffer[offset] = r
                buffer[offset + 1] = g
                buffer[offset + 2] = b
                buffer[offset + 3] = 255
                offset += 4
            }
        }
    }

    // Four fills, not strokeRect: a 1px stroke straddles the pixel boundary
    // and comes out grey and blurred once the context is scaled up.
    public func drawBorder(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hexColor: String) {
        fillRect(x, y, w, 1, hexColor)
        fillRect(x, y + h - 1, w, 1, hexColor)
        fillRect(x, y, 1, h, hexColor)
        fillRect(x + w - 1, y, 1, h, hexColor)
    }

    private static let defaultGridColors: [Character: String] = ["#": "#000000", "w": "#FFFFFF", "g": "#C8C8C8"]

    public func drawGrid(_ grid: [String], _ x: Int, _ y: Int, colorMap: [Character: String] = [:]) {
        let colors = Self.defaultGridColors.merging(colorMap) { _, override in override }
        for (row, line) in grid.enumerated() {
            for (col, char) in line.enumerated() {
                if char == "." || char == "0" { continue }
                fillRect(x + col, y + row, 1, 1, colors[char] ?? "#000000")
            }
        }
    }

    public func drawIcon(_ iconGrid: [String], _ x: Int, _ y: Int, _ hexColor: String = "#000000") {
        for (row, line) in iconGrid.enumerated() {
            for (col, char) in line.enumerated() where char == "1" {
                fillRect(x + col, y + row, 1, 1, hexColor)
            }
        }
    }

    // Glyphs are not all the same width, so the advance has to come from the
    // glyph itself. Returns width in logical px.
    public static func measureText(_ text: String, scale: Int, glyphs: [Character: [String]], gap: Int = 1) -> Int {
        var w = 0
        for ch in text {
            guard let first = glyphs[ch]?.first else { continue }
            w += first.count + gap
        }
        return w > 0 ? (w - gap) * scale : 0
    }

    @discardableResult
    public func drawText(_ text: String, _ x: Int, _ y: Int, scale: Int, _ hexColor: String, glyphs: [Character: [String]], gap: Int = 1) -> Int {
        var px = 0
        for ch in text {
            guard let glyph = glyphs[ch], let first = glyph.first else { continue }
            drawGlyph(glyph, x + px * scale, y, scale, hexColor)
            px += first.count + gap
        }
        return px > 0 ? (px - gap) * scale : 0
    }

    private func drawGlyph(_ glyph: [String], _ x: Int, _ y: Int, _ scale: Int, _ hexColor: String) {
        for (row, line) in glyph.enumerated() {
            for (col, char) in line.enumerated() where char == "1" {
                fillRect(x + col * scale, y + row * scale, scale, scale, hexColor)
            }
        }
    }

    // Rounded rectangle by omitting the 4 extreme corner pixels.
    public func drawRoundRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hexColor: String, filled: Bool = false) {
        if filled {
            guard w > 2, h > 2 else { return }
            fillRect(x + 1, y, w - 2, h, hexColor)
            fillRect(x, y + 1, 1, h - 2, hexColor)
            fillRect(x + w - 1, y + 1, 1, h - 2, hexColor)
        } else {
            if w > 2 {
                fillRect(x + 1, y, w - 2, 1, hexColor)
                fillRect(x + 1, y + h - 1, w - 2, 1, hexColor)
            }
            if h > 2 {
                fillRect(x, y + 1, 1, h - 2, hexColor)
                fillRect(x + w - 1, y + 1, 1, h - 2, hexColor)
            }
        }
    }

    // Testing/debugging only: samples a pixel straight out of the backing
    // buffer, bypassing CGImage, so tests can assert exact placement without
    // depending on how makeImage() happens to encode the result.
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
    }

    private static func rgb(hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
}
