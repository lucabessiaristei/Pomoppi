// AppStorage.swift — Windows counterpart to AppDelegate.storageDir(): the
// settings storage directory SettingsStore is pointed at, %APPDATA%\Pomoppi,
// resolved via the shell's known-folder API rather than reading the
// environment variable by hand.
import Foundation
import WinSDK

func storageDir() -> URL {
    var pathPtr: PWSTR?
    // SHGetKnownFolderPath wants an UnsafePointer<KNOWNFOLDERID>, and the
    // bare GUID constant FOLDERID_RoamingAppData doesn't implicitly convert
    // to that — go through withUnsafePointer + withMemoryRebound instead.
    let hr = withUnsafePointer(to: FOLDERID_RoamingAppData) { rfid in
        rfid.withMemoryRebound(to: KNOWNFOLDERID.self, capacity: 1) { knownFolderID in
            SHGetKnownFolderPath(knownFolderID, 0, nil, &pathPtr)
        }
    }
    guard hr == S_OK, let pathPtr else {
        fatalError("SHGetKnownFolderPath(FOLDERID_RoamingAppData) failed with HRESULT \(hr)")
    }
    defer { CoTaskMemFree(pathPtr) }
    let roamingAppData = String(decodingCString: pathPtr, as: UTF16.self)
    return URL(fileURLWithPath: roamingAppData).appendingPathComponent("Pomoppi")
}
