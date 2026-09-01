import AppKit
import PomoppiCore
import PomoppiRender
import PomoppiSprites

// Small rendered previews for the settings window's visual pickers — reuses
// the same PixelCanvas/WindowFrame primitives the real widget draws with,
// so a preview always matches what selecting it actually looks like,
// instead of a stand-in gradient or icon.
enum PixelPreviews {
    // A miniature card: the frame border plus the background pattern masked
    // to its interior — the same two steps WidgetRenderer does first, minus
    // the pet/digits/UI chrome on top.
    //
    // The full frame is 110×124 canvas pixels; shrunk to fit a ~55×62pt
    // card, every style rendered as the same fuzzy grey square — most of
    // the frame is plain interior, so the one part that actually
    // distinguishes a frame style (its border) or a background (its
    // pattern) barely registered. Both card kinds below crop to the
    // representative slice and hand it to the picker near its native size
    // instead, so the picker actually shows what's different.
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

    // Window edge cards: one corner quadrant (top-left) of the full frame —
    // exactly 1/4 of its area — so the border style (each style's defining
    // feature) fills the card instead of a sliver around a mostly-empty
    // middle.
    static func frameEdgeCard(frameStyle: String, inkColor: String, paperColor: String) -> NSImage? {
        let canvas = renderFrame(backgroundID: nil, frameStyle: frameStyle, inkColor: inkColor, paperColor: paperColor)
        let quadrant = CGRect(x: 0, y: 0, width: WidgetLayout.frameWidth / 2, height: WidgetLayout.frameHeight / 2)
        return image(from: canvas, crop: quadrant)
    }

    // Background cards: the top half only, full width. Pattern art is
    // shorter than the frame interior (it never fills the bottom of the
    // real widget either — see WidgetRenderer), so a full-height preview
    // always wasted its bottom half on plain paper; cropping to where the
    // pattern actually is lets it read at a noticeably bigger, still
    // undistorted scale (see the matching cardSize in SettingsView).
    static func backgroundPatternCard(backgroundID: String, frameStyle: String, inkColor: String, paperColor: String) -> NSImage? {
        let canvas = renderFrame(backgroundID: backgroundID, frameStyle: frameStyle, inkColor: inkColor, paperColor: paperColor)
        let topHalf = CGRect(x: 0, y: 0, width: WidgetLayout.frameWidth, height: WidgetLayout.frameHeight / 2)
        return image(from: canvas, crop: topHalf)
    }

    // One friend frame (its resting pose), for a quick recognizable icon
    // next to its name. Friend art is line art ('#' ink, '.' transparent,
    // 'w' paper highlights) with no background of its own — on the real
    // widget the card's paper shows through, but a standalone preview has
    // nothing behind it, so a light ink colour on a transparent background
    // would go nearly invisible. Fill with paper first to guarantee
    // contrast regardless of the current theme.
    static func friendIcon(friendID: String, inkColor: String, paperColor: String) -> NSImage? {
        guard let frame = GeneratedSprites.friendFrames[friendID]?.first else { return nil }
        let canvas = PixelCanvas(width: GeneratedSprites.friendWidth, height: GeneratedSprites.friendHeight)
        canvas.fillRect(0, 0, GeneratedSprites.friendWidth, GeneratedSprites.friendHeight, paperColor)
        canvas.drawGrid(frame, 0, 0, colorMap: ["#": inkColor, "w": paperColor])
        return image(from: canvas)
    }

    private static func image(from canvas: PixelCanvas) -> NSImage? {
        guard let cgImage = canvas.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: canvas.width, height: canvas.height))
    }

    // Crops in the canvas's own coordinate space — row 0 is the top row
    // (see PixelCanvas.fillRect), which is also CGImage's cropping origin,
    // so no y-flip is needed to reach for the top-left corner or top half.
    private static func image(from canvas: PixelCanvas, crop rect: CGRect) -> NSImage? {
        guard let cgImage = canvas.makeImage()?.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: rect.width, height: rect.height))
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
