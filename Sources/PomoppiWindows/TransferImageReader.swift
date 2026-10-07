// TransferImageReader.swift — image file -> 8-bit luma buffer for
// QRDecoder (the Transfer window's Receive side, SPEC.md §16). GDI+'s flat
// API, loaded by hand: gdiplus.dll isn't in the default link set (same
// situation as uxtheme's SetWindowTheme, see SettingsWindow.swift), and its
// C++-flavoured header isn't imported by WinSDK. WIC would need hand-built
// COM vtables; the flat API is eight plain functions. Decodes PNG, JPEG,
// BMP, GIF and TIFF, whatever the installed codecs handle.
import Foundation
import WinSDK

enum TransferImageReader {
    struct Luma {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    // GdiplusStartupInput / BitmapData / Rect, laid out as gdiplus does.
    // Passed through raw pointers, since @convention(c) types can't name
    // Swift structs.
    private struct StartupInput {
        var gdiplusVersion: UInt32 = 1
        var debugEventCallback: UnsafeRawPointer? = nil
        var suppressBackgroundThread: Int32 = 0
        var suppressExternalCodecs: Int32 = 0
    }

    private struct BitmapData {
        var width: UInt32 = 0
        var height: UInt32 = 0
        var stride: Int32 = 0
        var pixelFormat: Int32 = 0
        var scan0: UnsafeMutableRawPointer? = nil
        var reserved: UInt = 0
    }

    private struct Rect {
        var x: Int32
        var y: Int32
        var width: Int32
        var height: Int32
    }

    private typealias StartupProc = @convention(c) (UnsafeMutablePointer<UInt>, UnsafeRawPointer, UnsafeRawPointer?) -> Int32
    private typealias CreateFromFileProc = @convention(c) (UnsafePointer<UInt16>, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias GetSizeProc = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias LockBitsProc = @convention(c) (OpaquePointer?, UnsafeRawPointer, UInt32, Int32, UnsafeMutableRawPointer) -> Int32
    private typealias UnlockBitsProc = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer) -> Int32
    private typealias DisposeProc = @convention(c) (OpaquePointer?) -> Int32

    private struct Api {
        let createFromFile: CreateFromFileProc
        let getWidth: GetSizeProc
        let getHeight: GetSizeProc
        let lockBits: LockBitsProc
        let unlockBits: UnlockBitsProc
        let dispose: DisposeProc
    }

    // Started once and kept for the process's life; nil if gdiplus.dll or
    // any of its functions is missing.
    private static let api: Api? = {
        let name: [UInt16] = Array("gdiplus.dll".utf16) + [0]
        guard let module = (name.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }),
              let startup = GetProcAddress(module, "GdiplusStartup"),
              let create = GetProcAddress(module, "GdipCreateBitmapFromFile"),
              let width = GetProcAddress(module, "GdipGetImageWidth"),
              let height = GetProcAddress(module, "GdipGetImageHeight"),
              let lock = GetProcAddress(module, "GdipBitmapLockBits"),
              let unlock = GetProcAddress(module, "GdipBitmapUnlockBits"),
              let dispose = GetProcAddress(module, "GdipDisposeImage")
        else { return nil }
        var token: UInt = 0
        var input = StartupInput()
        let status = withUnsafePointer(to: &input) {
            unsafeBitCast(startup, to: StartupProc.self)(&token, UnsafeRawPointer($0), nil)
        }
        guard status == 0 else { return nil }
        return Api(
            createFromFile: unsafeBitCast(create, to: CreateFromFileProc.self),
            getWidth: unsafeBitCast(width, to: GetSizeProc.self),
            getHeight: unsafeBitCast(height, to: GetSizeProc.self),
            lockBits: unsafeBitCast(lock, to: LockBitsProc.self),
            unlockBits: unsafeBitCast(unlock, to: UnlockBitsProc.self),
            dispose: unsafeBitCast(dispose, to: DisposeProc.self))
    }()

    private static let imageLockModeRead: UInt32 = 1
    private static let pixelFormat32bppARGB: Int32 = 0x0026200A

    // nil when the file can't be opened or isn't an image GDI+ understands.
    // Transparent pixels are composited on white, so a QR with an alpha
    // background still reads dark-on-light.
    static func luma(fromFileAt path: String) -> Luma? {
        guard let api else { return nil }
        var bitmap: OpaquePointer?
        let wide = Array(path.utf16) + [0]
        let created = wide.withUnsafeBufferPointer { api.createFromFile($0.baseAddress!, &bitmap) }
        guard created == 0, let bitmap else { return nil }
        defer { _ = api.dispose(bitmap) }

        var w: UInt32 = 0
        var h: UInt32 = 0
        guard api.getWidth(bitmap, &w) == 0, api.getHeight(bitmap, &h) == 0, w > 0, h > 0 else { return nil }
        let width = Int(w), height = Int(h)

        var rect = Rect(x: 0, y: 0, width: Int32(width), height: Int32(height))
        var data = BitmapData()
        let locked = withUnsafePointer(to: &rect) { rectPtr in
            withUnsafeMutablePointer(to: &data) { dataPtr in
                api.lockBits(bitmap, UnsafeRawPointer(rectPtr), imageLockModeRead, pixelFormat32bppARGB, UnsafeMutableRawPointer(dataPtr))
            }
        }
        guard locked == 0, let scan0 = data.scan0 else { return nil }
        defer {
            _ = withUnsafeMutablePointer(to: &data) { api.unlockBits(bitmap, UnsafeMutableRawPointer($0)) }
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let stride = Int(data.stride)
        for y in 0..<height {
            let row = (scan0 + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                // Memory order is B, G, R, A.
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2]), a = Int(row[x * 4 + 3])
                let y8 = (299 * r + 587 * g + 114 * b) / 1000
                pixels[y * width + x] = UInt8((y8 * a + 255 * (255 - a)) / 255)
            }
        }
        return Luma(pixels: pixels, width: width, height: height)
    }
}
