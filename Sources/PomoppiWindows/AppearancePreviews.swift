// AppearancePreviews.swift — small rendered previews for the Appearance
// tab's picker grids (Phase W7), reusing the same PixelCanvas/WindowFrame
// primitives the real widget draws with — a preview always matches what
// selecting it actually looks like. Mirrors the algorithm in
// Sources/PomoppiApp/PixelPreviews.swift (same crop/tint logic) but written
// fresh here rather than shared with it: Sources/PomoppiApp/ is off-limits
// for this port, so this duplicates the small amount of logic instead of
// extracting it into a common file both targets would import. Produces
// plain PixelCanvas + a crop rect; SettingsWindow's
// WM_DRAWITEM handling blits the result into a picker card's button HDC via
// PixelCanvas+GDI's draw(into:) helper.
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiSprites

enum AppearancePreviews {
    struct Card {
        let canvas: PixelCanvas
        let cropX: Int
        let cropY: Int
        let cropWidth: Int
        let cropHeight: Int
    }

    // Same two steps WidgetRenderer does first (frame border, then the
    // background pattern masked to the frame's paper interior), minus the
    // pet/digits/UI chrome on top — see PixelPreviews.renderFrame for the
    // original reasoning (cards crop to a representative slice rather than
    // shrinking the whole 110x124 frame, since most of it is plain
    // interior).
    private static func renderFrame(backgroundID: String?, frameStyle: String, inkColor: String, paperColor: String) -> PixelCanvas {
        let style = FrameStyle(rawValue: frameStyle) ?? .scallopy
        let frameGrid = WindowFrame.grid(style: style, w: WidgetLayout.frameWidth, h: WidgetLayout.frameHeight)
        let canvas = PixelCanvas(width: WidgetLayout.frameWidth, height: WidgetLayout.frameHeight)
        canvas.drawGrid(frameGrid, 0, 0, colorMap: ["#": inkColor, "w": paperColor])

        if let backgroundID, let pattern = GeneratedSprites.backgroundPatterns[backgroundID] {
            let tint = mix(paperColor, inkColor, 0.3)
            for y in 0..<min(pattern.count, frameGrid.count) {
                let row = Array(pattern[y])
                let frameRow = Array(frameGrid[y])
                for x in 0..<min(row.count, frameRow.count) {
                    guard row[x] == "#", frameRow[x] == "w" else { continue }
                    canvas.fillRect(x, y, 1, 1, tint)
                }
            }
        }
        return canvas
    }

    // Window-edge cards: one corner quadrant (top-left) of the full frame,
    // exactly 1/4 of its area — the border style fills the card instead of
    // a sliver around a mostly-empty middle.
    static func frameEdgeCard(frameStyle: String, inkColor: String, paperColor: String) -> Card {
        let canvas = renderFrame(backgroundID: nil, frameStyle: frameStyle, inkColor: inkColor, paperColor: paperColor)
        return Card(canvas: canvas, cropX: 0, cropY: 0, cropWidth: WidgetLayout.frameWidth / 2, cropHeight: WidgetLayout.frameHeight / 2)
    }

    // Background cards: the top half only, full width — pattern art never
    // fills the bottom of the real widget either, so a full-height preview
    // wastes its bottom half on plain paper.
    static func backgroundPatternCard(backgroundID: String, frameStyle: String, inkColor: String, paperColor: String) -> Card {
        let canvas = renderFrame(backgroundID: backgroundID, frameStyle: frameStyle, inkColor: inkColor, paperColor: paperColor)
        return Card(canvas: canvas, cropX: 0, cropY: 0, cropWidth: WidgetLayout.frameWidth, cropHeight: WidgetLayout.frameHeight / 2)
    }

    // One friend frame (its resting pose). Friend art is line art ('#' ink,
    // '.' transparent, 'w' paper highlights) with no background of its own,
    // so fill with paper first — a light ink colour on transparent would go
    // nearly invisible otherwise.
    static func friendIcon(friendID: String, inkColor: String, paperColor: String) -> Card? {
        guard let frame = GeneratedSprites.friendFrames[friendID]?.first else { return nil }
        let canvas = PixelCanvas(width: GeneratedSprites.friendWidth, height: GeneratedSprites.friendHeight)
        canvas.fillRect(0, 0, GeneratedSprites.friendWidth, GeneratedSprites.friendHeight, paperColor)
        canvas.drawGrid(frame, 0, 0, colorMap: ["#": inkColor, "w": paperColor])
        return Card(canvas: canvas, cropX: 0, cropY: 0, cropWidth: GeneratedSprites.friendWidth, cropHeight: GeneratedSprites.friendHeight)
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let n = UInt32(h, radix: 16) ?? 0
        return (Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
    }

    private static func mix(_ base: String, _ tint: String, _ amount: Double) -> String {
        let a = rgb(base)
        let b = rgb(tint)
        func mixed(_ from: Int, _ to: Int) -> String {
            let v = Double(from) + Double(to - from) * amount
            return String(format: "%02X", Int(min(255, max(0, v)).rounded()))
        }
        return "#" + mixed(a.0, b.0) + mixed(a.1, b.1) + mixed(a.2, b.2)
    }
}
