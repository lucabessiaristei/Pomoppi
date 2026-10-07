import XCTest
@testable import PomoppiCore

final class QREncoderTests: XCTestCase {
    func testCapacityTable() {
        XCTAssertEqual(QRCode.byteCapacity(version: 1), 14)
        XCTAssertEqual(QRCode.byteCapacity(version: 10), 213)
        XCTAssertEqual(QRCode.byteCapacity(version: 40), 2331)
        XCTAssertEqual(QRCode.maxByteCount, 2331)
        XCTAssertEqual(QRCode.version(forByteCount: 0), 1)
        XCTAssertEqual(QRCode.version(forByteCount: 14), 1)
        XCTAssertEqual(QRCode.version(forByteCount: 15), 2)
        XCTAssertEqual(QRCode.version(forByteCount: 213), 10)
        XCTAssertEqual(QRCode.version(forByteCount: 214), 11)
        XCTAssertEqual(QRCode.version(forByteCount: 2331), 40)
        XCTAssertNil(QRCode.version(forByteCount: 2332))
        XCTAssertNil(QRCode.encode(Data(count: 2332)))
    }

    // The block table must account for exactly the symbol's codeword count
    // (modules minus function patterns, / 8) in every version.
    func testBlockTableMatchesRawCodewordCount() {
        for version in 1...40 {
            let layout = QRCode.Layout(version: version)
            let free = layout.isFunction.filter { !$0 }.count
            let t = QRCode.blockTable[version - 1]
            let total = t.n1 * (t.d1 + t.ec) + t.n2 * (t.d2 + t.ec)
            XCTAssertEqual(free / 8, total, "version \(version)")
            XCTAssertEqual(QRCode.alignmentPositions(version: version).count, version == 1 ? 0 : version / 7 + 2)
        }
    }

    // Published HELLO WORLD 1-M example (thonky.com): its 16 data codewords
    // and 10 EC codewords.
    func testReedSolomonPublishedVector() {
        let data: [UInt8] = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        XCTAssertEqual(QRCode.reedSolomon(data, ecCount: 10), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
    }

    func testInterleavingSingleBlockIsDataThenEC() {
        let data = (0..<16).map { UInt8($0) }
        let out = QRCode.interleavedCodewords(data, version: 1)
        XCTAssertEqual(Array(out.prefix(16)), data)
        XCTAssertEqual(Array(out.suffix(10)), QRCode.reedSolomon(data, ecCount: 10))
    }

    func testInterleavingMultiBlockColumnOrder() {
        // v5-M: 2 blocks of 43 data + 24 EC each.
        let data = (0..<86).map { UInt8($0) }
        let out = QRCode.interleavedCodewords(data, version: 5)
        XCTAssertEqual(out.count, 86 + 48)
        XCTAssertEqual(Array(out.prefix(4)), [0, 43, 1, 44])
        let ec0 = QRCode.reedSolomon(Array(data[0..<43]), ecCount: 24)
        let ec1 = QRCode.reedSolomon(Array(data[43..<86]), ecCount: 24)
        XCTAssertEqual(Array(out[86..<88]), [ec0[0], ec1[0]])
    }

    func testFormatBitsForLevelM() {
        let expected = [
            0b101010000010010, 0b101000100100101, 0b101111001111100, 0b101101101001011,
            0b100010111111001, 0b100000011001110, 0b100111110010111, 0b100101010100000,
        ]
        for mask in 0..<8 { XCTAssertEqual(QRCode.formatBits(mask: mask), expected[mask], "mask \(mask)") }
    }

    func testVersionBits() {
        XCTAssertEqual(QRCode.versionBits(7), 0x07C94)
        XCTAssertEqual(QRCode.versionBits(8), 0x085BC)
        XCTAssertEqual(QRCode.versionBits(40), 0x28C69)
    }

    func testFunctionPatternsPlaced() throws {
        let code = try XCTUnwrap(QRCode.encode(Data("hello".utf8)))
        XCTAssertEqual(code.version, 1)
        XCTAssertEqual(code.size, 21)
        // Finder rings at the three corners.
        for (ox, oy) in [(0, 0), (14, 0), (0, 14)] {
            XCTAssertTrue(code[ox, oy] && code[ox + 6, oy] && code[ox, oy + 6] && code[ox + 6, oy + 6])
            XCTAssertFalse(code[ox + 1, oy + 1])
            XCTAssertTrue(code[ox + 3, oy + 3])
        }
        // Timing pattern and the fixed dark module.
        for i in 8..<13 { XCTAssertEqual(code[i, 6], i % 2 == 0); XCTAssertEqual(code[6, i], i % 2 == 0) }
        XCTAssertTrue(code[8, 21 - 8])
        // Format info is the chosen mask's, in both copies.
        let bits = QRCode.formatBits(mask: code.mask)
        for i in 0..<8 { XCTAssertEqual(code[20 - i, 8], (bits >> i) & 1 == 1) }
        for i in 0...5 { XCTAssertEqual(code[8, i], (bits >> i) & 1 == 1) }
    }

    func testVersionInfoAndAlignmentPlaced() throws {
        let code = try XCTUnwrap(QRCode.encode(Data(count: 150)))
        XCTAssertGreaterThanOrEqual(code.version, 7)
        let bits = QRCode.versionBits(code.version)
        let s = code.size
        for i in 0..<18 {
            let bit = (bits >> i) & 1 == 1
            XCTAssertEqual(code[s - 11 + i % 3, i / 3], bit)
            XCTAssertEqual(code[i / 3, s - 11 + i % 3], bit)
        }
        // v7 alignment centres 6/22/38: the (22,22) centre is dark, ring light.
        let v7 = try XCTUnwrap(QRCode.encode(Data(count: 110)))
        XCTAssertEqual(v7.version, 7)
        XCTAssertTrue(v7[22, 22])
        XCTAssertFalse(v7[23, 22])
        XCTAssertTrue(v7[24, 24])
    }

    func testDeterministicAndVersionsGrow() throws {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        XCTAssertEqual(QRCode.encode(payload), QRCode.encode(payload))
        let small = try XCTUnwrap(QRCode.encode(Data([1])))
        let big = try XCTUnwrap(QRCode.encode(payload))
        XCTAssertLessThan(small.size, big.size)
        XCTAssertEqual(try XCTUnwrap(QRCode.encode(Data(count: 2331))).version, 40)
        XCTAssertEqual(try XCTUnwrap(QRCode.encode(Data(count: 2331))).size, 177)
    }

    func testTransferSizeQRSide() {
        XCTAssertEqual(TransferSize(bytes: 10, textCodeLength: 20).qrSide, 21)
        XCTAssertEqual(TransferSize(bytes: 2331, textCodeLength: 0).qrSide, 177)
        XCTAssertNil(TransferSize(bytes: 2332, textCodeLength: 0).qrSide)
    }
}
