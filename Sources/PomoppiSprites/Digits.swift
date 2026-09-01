// Digits.swift — port of the 7-segment digit generator in renderer/sprites.js
// (SEGMENTS/segmentGlyph). The clock digits are algorithmic, not art: a
// segment table plus a tiny generator produces every glyph, so there is no
// pixel data to transcribe for 0-9. ':' and ' ' are the two literal
// exceptions in the original file and are kept as literals here too.
import Foundation

public enum Digits {
    public static let glyphWidth = 7
    public static let glyphHeight = 11
    public static let digitGap = 2

    // top, tl, tr, mid, bl, br, bot
    private static let segments: [Character: [Bool]] = [
        "0": [true, true, true, false, true, true, true],
        "1": [false, false, true, false, false, true, false],
        "2": [true, false, true, true, true, false, true],
        "3": [true, false, true, true, false, true, true],
        "4": [false, true, true, true, false, true, false],
        "5": [true, true, false, true, false, true, true],
        "6": [true, true, false, true, true, true, true],
        "7": [true, false, true, false, false, true, false],
        "8": [true, true, true, true, true, true, true],
        "9": [true, true, true, true, false, true, true],
    ]

    private static func segmentGlyph(_ segs: [Bool]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("0"), count: glyphWidth), count: glyphHeight)
        let top = segs[0], tl = segs[1], tr = segs[2], mid = segs[3], bl = segs[4], br = segs[5], bot = segs[6]

        func h(_ y: Int) {
            for x in 1...(glyphWidth - 2) { grid[y][x] = "1" }
        }
        func v(_ x: Int, _ y0: Int, _ y1: Int) {
            for y in y0...y1 { grid[y][x] = "1" }
        }

        if top { h(0) }
        if mid { h(5) }
        if bot { h(10) }
        if tl { v(0, 1, 4) }
        if tr { v(glyphWidth - 1, 1, 4) }
        if bl { v(0, 6, 9) }
        if br { v(glyphWidth - 1, 6, 9) }

        return grid.map { String($0) }
    }

    public static let glyphs: [Character: [String]] = {
        var out: [Character: [String]] = [:]
        for (ch, segs) in segments { out[ch] = segmentGlyph(segs) }
        out[":"] = ["00", "00", "11", "11", "00", "00", "00", "11", "11", "00", "00"]
        out[" "] = Array(repeating: "000", count: glyphHeight)
        return out
    }()
}
