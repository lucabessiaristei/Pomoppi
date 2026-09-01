// WindowFrame.swift — port of the windowFrame()/wave()/rrProbe() algorithm in
// renderer/sprites.js. All four border styles (ziggy/scallopy/splotchy/wavey)
// are generated from geometry, not art, so porting this ~150-line function
// gets every style without transcribing any pixel data: a rounded rectangle
// probed against a per-edge-segment wave function, with the wave's period
// adapted per segment so it tiles evenly around the frame.
import Foundation

public enum FrameStyle: String, CaseIterable {
    case ziggy, scallopy, splotchy, wavey
}

public enum WindowFrame {
    private static let frameAmp = 8.0
    private static let frameRadius = 25.0
    private static let framePeriods: [FrameStyle: Double] = [
        .ziggy: 24, .scallopy: 26, .splotchy: 25, .wavey: 10,
    ]
    private static let framePeriod = 14.0

    private struct CacheKey: Hashable {
        let style: FrameStyle
        let w: Int
        let h: Int
    }
    private static var cache: [CacheKey: [String]] = [:]

    private static func wave(_ style: FrameStyle, _ t: Double, _ period: Double) -> Double {
        let p = (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        switch style {
        case .ziggy, .wavey:
            let half = period / 2
            return frameAmp * (p < half ? p / half : (period - p) / half)
        case .scallopy:
            let r = period / 2
            let dx = (p - r) / r
            return 10 * max(0, 1 - dx * dx).squareRoot()
        case .splotchy:
            return 5 * (0.5 - 0.5 * cos((p / period) * Double.pi * 2))
        }
    }

    private struct Probe {
        let d: Double
        let seg: Int
        let t: Double
    }

    // Distance from a rounded rect's own border, split into 8 alternating
    // straight/arc segments (top, top-right corner, right, bottom-right
    // corner, bottom, bottom-left corner, left, top-left corner) so each can
    // carry its own wave phase.
    private static func rrProbe(_ px: Double, _ py: Double, _ w: Double, _ h: Double, _ r: Double) -> Probe {
        let ix = min(max(px, r), w - r)
        let iy = min(max(py, r), h - r)
        let vx = px - ix, vy = py - iy
        let dist = (vx * vx + vy * vy).squareRoot()

        // sw/sh (the straight-segment lengths) only ever fed the original
        // `s` running-offset value, which windowFrame() never reads (only
        // `.d` and `.t` matter) — dropped here along with `s` itself.
        let arc = (Double.pi / 2) * r
        let cxOut = px < r ? -1 : (px > w - r ? 1 : 0)
        let cyOut = py < r ? -1 : (py > h - r ? 1 : 0)

        var seg = 0
        var t = 0.0

        if cxOut != 0 && cyOut != 0 {
            let a = atan2(vy, vx)
            let q = (a + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
            if cxOut > 0 && cyOut < 0 {
                seg = 1
                t = ((q - 1.5 * Double.pi) / (Double.pi / 2)) * arc
            } else if cxOut > 0 {
                seg = 3
                t = (q / (Double.pi / 2)) * arc
            } else if cyOut > 0 {
                seg = 5
                t = ((q - Double.pi / 2) / (Double.pi / 2)) * arc
            } else {
                seg = 7
                t = ((q - Double.pi) / (Double.pi / 2)) * arc
            }
        } else if cyOut < 0 {
            seg = 0
            t = px - r
        } else if cxOut > 0 {
            seg = 2
            t = py - r
        } else if cyOut > 0 {
            seg = 4
            t = w - r - px
        } else if cxOut < 0 {
            seg = 6
            t = h - r - py
        } else {
            seg = 0
            t = px - r
        }

        return Probe(d: dist - r, seg: seg, t: t)
    }

    // Grid legend matches renderer/draw.js: '.' transparent, '#' ink (edge
    // pixel), 'w' paper (interior pixel), so the caller can mask a background
    // pattern against the 'w' cells to crop it to the frame's own shape.
    public static func grid(style: FrameStyle, w: Int, h: Int) -> [String] {
        let key = CacheKey(style: style, w: w, h: h)
        if let cached = cache[key] { return cached }

        let amp = style == .scallopy ? 10.0 : frameAmp
        let r: Double = style == .scallopy ? 32 : (style == .splotchy || style == .wavey ? 25 : frameRadius)

        let bw = Double(w) - 1 - 2 * amp
        let bh = Double(h) - 1 - 2 * amp
        let wanted = framePeriods[style] ?? framePeriod

        let sw = bw - 2 * r, sh = bh - 2 * r, arc = (Double.pi / 2) * r
        let segLen = [sw, arc, sh, arc, sw, arc, sh, arc]
        let segPeriod = segLen.map { len in len / max(1, (len / wanted).rounded()) }

        var inside = Array(repeating: Array(repeating: false, count: w), count: h)
        for y in 0..<h {
            for x in 0..<w {
                let probe = rrProbe(Double(x) - amp, Double(y) - amp, bw, bh, r)
                let out = wave(style, probe.t, segPeriod[probe.seg])
                inside[y][x] = probe.d <= out
            }
        }

        var rows: [String] = []
        rows.reserveCapacity(h)
        for y in 0..<h {
            var chars = Array(repeating: Character("."), count: w)
            for x in 0..<w {
                guard inside[y][x] else { continue }
                let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                    || !inside[y][x - 1] || !inside[y][x + 1]
                    || !inside[y - 1][x] || !inside[y + 1][x]
                chars[x] = edge ? "#" : "w"
            }
            rows.append(String(chars))
        }

        cache[key] = rows
        return rows
    }
}
