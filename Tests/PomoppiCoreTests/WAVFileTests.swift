import XCTest
@testable import PomoppiCore

final class WAVFileTests: XCTestCase {
    private func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
    private func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    func testHeaderFieldsForKnownInput() {
        let pcm: [UInt8] = [1, 2, 3, 4]
        let bytes = WAVFile.data(pcm: pcm, sampleRate: 44100, bitsPerSample: 16, channels: 1)

        XCTAssertEqual(bytes.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(u32(bytes, 4), 36 + UInt32(pcm.count), "RIFF chunk size: 36 + data size")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: bytes[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(u32(bytes, 16), 16, "fmt chunk size: 16 for PCM, no extension")
        XCTAssertEqual(u16(bytes, 20), 1, "audioFormat: 1 = PCM")
        XCTAssertEqual(u16(bytes, 22), 1, "channels")
        XCTAssertEqual(u32(bytes, 24), 44100, "sampleRate")
        XCTAssertEqual(u32(bytes, 28), 44100 * 1 * 2, "byte rate: sampleRate * channels * bytesPerSample")
        XCTAssertEqual(u16(bytes, 32), 2, "block align: channels * bytesPerSample")
        XCTAssertEqual(u16(bytes, 34), 16, "bitsPerSample")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(bytes, 40), UInt32(pcm.count), "data chunk size")
        XCTAssertEqual(Array(bytes[44...]), pcm)
    }
}
