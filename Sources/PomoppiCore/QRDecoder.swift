// QRDecoder.swift — hand-rolled QR reader over a grayscale buffer (ISO/IEC
// 18004): binarize, find the three finder patterns, fix the fourth corner
// with the bottom-right alignment pattern, sample the grid through a
// perspective transform, read format/version info, unmask, Reed-Solomon
// correct, parse byte mode. Foundation-only, so it builds on Windows too
// (SPEC.md §16). Level M and byte mode only, i.e. what QREncoder writes.
// Loading an image file into a luma buffer is each platform's own job.
import Foundation

public enum QRDecoder {
    public enum Error: Swift.Error, Equatable {
        case notFound     // no QR-like finder triple in the image
        case unreadable   // found one, but format info or Reed-Solomon failed
        case unsupported  // a valid code that isn't level M / byte mode
    }

    static let maxSide = 2000

    public static func decode(luma: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, luma.count == width * height else { throw Error.notFound }
        let (pixels, w, h) = downscaled(luma, width, height)
        let image = QRBinaryImage(luma: pixels, width: w, height: h)
        let triples = image.finderTriples()
        guard !triples.isEmpty else { throw Error.notFound }
        // Rank by whether the two timing patterns agree on a version: a real
        // triple has them, a false one (finder-like blobs in the data) doesn't,
        // however plausible its geometry.
        let frames = triples.prefix(30).map { frame(for: $0, in: image) }.sorted { $0.agreement > $1.agreement }
        var unsupported = false
        for frame in frames.prefix(3) {
            let (data, flagged) = decode(frame, in: image)
            if let data { return data }
            unsupported = unsupported || flagged
        }
        throw unsupported ? Error.unsupported : Error.unreadable
    }

