// QRDecoder+Locate.swift — the image side of the QR decoder: adaptive
// binarization, finder-pattern search, picking and orienting a triple,
// alignment-pattern search, and the 4-point homography. Pixel (i, j) covers
// [i, i+1) x [j, j+1); every Double coordinate here is continuous in that
// frame.
import Foundation

struct QRFinder {
    var x: Double
    var y: Double
    var module: Double
    var count: Int
}

// Oriented: tr is to the right of tl and bl below it, as the code reads.
struct QRFinderTriple {
    let tl: QRFinder
    let tr: QRFinder
    let bl: QRFinder
}

struct QRHomography {
    private let h: [Double]  // h11 h12 h13 h21 h22 h23 h31 h32, h33 = 1

    private init(_ h: [Double]) { self.h = h }

    // Least-squares fit of module-space points onto image points (exact for
    // four), on normalized coordinates so the normal equations stay tame.
    init?(from src: [(Double, Double)], to dst: [(Double, Double)]) {
        let n = src.count
        guard n >= 4, dst.count == n else { return nil }
        func normalization(_ pts: [(Double, Double)]) -> (cx: Double, cy: Double, scale: Double) {
            let cx = pts.map(\.0).reduce(0, +) / Double(n), cy = pts.map(\.1).reduce(0, +) / Double(n)
            let mean = pts.map { hypot($0.0 - cx, $0.1 - cy) }.reduce(0, +) / Double(n)
            return (cx, cy, mean > 0 ? 2.0.squareRoot() / mean : 1)
        }
        let ns = normalization(src), nd = normalization(dst)
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<n {
            let x = (src[i].0 - ns.cx) * ns.scale, y = (src[i].1 - ns.cy) * ns.scale
            let u = (dst[i].0 - nd.cx) * nd.scale, v = (dst[i].1 - nd.cy) * nd.scale
            for row in [[x, y, 1, 0, 0, 0, -u * x, -u * y, u], [0, 0, 0, x, y, 1, -v * x, -v * y, v]] {
                for r in 0..<8 {
                    for c in 0..<9 { a[r][c] += row[r] * row[c] }
                }
            }
        }
        for col in 0..<8 {
            var pivot = col
            for row in col..<8 where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let f = a[row][col] / a[col][col]
                if f == 0 { continue }
                for k in col...8 { a[row][k] -= f * a[col][k] }
            }
        }
        let g = (0..<8).map { a[$0][8] / a[$0][$0] } + [1.0]
        // H = Td^-1 * Hn * Ts, with Ts = scale(ns) o translate(-centre).
        let ts: [[Double]] = [[ns.scale, 0, -ns.cx * ns.scale], [0, ns.scale, -ns.cy * ns.scale], [0, 0, 1]]
        let tdInverse: [[Double]] = [[1 / nd.scale, 0, nd.cx], [0, 1 / nd.scale, nd.cy], [0, 0, 1]]
        func multiply(_ p: [[Double]], _ q: [[Double]]) -> [[Double]] {
            (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0.0) { $0 + p[r][$1] * q[$1][c] } } }
        }
        let hn: [[Double]] = [[g[0], g[1], g[2]], [g[3], g[4], g[5]], [g[6], g[7], 1]]
        let m = multiply(tdInverse, multiply(hn, ts))
        guard abs(m[2][2]) > 1e-12 else { return nil }
        self.init([m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1]].map { $0 / m[2][2] })
    }

    func map(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = h[6] * x + h[7] * y + 1
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }
}

struct QRBinaryImage {
    let width: Int
    let height: Int
    private let dark: [Bool]

