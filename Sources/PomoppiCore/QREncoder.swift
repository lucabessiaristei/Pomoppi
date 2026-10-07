// QREncoder.swift — hand-rolled QR Code encoder (ISO/IEC 18004): byte mode
// only, versions 1-40, error correction level M, GF(256) Reed-Solomon, all 8
// masks scored with the 4 penalty rules (lowest wins). Foundation-only, so
// it builds on Windows too. Used by the transfer popup (SPEC.md §16); the
// pixel drawing lives in PomoppiRender's PixelCanvas+QR.swift.
import Foundation

public struct QRCode: Equatable {
    public let version: Int
    public let mask: Int
    private let modules: [Bool]

    public var size: Int { Self.size(ofVersion: version) }

    // Row-major from the top-left; true = dark. Out of range reads as light.
    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, x < size, y >= 0, y < size else { return false }
        return modules[y * size + x]
    }

    public static func size(ofVersion version: Int) -> Int { 17 + 4 * version }

    // MARK: Capacity (level M)

    // (EC codewords per block, blocks in group 1, data codewords per block in
    // group 1, blocks in group 2, data codewords per block in group 2),
    // indexed by version - 1.
    static let blockTable: [(ec: Int, n1: Int, d1: Int, n2: Int, d2: Int)] = [
        (10, 1, 16, 0, 0), (16, 1, 28, 0, 0), (26, 1, 44, 0, 0), (18, 2, 32, 0, 0),
        (24, 2, 43, 0, 0), (16, 4, 27, 0, 0), (18, 4, 31, 0, 0), (22, 2, 38, 2, 39),
        (22, 3, 36, 2, 37), (26, 4, 43, 1, 44), (30, 1, 50, 4, 51), (22, 6, 36, 2, 37),
        (22, 8, 37, 1, 38), (24, 4, 40, 5, 41), (24, 5, 41, 5, 42), (28, 7, 45, 3, 46),
        (28, 10, 46, 1, 47), (26, 9, 43, 4, 44), (26, 3, 44, 11, 45), (26, 3, 41, 13, 42),
        (26, 17, 42, 0, 0), (28, 17, 46, 0, 0), (28, 4, 47, 14, 48), (28, 6, 45, 14, 46),
        (28, 8, 47, 13, 48), (28, 19, 46, 4, 47), (28, 22, 45, 3, 46), (28, 3, 45, 23, 46),
        (28, 21, 45, 7, 46), (28, 19, 47, 10, 48), (28, 2, 46, 29, 47), (28, 10, 46, 23, 47),
        (28, 14, 46, 21, 47), (28, 14, 46, 23, 47), (28, 12, 47, 26, 48), (28, 6, 47, 34, 48),
        (28, 29, 46, 14, 47), (28, 13, 46, 32, 47), (28, 40, 47, 7, 48), (28, 18, 47, 31, 48),
    ]

    static func dataCodewords(version: Int) -> Int {
        let t = blockTable[version - 1]
        return t.n1 * t.d1 + t.n2 * t.d2
    }

    static func countBits(version: Int) -> Int { version <= 9 ? 8 : 16 }

    // Largest payload (bytes) that fits a version: data bits minus the 4-bit
    // mode and the length field.
    public static func byteCapacity(version: Int) -> Int {
        (dataCodewords(version: version) * 8 - 4 - countBits(version: version)) / 8
    }

    public static let maxByteCount = byteCapacity(version: 40)

    // Smallest version whose capacity holds `count` bytes; nil past v40-M.
    public static func version(forByteCount count: Int) -> Int? {
        guard count >= 0 else { return nil }
        return (1...40).first { count <= byteCapacity(version: $0) }
    }

    // MARK: Encoding

    public static func encode(_ data: Data) -> QRCode? {
        guard let version = version(forByteCount: data.count) else { return nil }

        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
        append(0b0100, 4)
        append(data.count, countBits(version: version))
        for byte in data { append(Int(byte), 8) }
        let capacityBits = dataCodewords(version: version) * 8
        append(0, min(4, capacityBits - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var codewords = [UInt8](repeating: 0, count: bits.count / 8)
        for (i, bit) in bits.enumerated() where bit { codewords[i / 8] |= 0x80 >> UInt8(i % 8) }
        var pad: UInt8 = 0xEC
        while codewords.count < dataCodewords(version: version) {
            codewords.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }

        let all = interleavedCodewords(codewords, version: version)
        var best: QRCode?
        var bestPenalty = Int.max
        for mask in 0..<8 {
            let candidate = QRCode(version: version, mask: mask, codewords: all)
            let penalty = candidate.penalty()
            if penalty < bestPenalty {
                bestPenalty = penalty
                best = candidate
            }
        }
        return best
    }

    // Splits the data codewords into the version's blocks, appends each
    // block's Reed-Solomon codewords, then interleaves column-wise.
    static func interleavedCodewords(_ data: [UInt8], version: Int) -> [UInt8] {
        let t = blockTable[version - 1]
        var blocks: [[UInt8]] = []
        var ecs: [[UInt8]] = []
        var offset = 0
        for i in 0..<(t.n1 + t.n2) {
            let length = i < t.n1 ? t.d1 : t.d2
            let block = Array(data[offset..<offset + length])
            offset += length
            blocks.append(block)
            ecs.append(reedSolomon(block, ecCount: t.ec))
        }
        var out: [UInt8] = []
        for i in 0..<max(t.d1, t.d2) {
            for block in blocks where i < block.count { out.append(block[i]) }
        }
        for i in 0..<t.ec {
            for ec in ecs { out.append(ec[i]) }
        }
        return out
    }

    // MARK: Reed-Solomon over GF(256), primitive polynomial 0x11D

    private static let gfTables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    static func gfMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return gfTables.exp[gfTables.log[Int(a)] + gfTables.log[Int(b)]]
    }

    // The `ecCount` error-correction codewords of `data` (remainder of
    // data * x^ecCount divided by the generator polynomial).
    static func reedSolomon(_ data: [UInt8], ecCount: Int) -> [UInt8] {
        // Generator (x - a^0)(x - a^1)...(x - a^(ecCount-1)), highest term
        // implicit, coefficients high to low.
        var generator = [UInt8](repeating: 0, count: ecCount)
        generator[ecCount - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<ecCount {
            for j in 0..<ecCount {
                generator[j] = gfMultiply(generator[j], root)
                if j + 1 < ecCount { generator[j] ^= generator[j + 1] }
            }
            root = gfMultiply(root, 2)
        }
        var result = [UInt8](repeating: 0, count: ecCount)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for j in 0..<ecCount { result[j] ^= gfMultiply(generator[j], factor) }
        }
        return result
    }

    // MARK: Format and version information (BCH)

    // 15 format bits for level M (bits 00) + mask, already XORed with 0x5412.
    static func formatBits(mask: Int) -> Int {
        let data = mask  // level M = 0b00 in the top two of the five data bits
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        return ((data << 10) | rem) ^ 0x5412
    }

    // 18 version bits (versions 7+): 6 data bits + 12 BCH bits.
    static func versionBits(_ version: Int) -> Int {
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        return (version << 12) | rem
    }

    // MARK: Matrix

    static func alignmentPositions(version: Int) -> [Int] {
        if version == 1 { return [] }
        let count = version / 7 + 2
        let step = version == 32 ? 26 : (version * 4 + 4 + count * 2 - 3) / (count * 2 - 2) * 2
        var positions = [6]
        var p = size(ofVersion: version) - 7
        for _ in 0..<(count - 1) {
            positions.insert(p, at: 1)
            p -= step
        }
        return positions
    }

    // Function-pattern layout shared by every mask: which modules are
    // reserved and what the fixed ones hold.
    struct Layout {
        let size: Int
        var dark: [Bool]
        var isFunction: [Bool]

        init(version: Int) {
            size = QRCode.size(ofVersion: version)
            dark = [Bool](repeating: false, count: size * size)
            isFunction = dark
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
                for dy in -4...4 {
                    for dx in -4...4 {
                        let x = cx + dx, y = cy + dy
                        guard x >= 0, x < size, y >= 0, y < size else { continue }
                        let dist = max(abs(dx), abs(dy))
                        set(x, y, dist != 2 && dist != 4)
                    }
                }
            }
            let positions = QRCode.alignmentPositions(version: version)
            for (i, cx) in positions.enumerated() {
                for (j, cy) in positions.enumerated() {
                    if (i == 0 && j == 0) || (i == 0 && j == positions.count - 1) || (i == positions.count - 1 && j == 0) { continue }
                    for dy in -2...2 {
                        for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
                    }
                }
            }
            drawFormat(mask: 0)
            if version >= 7 {
                let bits = QRCode.versionBits(version)
                for i in 0..<18 {
                    let bit = (bits >> i) & 1 == 1
                    let a = size - 11 + i % 3, b = i / 3
                    set(a, b, bit)
                    set(b, a, bit)
                }
            }
        }

        mutating func set(_ x: Int, _ y: Int, _ value: Bool) {
            dark[y * size + x] = value
            isFunction[y * size + x] = true
        }

        mutating func drawFormat(mask: Int) {
            let bits = QRCode.formatBits(mask: mask)
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }
            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)
        }
    }

    static func maskApplies(_ mask: Int, _ x: Int, _ y: Int) -> Bool {
        switch mask {
        case 0: return (x + y) % 2 == 0
        case 1: return y % 2 == 0
        case 2: return x % 3 == 0
        case 3: return (x + y) % 3 == 0
        case 4: return (x / 3 + y / 2) % 2 == 0
        case 5: return x * y % 2 + x * y % 3 == 0
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    private init(version: Int, mask: Int, codewords: [UInt8]) {
        var layout = Layout(version: version)
        let size = layout.size
        var bitIndex = 0
        let totalBits = codewords.count * 8
        // Two-column zigzag from the bottom-right, skipping the timing column.
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vert : vert
                    guard !layout.isFunction[y * size + x], bitIndex < totalBits else { continue }
                    layout.dark[y * size + x] = (codewords[bitIndex >> 3] >> UInt8(7 - bitIndex & 7)) & 1 == 1
                    bitIndex += 1
                }
            }
            right -= 2
        }
        for y in 0..<size {
            for x in 0..<size where !layout.isFunction[y * size + x] && Self.maskApplies(mask, x, y) {
                layout.dark[y * size + x].toggle()
            }
        }
        layout.drawFormat(mask: mask)
        self.version = version
        self.mask = mask
        self.modules = layout.dark
    }

    // MARK: Penalty (ISO 18004 §7.8.3)

    func penalty() -> Int {
        let n = size
        var total = 0

        // Rule 1: runs of 5+ same-colour modules in a row/column.
        for horizontal in [true, false] {
            for a in 0..<n {
                var run = 1
                for b in 1..<n {
                    let same = horizontal ? self[b, a] == self[b - 1, a] : self[a, b] == self[a, b - 1]
                    if same {
                        run += 1
                        if run == 5 { total += 3 } else if run > 5 { total += 1 }
                    } else {
                        run = 1
                    }
                }
            }
        }

        // Rule 2: 2x2 blocks of one colour.
        for y in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                let c = self[x, y]
                if c == self[x + 1, y] && c == self[x, y + 1] && c == self[x + 1, y + 1] { total += 3 }
            }
        }

        // Rule 3: finder-like 1:1:3:1:1 with 4 light modules on either side.
        let patternA: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
        let patternB = Array(patternA.reversed())
        for horizontal in [true, false] {
            for a in 0..<n {
                for b in 0...(n - 11) {
                    var matchA = true, matchB = true
                    for k in 0..<11 {
                        let m = horizontal ? self[b + k, a] : self[a, b + k]
                        if m != patternA[k] { matchA = false }
                        if m != patternB[k] { matchB = false }
                        if !matchA && !matchB { break }
                    }
                    if matchA { total += 40 }
                    if matchB { total += 40 }
                }
            }
        }

        // Rule 4: dark/light balance, 10 per 5% step away from 50%.
        let dark = modules.reduce(0) { $0 + ($1 ? 1 : 0) }
        let cells = n * n
        total += ((abs(dark * 20 - cells * 10) + cells - 1) / cells - 1) * 10
        return total
    }
}

extension TransferSize {
    // Modules per side of the smallest level-M QR that holds the payload;
    // nil when it's past version 40's capacity (no QR is shown then).
    public var qrSide: Int? {
        QRCode.version(forByteCount: bytes).map { QRCode.size(ofVersion: $0) }
    }
}