    // Box filter by the integer factor that brings the long side to maxSide or less.
    static func downscaled(_ luma: [UInt8], _ width: Int, _ height: Int) -> ([UInt8], Int, Int) {
        let factor = (max(width, height) + maxSide - 1) / maxSide
        guard factor > 1 else { return (luma, width, height) }
        let w = width / factor, h = height / factor
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                for dy in 0..<factor {
                    for dx in 0..<factor { sum += Int(luma[(y * factor + dy) * width + x * factor + dx]) }
                }
                out[y * w + x] = UInt8(sum / (factor * factor))
            }
        }
        return (out, w, h)
    }

    // A finder triple plus what was measured off it: module size in pixels
    // and the perspective weights (the homography's denominator at the TR and
    // BL finders relative to TL; 1 = no foreshortening).
    private struct Frame {
        let triple: QRFinderTriple
        let module: Double
        let weightTR: Double
        let weightBL: Double
        let estimate: Double  // version, continuous
        var timingVersions: [Int?] = []  // version read off the row-6 and column-6 timing patterns

        // 2 when both timing patterns read the same version, 1 when one reads.
        var agreement: Int {
            if let a = timingVersions[0], a == timingVersions[1] { return 2 }
            return timingVersions.contains { $0 != nil } ? 1 : 0
        }
    }

    private enum Outcome {
        case data(Data)
        case failed(sawOtherFormat: Bool)
        case unsupportedMode
    }

    private static func frame(for triple: QRFinderTriple, in image: QRBinaryImage) -> Frame {
        let (tl, tr, bl) = (triple.tl, triple.tr, triple.bl)
        let lenU = hypot(tr.x - tl.x, tr.y - tl.y), lenV = hypot(bl.x - tl.x, bl.y - tl.y)
        let u = ((tr.x - tl.x) / lenU, (tr.y - tl.y) / lenU)
        let v = ((bl.x - tl.x) / lenV, (bl.y - tl.y) / lenV)
        // Along an edge the scale goes as 1 / w^2 (derivative of a Moebius map),
        // so the ratio of module sizes at the two ends gives the weights.
        func sizes(_ dir: (Double, Double)) -> [Double?] {
            [tl, tr, bl].map { image.moduleSize(of: $0, along: dir.0, dir.1) }
        }
        let su = sizes(u), sv = sizes(v)
        func average(_ s: [Double?], _ fallback: Double) -> Double {
            let known = s.compactMap { $0 }
            return known.isEmpty ? fallback : known.reduce(0, +) / Double(known.count)
        }
        let fallback = (tl.module + tr.module + bl.module) / 3
        let modU = average(su, fallback), modV = average(sv, fallback)
        func weight(_ from: Double?, _ to: Double?) -> Double {
            guard let from, let to else { return 1 }
            return min(2, max(0.5, (from / to).squareRoot()))
        }
        var frame = Frame(
            triple: triple, module: (modU + modV) / 2, weightTR: weight(su[0], su[1]), weightBL: weight(sv[0], sv[2]),
            estimate: ((lenU / modU + lenV / modV) / 2 + 7 - 17) / 4)
        frame.timingVersions = [
            timingVersion(from: tl, to: tr, offset: (v, [sv[0], sv[1]]), image, frame.module),
            timingVersion(from: tl, to: bl, offset: (u, [su[0], su[2]]), image, frame.module),
        ]
        return frame
    }

    // Version from the number of 1-module runs along a timing pattern: walk
    // the line three modules inside the edge between two finders (row/column
    // 6), where dark and light alternate for 4v + 3 runs between the finders'
    // own dark runs. Counting runs, not sampling a grid, so perspective and
    // rotation don't matter. nil when the count isn't a valid version.
    private static func timingVersion(
        from a: QRFinder, to b: QRFinder, offset: (dir: (Double, Double), sizes: [Double?]), _ image: QRBinaryImage, _ module: Double
    ) -> Int? {
        let ma = offset.sizes[0] ?? module, mb = offset.sizes[1] ?? module
        let x0 = a.x + offset.dir.0 * 3 * ma, y0 = a.y + offset.dir.1 * 3 * ma
        let x1 = b.x + offset.dir.0 * 3 * mb, y1 = b.y + offset.dir.1 * 3 * mb
        let length = hypot(x1 - x0, y1 - y0)
        let steps = Int(length * 4)
        guard steps > 8 else { return nil }
        var runs: [(dark: Bool, length: Int)] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let dark = image.isDark(Int(floor(x0 + (x1 - x0) * t)), Int(floor(y0 + (y1 - y0) * t)))
            if let last = runs.last, last.dark == dark { runs[runs.count - 1].length += 1 } else { runs.append((dark, 1)) }
        }
        // Specks shorter than a third of a module are noise: fold them into their neighbours.
        let shortest = Int(module * 4 / 3)
        while let i = runs.indices.dropFirst().dropLast().first(where: { runs[$0].length < shortest }) {
            runs.replaceSubrange((i - 1)...(i + 1), with: [(runs[i - 1].dark, runs[i - 1].length + runs[i].length + runs[i + 1].length)])
        }
        let alternating = runs.count - 2  // minus the two finders' dark runs
        guard alternating >= 7, (alternating - 3) % 4 == 0 else { return nil }
        let version = (alternating - 3) / 4
        return (1...40).contains(version) ? version : nil
    }

    // (payload, saw a valid non-M/non-byte code). Tries the estimated version
    // and its neighbours: the module size read off the finders is only
    // approximate, and the version info (v7+) is a better source when readable.
    private static func decode(_ frame: Frame, in image: QRBinaryImage) -> (Data?, Bool) {
        let estimate = frame.estimate
        let base = min(40, max(1, Int(estimate.rounded())))
        var versions: [Int] = []
        func add(_ version: Int) {
            if (1...40).contains(version) && !versions.contains(version) { versions.append(version) }
        }
        // Versions the timing patterns say (the size estimate off the finders is
        // too coarse to be trusted on its own), then the estimate and its neighbours.
        let timing = frame.timingVersions.compactMap { $0 }
        if let top = timing.first ?? (base >= 5 ? base : nil), top >= 5, let hint = versionHint(top, frame, image) { add(hint) }
        for version in timing { add(version) }
        add(base)
        let sign = estimate >= Double(base) ? 1 : -1
        for d in 1...(frame.agreement == 2 ? 1 : 3) {
            add(base + sign * d)
            add(base - sign * d)
        }

        var sawOtherFormat = false
        for version in versions {
            switch attempt(version, frame, image) {
            case .data(let data): return (data, false)
            case .unsupportedMode: return (nil, true)
            case .failed(let other): sawOtherFormat = sawOtherFormat || other
            }
        }
        return (nil, sawOtherFormat)
    }

    // MARK: Geometry

    // The three finder centres plus a fourth point from the perspective
    // weights (all 1 = the parallelogram estimate): the numerator of the
    // forward map is affine, so N = w * P at the three known corners fixes it.
    private static func finderHomography(_ version: Int, _ f: Frame, weighted: Bool = true) -> QRHomography? {
        let t = f.triple
        let far = Double(QRCode.size(ofVersion: version)) - 3.5
        let weight = weighted ? f.weightTR + f.weightBL - 1 : 0
        var corner = (t.tr.x + t.bl.x - t.tl.x, t.tr.y + t.bl.y - t.tl.y)
        if weighted && weight > 0.25 {
            corner = (
                (f.weightTR * t.tr.x + f.weightBL * t.bl.x - t.tl.x) / weight,
                (f.weightTR * t.tr.y + f.weightBL * t.bl.y - t.tl.y) / weight)
        }
        return QRHomography(
            from: [(3.5, 3.5), (far, 3.5), (3.5, far), (far, far)],
            to: [(t.tl.x, t.tl.y), (t.tr.x, t.tr.y), (t.bl.x, t.bl.y), corner])
    }

    // One module along each axis in pixels, measured around a module-space point.
    private static func axes(_ h: QRHomography, at c: Double, _ d: Double) -> ((x: Double, y: Double), (x: Double, y: Double)) {
        let l = h.map(c - 0.5, d), r = h.map(c + 0.5, d), u = h.map(c, d - 0.5), v = h.map(c, d + 0.5)
        return ((r.x - l.x, r.y - l.y), (v.x - u.x, v.y - u.y))
    }

    // Pins the fourth point of the finder-only estimate on the located
    // bottom-right alignment pattern (v2+).
    private static func pinned(_ version: Int, _ frame: Frame, _ estimate: QRHomography, _ image: QRBinaryImage) -> QRHomography? {
        let t = frame.triple
        let size = Double(QRCode.size(ofVersion: version))
        let alignment = size - 6.5
        let (a, b) = axes(estimate, at: alignment, alignment)
        guard let found = image.findAlignment(near: estimate.map(alignment, alignment), axis: a, b, radius: 4 + size / 20) else { return nil }
        return QRHomography(
            from: [(3.5, 3.5), (size - 3.5, 3.5), (3.5, size - 3.5), (alignment, alignment)],
            to: [(t.tl.x, t.tl.y), (t.tr.x, t.tr.y), (t.bl.x, t.bl.y), (found.x, found.y)])
    }

    // Big codes: locate every alignment pattern near where the current
    // transform predicts it and refit through all of them, twice.
    private static func refined(_ version: Int, _ frame: Frame, _ start: QRHomography, _ image: QRBinaryImage) -> QRHomography {
        let t = frame.triple
        let far = Double(QRCode.size(ofVersion: version)) - 3.5
        let positions = QRCode.alignmentPositions(version: version)
        var h = start
        for _ in 0..<2 {
            var src = [(3.5, 3.5), (far, 3.5), (3.5, far)]
            var dst = [(t.tl.x, t.tl.y), (t.tr.x, t.tr.y), (t.bl.x, t.bl.y)]
            for (i, px) in positions.enumerated() {
                for (j, py) in positions.enumerated() {
                    let last = positions.count - 1
                    if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                    let c = (Double(px) + 0.5, Double(py) + 0.5)
                    let (a, b) = axes(h, at: c.0, c.1)
                    if let found = image.findAlignment(near: h.map(c.0, c.1), axis: a, b, radius: 1.5) {
                        src.append(c)
                        dst.append((found.x, found.y))
                    }
                }
            }
            guard src.count >= 4, let next = QRHomography(from: src, to: dst) else { break }
            h = next
        }
        return h
    }

    // Last resort for small codes: walk the fourth point (v1: the corner,
    // no alignment pattern to pin it; otherwise the alignment centre) around
    // its estimate, nearest first, and let Reed-Solomon say when it fits.
    private static func cornerSearch(_ version: Int, _ frame: Frame, _ estimate: QRHomography) -> [QRHomography] {
        let t = frame.triple
        let size = Double(QRCode.size(ofVersion: version))
        let c = version == 1 ? size - 3.5 : size - 6.5
        let (a, b) = axes(estimate, at: c, c)
        let point = estimate.map(c, c)
        let reach = version == 1 ? 6 : 3
        var offsets: [(Double, Double)] = []
        for i in -reach...reach {
            for j in -reach...reach { offsets.append((Double(i) * 0.5, Double(j) * 0.5)) }
        }
        offsets.sort { $0.0 * $0.0 + $0.1 * $0.1 < $1.0 * $1.0 + $1.1 * $1.1 }
        return offsets.dropFirst().compactMap { o in
            QRHomography(
                from: [(3.5, 3.5), (size - 3.5, 3.5), (3.5, size - 3.5), (c, c)],
                to: [(t.tl.x, t.tl.y), (t.tr.x, t.tr.y), (t.bl.x, t.bl.y),
                     (point.x + o.0 * a.x + o.1 * b.x, point.y + o.0 * a.y + o.1 * b.y)])
        }
    }

    // Majority of the (2r+1)^2 pixels around a point.
    private static func vote(_ image: QRBinaryImage, _ x: Double, _ y: Double, _ r: Int) -> Bool {
        let px = Int(floor(x)), py = Int(floor(y))
        if r == 0 { return image.isDark(px, py) }
        var dark = 0
        for dy in -r...r {
            for dx in -r...r where image.isDark(px + dx, py + dy) { dark += 1 }
        }
        return dark * 2 > (2 * r + 1) * (2 * r + 1)
    }

    private static func sample(_ version: Int, _ h: QRHomography, _ image: QRBinaryImage, _ module: Double) -> [Bool] {
        let size = QRCode.size(ofVersion: version)
        let r = max(0, Int(module / 4))
        var grid = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let p = h.map(Double(x) + 0.5, Double(y) + 0.5)
                grid[y * size + x] = vote(image, p.x, p.y, r)
            }
        }
        return grid
    }

    // MARK: Format and version info

    private static let formatCodes = (0..<32).map { QRCode.formatBits(data: $0) }
    private static let versionCodes = (7...40).map { QRCode.versionBits($0) }

    private static func formatPositions(size: Int) -> ([(Int, Int)], [(Int, Int)]) {
        var first: [(Int, Int)] = []
        for i in 0..<15 {
            if i < 6 { first.append((8, i)) } else if i == 6 { first.append((8, 7)) } else if i == 7 { first.append((8, 8)) } else if i == 8 { first.append((7, 8)) } else { first.append((14 - i, 8)) }
        }
        let second = (0..<15).map { $0 < 8 ? (size - 1 - $0, 8) : (8, size - 15 + $0) }
        return (first, second)
    }

    // The 18-bit version info of the estimate's grid, nearest valid version
    // (Hamming <= 3) over both copies.
    private static func versionHint(_ base: Int, _ frame: Frame, _ image: QRBinaryImage) -> Int? {
        guard let h = finderHomography(base, frame) else { return nil }
        let size = QRCode.size(ofVersion: base)
        let grid = sample(base, h, image, frame.module)
        var a = 0, b = 0
        for i in 0..<18 {
            let p = size - 11 + i % 3, q = i / 3
            if grid[q * size + p] { a |= 1 << i }
            if grid[p * size + q] { b |= 1 << i }
        }
        var best: (distance: Int, version: Int)?
        for (index, code) in versionCodes.enumerated() {
            let d = min((a ^ code).nonzeroBitCount, (b ^ code).nonzeroBitCount)
            if d <= 3, best == nil || d < best!.distance { best = (d, index + 7) }
        }
        return best?.version
    }

    // MARK: Reading a symbol

    private static func attempt(_ version: Int, _ frame: Frame, _ image: QRBinaryImage) -> Outcome {
        guard let estimate = finderHomography(version, frame) else { return .failed(sawOtherFormat: false) }
        var sawOther = false
        // Lazily, best first: each later one only costs time when the earlier failed.
        var candidates: [() -> [QRHomography]] = []
        let pin = version >= 2 ? pinned(version, frame, estimate, image) : nil
        if let pin { candidates.append { [pin] } }
        if version >= 7 { candidates.append { [refined(version, frame, pin ?? estimate, image)] } }
        candidates.append { [estimate] }
        if version <= 10 { candidates.append { cornerSearch(version, frame, pin ?? estimate) } }
        for candidate in candidates {
            for h in candidate() {
                let outcome = read(version, sample(version, h, image, frame.module))
                switch outcome {
                case .failed(let other): sawOther = sawOther || other
                default: return outcome
                }
            }
        }
        return .failed(sawOtherFormat: sawOther)
    }

    private static func read(_ version: Int, _ grid: [Bool]) -> Outcome {
        let size = QRCode.size(ofVersion: version)
        let (first, second) = formatPositions(size: size)
        func bits(_ positions: [(Int, Int)]) -> Int {
            var value = 0
            for (i, p) in positions.enumerated() where grid[p.1 * size + p.0] { value |= 1 << i }
            return value
        }
        let a = bits(first), b = bits(second)
        var best: (sum: Int, d1: Int, d2: Int, data: Int)?
        for (data, code) in formatCodes.enumerated() {
            let d1 = (a ^ code).nonzeroBitCount, d2 = (b ^ code).nonzeroBitCount
            if best == nil || d1 + d2 < best!.sum { best = (d1 + d2, d1, d2, data) }
        }
        guard let format = best, min(format.d1, format.d2) <= 3 else { return .failed(sawOtherFormat: false) }
        guard format.data >> 3 == 0 else { return .failed(sawOtherFormat: max(format.d1, format.d2) <= 2) }
        let mask = format.data & 7

        // Codewords in the encoder's zigzag order, unmasked.
        let layout = QRCode.Layout(version: version)
        let table = QRCode.blockTable[version - 1]
        let total = table.n1 * (table.d1 + table.ec) + table.n2 * (table.d2 + table.ec)
        var codewords = [UInt8](repeating: 0, count: total)
        var bitIndex = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let y = ((right + 1) & 2) == 0 ? size - 1 - vert : vert
                    guard !layout.isFunction[y * size + x], bitIndex < total * 8 else { continue }
                    if grid[y * size + x] != QRCode.maskApplies(mask, x, y) { codewords[bitIndex >> 3] |= 0x80 >> UInt8(bitIndex & 7) }
                    bitIndex += 1
                }
            }
            right -= 2
        }

        // De-interleave, correct each block.
        let blockCount = table.n1 + table.n2
        let dataLengths = (0..<blockCount).map { $0 < table.n1 ? table.d1 : table.d2 }
        var blocks = [[UInt8]](repeating: [], count: blockCount)
        var next = 0
        for i in 0..<max(table.d1, table.d2) {
            for b in 0..<blockCount where i < dataLengths[b] {
                blocks[b].append(codewords[next])
                next += 1
            }
        }
        for _ in 0..<table.ec {
            for b in 0..<blockCount {
                blocks[b].append(codewords[next])
                next += 1
            }
        }
        var stream: [UInt8] = []
        for b in 0..<blockCount {
            guard QRCode.reedSolomonCorrect(&blocks[b], ecCount: table.ec) else { return .failed(sawOtherFormat: false) }
            stream += blocks[b].prefix(dataLengths[b])
        }
        return parse(stream, version: version)
    }

    // Byte-mode segments up to the terminator; any other mode is unsupported.
    private static func parse(_ stream: [UInt8], version: Int) -> Outcome {
        var position = 0
        let totalBits = stream.count * 8
        func read(_ count: Int) -> Int? {
            guard position + count <= totalBits else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int((stream[position >> 3] >> UInt8(7 - position & 7)) & 1)
                position += 1
            }
            return value
        }
        var out = Data()
        while totalBits - position >= 4 {
            guard let mode = read(4) else { break }
            if mode == 0 { break }
            guard mode == 0b0100 else { return .unsupportedMode }
            guard let count = read(QRCode.countBits(version: version)) else { return .failed(sawOtherFormat: false) }
            for _ in 0..<count {
                guard let byte = read(8) else { return .failed(sawOtherFormat: false) }
                out.append(UInt8(byte))
            }
        }
        return .data(out)
    }
}
