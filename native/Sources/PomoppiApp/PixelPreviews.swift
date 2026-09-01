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
    static func backgroundCard(backgroundID: String, frameStyle: String, inkColor: String, paperColor: String) -> NSImage? {
        let style = FrameStyle(rawValue: frameStyle) ?? .scallopy
        let frameGrid = WindowFrame.grid(style: style, w: WidgetLayout.frameWidth, h: WidgetLayout.frameHeight)
        let canvas = PixelCanvas(width: WidgetLayout.frameWidth, height: WidgetLayout.frameHeight)
        canvas.drawGrid(frameGrid, 0, 0, colorMap: ["#": inkColor, "w": paperColor])

        if let pattern = GeneratedSprites.backgroundPatterns[backgroundID] {
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
        return image(from: canvas)
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
