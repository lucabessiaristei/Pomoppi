// PixelCanvas+CoreGraphics.swift — the one CoreGraphics-dependent piece of
// PixelCanvas: exporting its raw byte buffer as a CGImage for macOS callers
// to draw. Kept in its own file (rather than PixelCanvas.swift itself) so
// the drawing kit stays a plain, zero-platform-import byte buffer — this is
// the seam a future Windows/GDI adapter (PixelCanvas+GDI.swift, not this
// phase) sits next to.
#if canImport(CoreGraphics)
import CoreGraphics

extension PixelCanvas {
    public func makeImage() -> CGImage? {
        buffer.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let ctx = CGContext(
                data: rawBuffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.setAllowsAntialiasing(false)
            return ctx.makeImage()
        }
    }
}
#endif
