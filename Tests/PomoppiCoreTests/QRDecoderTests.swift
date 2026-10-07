import XCTest
@testable import PomoppiCore

// Luma images are built straight from QRCode modules (no PixelCanvas), so
// this runs on Windows too. A render is an inverse mapping from output pixel
// to module space, supersampled; blur/noise/lighting are applied after.
final class QRDecoderTests: XCTestCase {
    struct Gray {
        var width: Int
        var height: Int
        var px: [Double]  // 0...255

        var luma: [UInt8] { px.map { UInt8(max(0, min(255, $0.rounded()))) } }
    }

    struct Rng {
        var state: UInt64
        mutating func next() -> Double {  // 0..<1
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let a = max(next(), 1e-12), b = next()
            return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
        }
    }

    func random(_ count: Int, seed: UInt64) -> Data {
        var rng = Rng(state: seed)
        return Data((0..<count).map { _ in UInt8(rng.next() * 256) })
    }

    // scale = pixels per module, angle in degrees, tilt = perspective strength
    // (per pixel; the far edge shrinks by 1 + tilt * y), offset moves the code
    // off-centre inside a larger frame.
    func render(
        _ code: QRCode, scale: Double, angle: Double = 0, tilt: Double = 0, margin: Double = 4,
        frame: Double = 1, offset: (Double, Double) = (0, 0), background: Double = 255,
        flips: Set<Int> = [], samples: Int = 1
    ) -> Gray {
        let d = Double(code.size)
        let plain = (d + 2 * margin) * scale * frame * (angle.truncatingRemainder(dividingBy: 90) == 0 ? 1 : 1.45)
        let side = Int((plain * (1 + abs(tilt) * plain * 0.75)).rounded(.up))  // keep the wide edge in frame
        let cx = Double(side) / 2 + offset.0, cy = Double(side) / 2 + offset.1
        let (s, c) = (sin(angle * .pi / 180), cos(angle * .pi / 180))
        var px = [Double](repeating: background, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0.0
                for sy in 0..<samples {
                    for sx in 0..<samples {
                        let fx = Double(x) + (Double(sx) + 0.5) / Double(samples) - cx
                        let fy = Double(y) + (Double(sy) + 0.5) / Double(samples) - cy
                        let rx = fx * c + fy * s, ry = -fx * s + fy * c
                        let w = 1 + tilt * ry
                        let u = rx / w / scale + d / 2, v = ry / w / scale + d / 2
                        if u < -margin || v < -margin || u >= d + margin || v >= d + margin {
                            sum += background
                        } else if u < 0 || v < 0 || u >= d || v >= d {
                            sum += 255
                        } else {
                            let mx = Int(u), my = Int(v)
                            sum += code[mx, my] != flips.contains(my * code.size + mx) ? 0 : 255
                        }
                    }
                }
                px[y * side + x] = sum / Double(samples * samples)
            }
        }
        return Gray(width: side, height: side, px: px)
    }

    // Integer scale, upright: straight block fill (the fast path for big frames).
    func blocky(_ code: QRCode, scale: Int, margin: Int = 4) -> Gray {
        let side = (code.size + 2 * margin) * scale
        var px = [Double](repeating: 255, count: side * side)
        for my in 0..<code.size {
            for mx in 0..<code.size where code[mx, my] {
                for y in 0..<scale {
                    for x in 0..<scale { px[((my + margin) * scale + y) * side + (mx + margin) * scale + x] = 0 }
                }
            }
        }
        return Gray(width: side, height: side, px: px)
    }

    // Box blur, `passes` times (3 passes ~ Gaussian), radius in pixels.
    func blurred(_ g: Gray, radius: Int, passes: Int = 3) -> Gray {
        var out = g
        for _ in 0..<passes {
            for horizontal in [true, false] {
                var next = out.px
                let n = horizontal ? g.width : g.height, m = horizontal ? g.height : g.width
                for line in 0..<m {
                    for i in 0..<n {
                        var sum = 0.0
                        for k in -radius...radius {
                            let j = min(n - 1, max(0, i + k))
                            sum += out.px[horizontal ? line * g.width + j : j * g.width + line]
                        }
                        next[horizontal ? line * g.width + i : i * g.width + line] = sum / Double(2 * radius + 1)
                    }
                }
                out.px = next
            }
        }
        return out
    }

    func noisy(_ g: Gray, sigma: Double, seed: UInt64 = 5) -> Gray {
        var rng = Rng(state: seed)
        var out = g
        for i in out.px.indices { out.px[i] += sigma * rng.gaussian() }
        return out
    }

    // Left edge at `low` of full brightness, right edge at full.
    func lit(_ g: Gray, low: Double) -> Gray {
        var out = g
        for y in 0..<g.height {
            for x in 0..<g.width {
                out.px[y * g.width + x] *= low + (1 - low) * Double(x + y) / Double(g.width + g.height)
            }
        }
        return out
    }

    @discardableResult
    func expectDecode(_ g: Gray, _ payload: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let start = Date()
        do {
            let data = try QRDecoder.decode(luma: g.luma, width: g.width, height: g.height)
            XCTAssertEqual(data, payload, label, file: file, line: line)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if payload.count > 300 { print("QRDECODE \(label): \(g.width)x\(g.height) \(ms) ms") }
            return data == payload
        } catch {
            XCTFail("\(label): \(error)", file: file, line: line)
            return false
        }
    }

    func code(_ count: Int, seed: UInt64 = 1) -> (QRCode, Data) {
        let payload = random(count, seed: seed)
        return (QRCode.encode(payload)!, payload)
    }

    func devSamplePayload() throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let json = try? Data(contentsOf: dir.appendingPathComponent(".dev-app-support/sessions.json")) else { throw XCTSkip("no dev sample") }
        struct File: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try TransferCodec.encode(settings: .defaults, sessions: decoder.decode(File.self, from: json).sessions)
    }

    // MARK: Reed-Solomon

    func testReedSolomonCorrectsUpToHalfTheECCodewords() {
        var rng = Rng(state: 3)
        let data = (0..<40).map { _ in UInt8(rng.next() * 256) }
        let clean = data + QRCode.reedSolomon(data, ecCount: 20)
        var block = clean
        XCTAssertTrue(QRCode.reedSolomonCorrect(&block, ecCount: 20))
        XCTAssertEqual(block, clean)
        for errors in [1, 5, 10] {
            block = clean
            for i in 0..<errors { block[i * 5 + 1] ^= UInt8(1 + i * 7) }
            XCTAssertTrue(QRCode.reedSolomonCorrect(&block, ecCount: 20), "\(errors) errors")
            XCTAssertEqual(block, clean, "\(errors) errors")
        }
        block = clean
        for i in 0..<11 { block[i * 5] ^= UInt8(3 + i) }
        XCTAssertFalse(QRCode.reedSolomonCorrect(&block, ecCount: 20))
    }

    // Payload sizes used throughout: tiny (v1), ~100 B (v5), ~700 B (v21).
    var tiny: (QRCode, Data) { code(5, seed: 1) }
    var small: (QRCode, Data) { code(100, seed: 2) }
    var medium: (QRCode, Data) { code(700, seed: 3) }
    var maximum: (QRCode, Data) { code(QRCode.maxByteCount, seed: 9) }

    // MARK: Exact renders

    func testExactScalesAcrossVersions() {
        for ((code, payload), scale) in [(tiny, 3), (tiny, 7), (small, 4), (medium, 3), (maximum, 3)] {
            expectDecode(blocky(code, scale: scale), payload, "v\(code.version) exact x\(scale)")
        }
        expectDecode(blocky(QRCode.encode(Data())!, scale: 6), Data(), "empty")
    }

    func testNonIntegerScale() {
        for ((code, payload), scale) in [(tiny, 3.3), (tiny, 6.15), (small, 4.7)] {
            expectDecode(render(code, scale: scale, samples: 2), payload, "v\(code.version) x\(scale)")
        }
    }

    func testDevSampleCodecOutput() throws {
        let payload = try devSamplePayload()
        let code = QRCode.encode(payload)!
        print("QRDECODE dev sample: \(payload.count) bytes, v\(code.version)")
        expectDecode(blocky(code, scale: 3), payload, "dev sample exact x3")
        expectDecode(render(code, scale: 3, angle: 7, tilt: 0.3 / (Double(code.size) * 3)), payload, "dev sample rot 7 keystone 0.3")
    }

    // MARK: Rotation

    func testRotations() {
        for ((code, payload), angles) in [(tiny, [30.0, 90]), (small, [7, 180]), (medium, [30, 90]), (maximum, [7])] {
            for angle in angles {
                expectDecode(render(code, scale: 3, angle: angle), payload, "v\(code.version) rot \(angle)")
            }
        }
    }

    // MARK: Perspective

    // tilt k: the far edge is (1 - k/2) / (1 + k/2) as wide as the near one.
    func testPerspective() {
        let (small, smallPayload) = self.small
        expectDecode(render(small, scale: 4, tilt: 0.4 / (Double(small.size) * 4)), smallPayload, "v\(small.version) keystone 0.4")
        let (medium, mediumPayload) = self.medium
        expectDecode(render(medium, scale: 3, angle: 15, tilt: -0.4 / (Double(medium.size) * 3)), mediumPayload, "v\(medium.version) keystone -0.4 rot 15")
        let (maximum, maximumPayload) = self.maximum
        expectDecode(render(maximum, scale: 3, tilt: 0.3 / (Double(maximum.size) * 3)), maximumPayload, "v\(maximum.version) keystone 0.3")
    }

    // MARK: Degradation

    func testBlur() {
        let (small, smallPayload) = self.small
        expectDecode(blurred(blocky(small, scale: 6), radius: 2), smallPayload, "v\(small.version) blur 2px (~1/3 module)")
        let (medium, mediumPayload) = self.medium
        expectDecode(blurred(blocky(medium, scale: 4), radius: 1), mediumPayload, "v\(medium.version) blur 1px")
    }

    func testNoiseAndUnevenLighting() {
        let (small, payload) = self.small
        let g = render(small, scale: 5, angle: 5, tilt: 0.2 / (Double(small.size) * 5))
        expectDecode(noisy(g, sigma: 20), payload, "v\(small.version) noise")
        expectDecode(lit(g, low: 0.5), payload, "v\(small.version) gradient")
        expectDecode(noisy(lit(blurred(g, radius: 1), low: 0.6), sigma: 12), payload, "v\(small.version) blur+noise+gradient")
    }

    func testGrayBackgroundAndOffsetInLargerFrame() {
        let (small, smallPayload) = self.small
        expectDecode(render(small, scale: 4, frame: 2.5, offset: (60, -40), background: 120), smallPayload, "v\(small.version) gray frame")
        let (medium, mediumPayload) = self.medium
        expectDecode(render(medium, scale: 3, angle: 20, frame: 2, offset: (-50, 30), background: 60), mediumPayload, "v\(medium.version) dark frame rot")
    }

    func testDownscalesHugeInput() {
        let (code, payload) = tiny
        let g = blocky(code, scale: 72)
        XCTAssertGreaterThan(g.width, QRDecoder.maxSide)
        expectDecode(g, payload, "v\(code.version) huge")
    }

    func testCorrectableFlippedModules() {
        for ((code, payload), flipCount) in [(tiny, 4), (small, 10), (medium, 40)] {
            var rng = Rng(state: 77)
            var flips = Set<Int>()
            let size = code.size
            while flips.count < flipCount {
                let x = Int(rng.next() * Double(size)), y = Int(rng.next() * Double(size))
                if x > 8 && y > 8 && x < size - 9 || x > 8 && y > 8 && y < size - 9 { flips.insert(y * size + x) }
            }
            expectDecode(render(code, scale: 4, flips: flips), payload, "v\(code.version) \(flipCount) flipped")
        }
    }

    // MARK: Failures

    func testNotFound() {
        let blank = Gray(width: 200, height: 200, px: [Double](repeating: 255, count: 200 * 200))
        XCTAssertThrowsError(try QRDecoder.decode(luma: blank.luma, width: 200, height: 200)) {
            XCTAssertEqual($0 as? QRDecoder.Error, .notFound)
        }
        let n = noisy(Gray(width: 300, height: 300, px: [Double](repeating: 128, count: 300 * 300)), sigma: 60)
        XCTAssertThrowsError(try QRDecoder.decode(luma: n.luma, width: 300, height: 300)) {
            XCTAssertEqual($0 as? QRDecoder.Error, .notFound)
        }
        XCTAssertThrowsError(try QRDecoder.decode(luma: [], width: 0, height: 0))
    }

    func testTooDamagedIsUnreadable() {
        let (code, _) = medium
        var flips = Set<Int>()
        var rng = Rng(state: 4)
        while flips.count < 1500 {
            let x = Int(rng.next() * Double(code.size)), y = Int(rng.next() * Double(code.size))
            if x > 8 && y > 8 { flips.insert(y * code.size + x) }
        }
        let g = render(code, scale: 3, flips: flips)
        XCTAssertThrowsError(try QRDecoder.decode(luma: g.luma, width: g.width, height: g.height)) {
            XCTAssertEqual($0 as? QRDecoder.Error, .unreadable)
        }
    }
}
