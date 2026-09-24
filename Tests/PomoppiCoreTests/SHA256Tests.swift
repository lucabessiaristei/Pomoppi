import XCTest
@testable import PomoppiCore

final class SHA256Tests: XCTestCase {
    // NIST FIPS 180-2 test vectors, plus the "million a" stress vector.
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hexDigest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            SHA256.hexDigest(Data(
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8
            )),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
        let millionA = Data(repeating: 0x61, count: 1_000_000) // 'a'
        XCTAssertEqual(SHA256.hexDigest(millionA), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // Values at and around the 64-byte block boundary, where the padding's
    // "does it need an extra block" branch changes.
    func testBlockBoundaryLengths() {
        let expected: [Int: String] = [
            55: "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59",
            56: "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562",
            63: "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488",
            64: "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108",
            65: "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781",
        ]
        for (length, digest) in expected {
            let bytes = (0..<length).map { UInt8($0 % 256) }
            XCTAssertEqual(SHA256.hexDigest(Data(bytes)), digest, "length \(length)")
        }
    }

    func testStreamingInUnevenChunksMatchesOneShot() {
        let bytes = (0..<5000).map { UInt8($0 % 256) }
        let data = Data(bytes)

        var sha = SHA256()
        sha.update(data.subdata(in: 0..<1))
        sha.update(data.subdata(in: 1..<3))
        sha.update(data.subdata(in: 3..<3)) // empty chunk in the middle
        sha.update(data.subdata(in: 3..<200))
        sha.update(data.subdata(in: 200..<4096))
        sha.update(Array(data.subdata(in: 4096..<5000))) // the [UInt8] overload too
        let streamed = sha.finalize().map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(streamed, SHA256.hexDigest(data))
        XCTAssertEqual(streamed, "8026e5c96cf1e502c8deb3e89f8b8bc342f5039b871911a92eb10edf9c6542d3")
    }

    // Larger than the 64 KiB chunk hexDigest(fileAt:) reads at a time, and
    // not a multiple of it, so the last short read is exercised too.
    func testHexDigestOfFileStreamsInChunks() throws {
        var pattern = [UInt8]()
        pattern.reserveCapacity(200_003)
        for i in 0..<200_003 {
            pattern.append(UInt8((i * 37 + 11) % 256))
        }
        let data = Data(pattern)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SHA256Tests-\(UUID().uuidString).bin")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let digest = try SHA256.hexDigest(fileAt: fileURL)
        XCTAssertEqual(digest, "a087d4f354eba7d5295e77d70d8303a0c7f33f0610288820e1c844beae03030f")
        XCTAssertEqual(digest, SHA256.hexDigest(data))
    }
}
