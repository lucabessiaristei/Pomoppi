// Reference decode of the encoder's output with Apple's Vision, macOS only
// (needs CGImage, so it lives here rather than in PomoppiCoreTests).
#if canImport(Vision)
import XCTest
import Vision
import PomoppiCore
@testable import PomoppiRender

final class QRVisionTests: XCTestCase {
    private func decode(_ code: QRCode, scale: Int = 4) throws -> VNBarcodeObservation {
        let canvas = PixelCanvas.qrCanvas(code, scale: scale)
        let image = try XCTUnwrap(canvas.makeImage())
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return try XCTUnwrap(request.results?.first, "no QR found, version \(code.version)")
    }

    // payloadData is the symbol's data codewords (mode, count, bytes,
    // terminator, padding), not the bytes: parse the byte-mode segment out.
    private func byteModePayload(_ raw: Data, version: Int) -> Data? {
        let bytes = [UInt8](raw)
        func bits(_ start: Int, _ count: Int) -> Int {
            (start..<start + count).reduce(0) { acc, i in (acc << 1) | Int((bytes[i / 8] >> UInt8(7 - i % 8)) & 1) }
        }
        let countBits = version <= 9 ? 8 : 16
        guard bits(0, 4) == 0b0100 else { return nil }
        let n = bits(4, countBits)
        guard (4 + countBits + n * 8 + 7) / 8 <= bytes.count else { return nil }
        let start = 4 + countBits
        return Data((0..<n).map { UInt8(bits(start + $0 * 8, 8)) })
    }

    private func check(_ payload: Data, line: UInt = #line) throws -> Int {
        let code = try XCTUnwrap(QRCode.encode(payload), line: line)
        let observation = try decode(code)
        let got = try XCTUnwrap(observation.payloadData, line: line)
        print("QRVision: \(payload.count) B -> v\(code.version) (\(code.size)x\(code.size)), payloadData \(got.count) B")
        XCTAssertEqual(byteModePayload(got, version: code.version), payload, "v\(code.version)", line: line)
        return code.version
    }

    private func random(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    func testAsciiPayloadStringValue() throws {
        let text = "pomoppi1-hello world 123"
        let code = try XCTUnwrap(QRCode.encode(Data(text.utf8)))
        XCTAssertEqual(try decode(code).payloadStringValue, text)
    }

    func testPayloadSizes() throws {
        var versions = Set<Int>()
        for (count, seed) in [(1, 1), (14, 2), (15, 3), (100, 4), (213, 5), (214, 6), (700, 7), (1500, 8), (2331, 9)] {
            versions.insert(try check(random(count, seed: UInt64(seed))))
        }
        XCTAssertTrue(versions.contains(1) && versions.contains(40))
    }

    func testDevSampleCodecOutput() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = dir.appendingPathComponent(".dev-app-support/sessions.json")
        guard let json = try? Data(contentsOf: url) else { throw XCTSkip("no dev sample") }
        struct File: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = try decoder.decode(File.self, from: json).sessions
        let payload = try TransferCodec.encode(settings: .defaults, sessions: sessions)
        _ = try check(payload)
    }
}
#endif
