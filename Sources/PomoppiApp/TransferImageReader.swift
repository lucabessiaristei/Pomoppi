import CoreGraphics
import Foundation
import ImageIO
import Vision
import PomoppiCore

// Image file -> the QR's payload bytes, for the Transfer popup's Receive
// side (SPEC.md §16). Vision first; when it finds nothing or none of its
// payloads pass TransferCodec's checksum, the shared QRDecoder gets the same
// pixels as 8-bit luma.
enum TransferImageReader {
    enum ReadError: Error {
        case file
        case noQR
        case unreadable
    }

    static func payload(fromImageAt url: URL) throws -> Data {
        guard let image = loadImage(url) else { throw ReadError.file }
        if let data = visionPayloads(image).first(where: { (try? TransferCodec.decode($0)) != nil }) { return data }
        guard let (luma, width, height) = lumaBytes(image) else { throw ReadError.file }
        do {
            return try QRDecoder.decode(luma: luma, width: width, height: height)
        } catch QRDecoder.Error.notFound {
            throw ReadError.noQR
        } catch {
            throw ReadError.unreadable
        }
    }

    // The thumbnail path applies the EXIF orientation, so a phone photo
    // arrives upright.
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func visionPayloads(_ image: CGImage) -> [Data] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).flatMap { observation -> [Data] in
            guard let raw = observation.payloadData else { return [] }
            return [8, 16].compactMap { byteModePayload(raw, countBits: $0) }
        }
    }

    // payloadData is the symbol's data codewords (mode, count, bytes,
    // terminator, padding), not the bytes. The count field is 8 bits up to
    // version 9 and 16 from 10, and Vision doesn't say which version it
    // read, so both are tried and the checksum picks.
    private static func byteModePayload(_ raw: Data, countBits: Int) -> Data? {
        let bytes = [UInt8](raw)
        func bits(_ start: Int, _ count: Int) -> Int {
            (start..<start + count).reduce(0) { acc, i in (acc << 1) | Int((bytes[i / 8] >> UInt8(7 - i % 8)) & 1) }
        }
        guard bytes.count * 8 >= 4 + countBits, bits(0, 4) == 0b0100 else { return nil }
        let n = bits(4, countBits)
        guard (4 + countBits + n * 8 + 7) / 8 <= bytes.count else { return nil }
        let start = 4 + countBits
        return Data((0..<n).map { UInt8(bits(start + $0 * 8, 8)) })
    }

    private static func lumaBytes(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let width = image.width, height = image.height
        var luma = [UInt8](repeating: 255, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (luma, width, height) : nil
    }
}
