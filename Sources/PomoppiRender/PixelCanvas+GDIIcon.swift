// PixelCanvas+GDIIcon.swift — the tray-icon counterpart to
// PixelCanvas+GDI.swift's makeLayeredBitmap: converts an already-drawn
// canvas into a real HICON for Shell_NotifyIcon (Sources/PomoppiWindows/
// TrayController.swift, Phase W4). Kept as its own file rather than folding
// into PixelCanvas+GDI.swift since it's a distinct GDI object (HICON, not a
// layered-window bitmap) with its own two-bitmap construction and disposal
// dance.
#if os(Windows)
import WinSDK

extension PixelCanvas {
    // Builds an HICON straight from this canvas's already-drawn pixels — no
    // scale parameter, tray icons are a fixed small size (always built at
    // 16x16 here, see TrayIconFrames above). Same RGBA->BGRA swizzle/
    // alpha-passthrough logic as makeLayeredBitmap (this app's pixels are
    // always alpha 0 or 255, so a straight copy is correct, not a real
    // premultiply).
    //
    // Ownership: CreateIconIndirect copies the bitmap data it's given and
    // takes no ownership of either GDI object — both are deleted here
    // before returning, success or failure, same discipline
    // makeLayeredBitmap's own callers use for its output.
    public func makeIcon() -> HICON? {
        var bitmapInfo = BITMAPINFO()
        bitmapInfo.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bitmapInfo.bmiHeader.biWidth = Int32(width)
        bitmapInfo.bmiHeader.biHeight = -Int32(height)
        bitmapInfo.bmiHeader.biPlanes = 1
        bitmapInfo.bmiHeader.biBitCount = 32
        bitmapInfo.bmiHeader.biCompression = DWORD(BI_RGB)

        guard let hdc = CreateCompatibleDC(nil) else { return nil }
        var bitsPtr: UnsafeMutableRawPointer?
        guard let colorBitmap = CreateDIBSection(hdc, &bitmapInfo, UINT(DIB_RGB_COLORS), &bitsPtr, nil, 0), let bits = bitsPtr else {
            DeleteDC(hdc)
            return nil
        }
        // Never selected into hdc (nothing draws onto it via GDI calls —
        // the pixel copy below writes straight into the DIB section's
        // backing memory), so the DC can go the moment the bitmap exists.
        DeleteDC(hdc)

        guard let maskBitmap = CreateBitmap(Int32(width), Int32(height), 1, 1, nil) else {
            DeleteObject(colorBitmap)
            return nil
        }
        defer {
            DeleteObject(colorBitmap)
            DeleteObject(maskBitmap)
        }

        let outBytesPerRow = width * 4
        let outBuffer = bits.bindMemory(to: UInt8.self, capacity: outBytesPerRow * height)
        buffer.withUnsafeBufferPointer { src in
            for y in 0..<height {
                for x in 0..<width {
                    let srcOffset = y * bytesPerRow + x * 4
                    let dstOffset = y * outBytesPerRow + x * 4
                    outBuffer[dstOffset] = src[srcOffset + 2]     // B
                    outBuffer[dstOffset + 1] = src[srcOffset + 1] // G
                    outBuffer[dstOffset + 2] = src[srcOffset]     // R
                    outBuffer[dstOffset + 3] = src[srcOffset + 3] // A
                }
            }
        }

        var iconInfo = ICONINFO()
        iconInfo.fIcon = true
        iconInfo.hbmMask = maskBitmap
        iconInfo.hbmColor = colorBitmap
        return CreateIconIndirect(&iconInfo)
    }
}
#endif
