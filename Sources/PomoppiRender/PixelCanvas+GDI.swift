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

    // Builds a memory DC whose DIB is sized to *exactly* destWidth x
    // destHeight — used by draw(into:) below instead of the unscaled-then-
    // StretchBlt approach that used to live there (see draw(into:)'s own
    // comment for why). Each dest pixel (dx, dy) maps back to its source
    // pixel via plain floor-division integer math, the same nearest-
    // neighbor formula CoreGraphics's own `.interpolation(.none)` already
    // applies for PixelCanvas+CoreGraphics.swift's macOS blits — done by
    // hand here since GDI has no equivalent "just do it right" mode. Same
    // RGBA->BGRA swizzle/alpha-passthrough as makeLayeredBitmap above.
    // Ownership: same as makeLayeredBitmap — caller disposes via
    // SelectObject(hdc, previousBitmap) -> DeleteObject(bitmap) -> DeleteDC(hdc).
    private func makeResampledBitmap(
        destWidth: Int, destHeight: Int,
        cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int
    ) -> (hdc: HDC, bitmap: HBITMAP, previousBitmap: HGDIOBJ?)? {
        guard destWidth > 0, destHeight > 0, cropWidth > 0, cropHeight > 0 else { return nil }

        var bitmapInfo = BITMAPINFO()
        bitmapInfo.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bitmapInfo.bmiHeader.biWidth = Int32(destWidth)
        bitmapInfo.bmiHeader.biHeight = -Int32(destHeight)
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

        let outBytesPerRow = destWidth * 4
        let outBuffer = bits.bindMemory(to: UInt8.self, capacity: outBytesPerRow * destHeight)
        buffer.withUnsafeBufferPointer { src in
            for dy in 0..<destHeight {
                let srcY = cropY + dy * cropHeight / destHeight
                for dx in 0..<destWidth {
                    let srcX = cropX + dx * cropWidth / destWidth
                    let srcOffset = srcY * bytesPerRow + srcX * 4
                    let outOffset = dy * outBytesPerRow + dx * 4
                    outBuffer[outOffset] = src[srcOffset + 2]     // B
                    outBuffer[outOffset + 1] = src[srcOffset + 1] // G
                    outBuffer[outOffset + 2] = src[srcOffset]     // R
                    outBuffer[outOffset + 3] = src[srcOffset + 3] // A
                }
            }
        }

        return (hdc, bitmap, previousBitmap)
    }

    // Blits an optionally-cropped region of this canvas into an arbitrary
    // destination device context, scaled to fill destRect — used by the
    // Appearance tab's owner-drawn picker cards (Sources/PomoppiWindows/
    // SettingsWindow.swift's WM_DRAWITEM handling), unlike
    // makeLayeredBitmap's other caller (WidgetWindow's UpdateLayeredWindow
    // loop, always at a fixed integer scale with caller-managed GDI object
    // lifetime). Used to build an unscaled memory DC via
    // makeLayeredBitmap(scale: 1) and hand the scaling to StretchBlt's
    // COLORONCOLOR mode — but COLORONCOLOR is a fast pixel-replication/
    // decimation mode that produces visibly uneven, non-uniform scaling
    // artifacts at non-integer ratios (every picker card here has one:
    // friend cards are 1.75x their native sprite, frameStyle ~1.127x,
    // background ~0.87x downscale), confirmed by a real screenshot showing
    // the grainy/aliased edges this was reported as. Rebuilt on
    // makeResampledBitmap above instead: it builds the DIB at destRect's
    // exact pixel size up front, so this is now a plain 1:1 BitBlt, no
    // GDI stretch mode involved anywhere.
    public func draw(into destDC: HDC?, destRect: RECT, cropX: Int = 0, cropY: Int = 0, cropWidth: Int? = nil, cropHeight: Int? = nil) {
        let srcWidth = cropWidth ?? width
        let srcHeight = cropHeight ?? height
        let destWidth = Int(destRect.right - destRect.left)
        let destHeight = Int(destRect.bottom - destRect.top)
        guard let (memDC, bitmap, previousBitmap) = makeResampledBitmap(
            destWidth: destWidth, destHeight: destHeight,
            cropX: cropX, cropY: cropY, cropWidth: srcWidth, cropHeight: srcHeight
        ) else { return }
        defer {
            SelectObject(memDC, previousBitmap)
            DeleteObject(bitmap)
            DeleteDC(memDC)
        }
        BitBlt(destDC, destRect.left, destRect.top, Int32(destWidth), Int32(destHeight), memDC, 0, 0, DWORD(SRCCOPY))
    }
}
#endif
