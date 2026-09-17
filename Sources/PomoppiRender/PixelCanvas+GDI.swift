// PixelCanvas+GDI.swift — the Windows counterpart to
// PixelCanvas+CoreGraphics.swift: exporting the raw RGBA byte buffer as a
// GDI device context with a selected-in bitmap, ready for
// UpdateLayeredWindow (WidgetWindow, a later phase). Two things this app's
// own drawing guarantees make simpler than the general case:
//   - Channel order: PixelCanvas's buffer is RGBA; GDI bitmaps are BGRA, so
//     R and B are swapped per pixel below.
//   - Alpha: every pixel PixelCanvas ever draws is alpha 0 (untouched) or
//     255 (opaque), never partial. ULW_ALPHA wants premultiplied alpha, but
//     premultiplication is a no-op at both of those values (at A=255,
//     premultiplied RGB == original RGB; at A=0 the pixel is invisible
//     regardless of RGB) — so R/G/B are copied straight through
//     un-premultiplied rather than running any real premultiply math.
#if os(Windows)
import WinSDK

extension PixelCanvas {
    // Builds a memory DC with a top-down 32bpp DIB section selected into it,
    // upscaled from this canvas by `scale` via integer nearest-neighbor (no
    // interpolation — this app never draws pre-scaled, every platform blits
    // the logical-size canvas scaled up hard-edged). Returns nil if any GDI
    // call fails.
    //
    // Ownership: the caller owns every GDI object returned here. Dispose in
    // this order once done with them: SelectObject(hdc, previousBitmap) to
    // put the DC's original (stock) bitmap back, then DeleteObject(bitmap),
    // then DeleteDC(hdc). Deleting the DC while `bitmap` is still selected
    // into it (skipping the SelectObject-back step) leaks the bitmap handle.
    public func makeLayeredBitmap(scale: Int) -> (hdc: HDC, bitmap: HBITMAP, previousBitmap: HGDIOBJ?, size: SIZE)? {
        guard scale > 0 else { return nil }
        let outWidth = width * scale
        let outHeight = height * scale

        var bitmapInfo = BITMAPINFO()
        bitmapInfo.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bitmapInfo.bmiHeader.biWidth = Int32(outWidth)
        // Negative height = top-down DIB, so row 0 is the top row — matches
        // PixelCanvas's own row-0-is-top convention (see PixelCanvas.swift),
        // no coordinate flip needed.
        bitmapInfo.bmiHeader.biHeight = -Int32(outHeight)
        bitmapInfo.bmiHeader.biPlanes = 1
        bitmapInfo.bmiHeader.biBitCount = 32
        bitmapInfo.bmiHeader.biCompression = DWORD(BI_RGB)

        guard let hdc = CreateCompatibleDC(nil) else { return nil }

        var bitsPtr: UnsafeMutableRawPointer?
        guard let bitmap = CreateDIBSection(hdc, &bitmapInfo, UINT(DIB_RGB_COLORS), &bitsPtr, nil, 0), let bits = bitsPtr else {
            DeleteDC(hdc)
            return nil
        }

        let previousBitmap = SelectObject(hdc, bitmap)

        let outBytesPerRow = outWidth * 4
        let outBuffer = bits.bindMemory(to: UInt8.self, capacity: outBytesPerRow * outHeight)
        buffer.withUnsafeBufferPointer { src in
            for y in 0..<height {
                for x in 0..<width {
                    let srcOffset = y * bytesPerRow + x * 4
                    let r = src[srcOffset]
                    let g = src[srcOffset + 1]
                    let b = src[srcOffset + 2]
                    let a = src[srcOffset + 3]
                    for dy in 0..<scale {
                        let outY = y * scale + dy
                        var outOffset = outY * outBytesPerRow + x * scale * 4
                        for _ in 0..<scale {
                            outBuffer[outOffset] = b
                            outBuffer[outOffset + 1] = g
                            outBuffer[outOffset + 2] = r
                            outBuffer[outOffset + 3] = a
                            outOffset += 4
                        }
                    }
                }
            }
        }

        return (hdc, bitmap, previousBitmap, SIZE(cx: Int32(outWidth), cy: Int32(outHeight)))
    }
}
#endif