    // Dark = clearly below the mean of a block of about 1/8 of the short side
    // (integral image), or in the darkest quarter of the global range when
    // the whole block is dark too (the flat middle of a finder).
    init(luma: [UInt8], width: Int, height: Int) {
        self.width = width
        self.height = height
        let stride = width + 1
        var integral = [UInt32](repeating: 0, count: stride * (height + 1))
        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            var row: UInt32 = 0
            for x in 0..<width {
                let p = luma[y * width + x]
                row += UInt32(p)
                histogram[Int(p)] += 1
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
            }
        }
        func percentile(_ fraction: Double) -> Int {
            let target = Int(Double(width * height) * fraction)
            var seen = 0
            for v in 0..<256 {
                seen += histogram[v]
                if seen > target { return v }
            }
            return 255
        }
        let low = percentile(0.02), high = percentile(0.98)
        let flatDark = low + (high - low) / 4
        let flatMean = flatDark + (high - low) / 8
        let half = max(8, min(width, height) / 16)
        var dark = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - half), y1 = min(height, y + half + 1)
            for x in 0..<width {
                let x0 = max(0, x - half), x1 = min(width, x + half + 1)
                let sum = integral[y1 * stride + x1] &- integral[y0 * stride + x1] &- integral[y1 * stride + x0] &+ integral[y0 * stride + x0]
                let mean = Int(sum) / ((x1 - x0) * (y1 - y0))
                let p = Int(luma[y * width + x])
                dark[y * width + x] = p < mean - max(8, mean / 8) || (p < flatDark && mean < flatMean)
            }
        }
        self.dark = dark
    }

    func isDark(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height && dark[y * width + x]
    }

    private func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < width && y >= 0 && y < height }

    // MARK: Finder patterns

    // counts = dark, light, dark (centre), light, dark run lengths, 1:1:3:1:1.
    private static func matches(_ counts: [Int], tolerance: Double) -> Bool {
        let total = counts.reduce(0, +)
        guard total >= 7 else { return false }
        let m = Double(total) / 7
        for i in [0, 1, 3, 4] where abs(Double(counts[i]) - m) > tolerance * m { return false }
        return abs(Double(counts[2]) - 3 * m) <= 3 * tolerance * m
    }

    // Runs through (x, y) along (dx, dy): the five finder runs and where the
    // middle one is centred, as an offset from the start pixel on that axis.
    private func scan(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> (counts: [Int], offset: Double)? {
        var counts = [0, 0, 0, 0, 0]
        var cx = x, cy = y
        while inside(cx, cy) && isDark(cx, cy) { counts[2] += 1; cx -= dx; cy -= dy }
        guard inside(cx, cy) else { return nil }
        while inside(cx, cy) && !isDark(cx, cy) { counts[1] += 1; cx -= dx; cy -= dy }
        guard inside(cx, cy), counts[1] > 0 else { return nil }
        while inside(cx, cy) && isDark(cx, cy) { counts[0] += 1; cx -= dx; cy -= dy }
        guard counts[0] > 0 else { return nil }
        let back = counts[2]
        cx = x + dx
        cy = y + dy
        while inside(cx, cy) && isDark(cx, cy) { counts[2] += 1; cx += dx; cy += dy }
        guard inside(cx, cy) else { return nil }
        while inside(cx, cy) && !isDark(cx, cy) { counts[3] += 1; cx += dx; cy += dy }
        guard inside(cx, cy), counts[3] > 0 else { return nil }
        while inside(cx, cy) && isDark(cx, cy) { counts[4] += 1; cx += dx; cy += dy }
        guard counts[4] > 0 else { return nil }
        return (counts, 1 + Double(counts[2] - back - back) / 2)
    }

    func findFinders() -> [QRFinder] {
        var found: [QRFinder] = []
        for y in 0..<height {
            var counts = [0, 0, 0, 0, 0]
            var state = 0
            for x in 0...width {
                let d = x < width && dark[y * width + x]
                if d == (state % 2 == 0) {
                    counts[state] += 1
                    continue
                }
                if state < 4 {
                    state += 1
                    counts[state] = 1
                    continue
                }
                if Self.matches(counts, tolerance: 0.6) {
                    let centre = Double(x) - Double(counts[4] + counts[3]) - Double(counts[2]) / 2
                    if let finder = crossChecked(x: centre, y: y) { merge(finder, into: &found) }
                }
                counts = [counts[2], counts[3], counts[4], 1, 0]
                state = 3
            }
        }
        // Seen on at least two rows and not pixel-sized: single hits are noise.
        return Array(found.filter { $0.count >= 2 && $0.module >= 1.5 }.sorted { $0.count > $1.count }.prefix(12))
    }

    private func crossChecked(x: Double, y: Int) -> QRFinder? {
        let ix = Int(floor(x))
        guard let vertical = scan(ix, y, 0, 1), Self.matches(vertical.counts, tolerance: 0.6) else { return nil }
        let cy = Double(y) + vertical.offset
        guard let horizontal = scan(ix, Int(floor(cy)), 1, 0), Self.matches(horizontal.counts, tolerance: 0.6) else { return nil }
        let cx = Double(ix) + horizontal.offset
        let module = Double(vertical.counts.reduce(0, +) + horizontal.counts.reduce(0, +)) / 14
        return QRFinder(x: cx, y: cy, module: module, count: 1)
    }

    private func merge(_ f: QRFinder, into found: inout [QRFinder]) {
        for i in found.indices {
            let o = found[i]
            let ratio = f.module / o.module
            guard hypot(f.x - o.x, f.y - o.y) < max(f.module, o.module), ratio > 0.67, ratio < 1.5 else { continue }
            let n = Double(o.count)
            found[i] = QRFinder(
                x: (o.x * n + f.x) / (n + 1), y: (o.y * n + f.y) / (n + 1),
                module: (o.module * n + f.module) / (n + 1), count: o.count + 1)
            return
        }
        found.append(f)
    }

    // Candidate triples, most plausible first: close to a right angle, equal
    // legs, similar module sizes, a plausible symbol size.
    func finderTriples() -> [QRFinderTriple] {
        let finders = findFinders()
        var scored: [(score: Double, triple: QRFinderTriple)] = []
        for i in 0..<finders.count {
            for j in (i + 1)..<max(i + 1, finders.count) {
                for k in (j + 1)..<max(j + 1, finders.count) {
                    let t = [finders[i], finders[j], finders[k]]
                    func d(_ a: QRFinder, _ b: QRFinder) -> Double { hypot(a.x - b.x, a.y - b.y) }
                    // The corner is the vertex opposite the longest side.
                    let sides = [d(t[1], t[2]), d(t[0], t[2]), d(t[0], t[1])]
                    let c = sides.firstIndex(of: sides.max()!)!
                    let p = t[c], q = t[(c + 1) % 3], r = t[(c + 2) % 3]
                    let lq = d(p, q), lr = d(p, r)
                    guard lq > 0, lr > 0 else { continue }
                    let cosine = ((q.x - p.x) * (r.x - p.x) + (q.y - p.y) * (r.y - p.y)) / (lq * lr)
                    let legRatio = min(lq, lr) / max(lq, lr)
                    let mods = t.map(\.module)
                    let moduleRatio = mods.max()! / mods.min()!
                    let span = (lq + lr) / 2 / (mods.reduce(0, +) / 3)
                    guard abs(cosine) < 0.4, legRatio > 0.5, moduleRatio < 3, span > 9, span < 190 else { continue }
                    let score = abs(cosine) + (1 - legRatio) + (moduleRatio - 1) * 0.2 + 3 / Double(t.map(\.count).min()!)
                    let cross = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
                    scored.append((score, cross > 0 ? QRFinderTriple(tl: p, tr: q, bl: r) : QRFinderTriple(tl: p, tr: r, bl: q)))
                }
            }
        }
        return scored.sorted { $0.score < $1.score }.map(\.triple)
    }

    // MARK: Module size and alignment

    // Module size of a finder measured along a direction (unit vector), from
    // where the dark/light edges fall on both sides of its centre: 1.5, 2.5
    // and 3.5 modules out.
    func moduleSize(of finder: QRFinder, along dx: Double, _ dy: Double) -> Double? {
        var total = 0.0
        for sign in [1.0, -1.0] {
            var color = isDark(Int(floor(finder.x)), Int(floor(finder.y)))
            guard color else { return nil }
            var edges: [Double] = []
            var t = 0.0
            while t < finder.module * 6, edges.count < 3 {
                t += 0.25
                let c = isDark(Int(floor(finder.x + sign * dx * t)), Int(floor(finder.y + sign * dy * t)))
                if c != color {
                    edges.append(t)
                    color = c
                }
            }
            guard edges.count == 3 else { return nil }
            total += (edges[0] / 1.5 + edges[1] / 2.5 + edges[2] / 3.5) / 3
        }
        return total / 2
    }

    // The 5x5 alignment pattern (dark ring, light ring, dark centre) nearest
    // a predicted centre: best template match over a window, or nil when
    // nothing matches well enough. (ax, ay) / (bx, by) are one module along
    // the symbol's x and y, in pixels.
    func findAlignment(near p: (x: Double, y: Double), axis a: (x: Double, y: Double), _ b: (x: Double, y: Double), radius: Double) -> (x: Double, y: Double)? {
        let module = max(hypot(a.x, a.y), hypot(b.x, b.y))
        let step = max(0.5, module / 8)
        let reach = radius * module
        var best = 0
        var bestDistance = Double.infinity
        var bestCentre: (x: Double, y: Double)?
        var oy = -reach
        while oy <= reach {
            var ox = -reach
            while ox <= reach {
                let cx = p.x + ox, cy = p.y + oy
                var score = 0
                for j in -2...2 {
                    for i in -2...2 {
                        let px = cx + Double(i) * a.x + Double(j) * b.x
                        let py = cy + Double(i) * a.y + Double(j) * b.y
                        let expected = max(abs(i), abs(j)) != 1
                        if isDark(Int(floor(px)), Int(floor(py))) == expected { score += 1 }
                    }
                }
                let distance = ox * ox + oy * oy
                if score > best || (score == best && distance < bestDistance) {
                    best = score
                    bestDistance = distance
                    bestCentre = (cx, cy)
                }
                ox += step
            }
            oy += step
        }
        return best >= 22 ? bestCentre : nil
    }
}
