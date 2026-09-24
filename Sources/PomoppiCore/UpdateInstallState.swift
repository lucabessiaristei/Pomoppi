// UpdateInstallState.swift — the in-app update's download/verify/launch
// state, shared by both platforms' UpdateInstaller.swift and the General
// tab's Updates row (UPDATE_PLAN.md "States and the Updates row"). No
// networking here: each platform owns its own URLSession download and
// installer launch; this file only holds the state they report and the
// post-download integrity check, which is the same on both.
//
// The state lives on AppUpdateChecker, never on the settings window, so a
// download survives closing and reopening it (Windows destroys the window).
import Foundation

public enum UpdateInstallFailure: Equatable {
    case downloadFailed
    case incompleteDownload
    case checksumMismatch
    case installerLaunchFailed

    // One clause, never an error code; the row renders it as
    // "Update failed: <clause>" next to Try again / Open release page.
    public var clause: String {
        switch self {
        case .downloadFailed: return "couldn't download"
        case .incompleteDownload: return "the download was incomplete"
        case .checksumMismatch: return "the download didn't match its checksum"
        case .installerLaunchFailed: return "couldn't start the installer"
        }
    }
}

public enum UpdateInstallState: Equatable {
    case idle
    // `total` is the asset's API-reported size, not Content-Length.
    case downloading(received: Int64, total: Int64)
    case verifying
    case installerOpened
    case failed(UpdateInstallFailure)

    // True while a click on Update must not start a second download.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installerOpened: return true
        case .idle, .failed: return false
        }
    }
}

extension ReleaseAsset {
    // Byte count must equal the API's `size`; SHA-256 must equal `digest`
    // when the release carries one. nil means the file passed. Only a file
    // that passed may have its quarantine / Mark-of-the-Web marker stripped
    // and be launched.
    public func verify(downloadedFileAt url: URL) -> UpdateInstallFailure? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let rawSize = attributes[.size] else { return .downloadFailed }
        // Darwin hands back an NSNumber, swift-corelibs-foundation (Windows)
        // may hand back a bare UInt64.
        let fileSize: Int
        if let n = rawSize as? NSNumber {
            fileSize = n.intValue
        } else if let n = rawSize as? UInt64 {
            fileSize = Int(n)
        } else {
            return .downloadFailed
        }
        guard fileSize == size else { return .incompleteDownload }
        guard let expected = sha256 else { return nil }
        guard let actual = try? SHA256.hexDigest(fileAt: url) else { return .downloadFailed }
        return actual == expected ? nil : .checksumMismatch
    }
}
