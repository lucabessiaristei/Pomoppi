// UpdateInstaller.swift — the Windows side of the in-app update
// (UPDATE_PLAN.md S6e): download the release's Setup .exe to %TEMP%, verify
// it, delete any Mark-of-the-Web stream, and run it with /SILENT. Inno Setup
// then closes Pomoppi through RestartManager (CloseApplications=yes),
// installs, and relaunches it (the WizardSilent [Run] entry).
//
// Owned by AppUpdateChecker. URLSession's delegate callbacks arrive on its
// own queue, never the message loop's thread, so every state change goes
// through `post`, which marshals it back (AppUpdateChecker's PostMessageW
// hop), the same as the update check's own results.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PomoppiCore
import WinSDK

final class UpdateInstaller: NSObject, URLSessionDownloadDelegate {
    var onStateChange: ((UpdateInstallState) -> Void)?

    private let post: (@escaping () -> Void) -> Void
    // Touched only on the message-loop thread: start/cancel run there, and
    // every delegate callback does its work inside `post`.
    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var asset: ReleaseAsset?
    private var lastProgressReport = Date.distantPast

    init(post: @escaping (@escaping () -> Void) -> Void) {
        self.post = post
    }

    func start(_ asset: ReleaseAsset) {
        cancel()
        self.asset = asset
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("Pomoppi/\(pomoppiVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        activeTask = task
        report(.downloading(received: 0, total: Int64(asset.size)))
        task.resume()
    }

    func cancel() {
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        asset = nil
        report(.idle)
    }

    private func report(_ state: UpdateInstallState) {
        onStateChange?(state)
    }

    private func fail(_ failure: UpdateInstallFailure) {
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        asset = nil
        report(.failed(failure))
    }

    // -- URLSessionDownloadDelegate (URLSession's own queue) -----------------

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        post { [weak self] in
            guard let self, downloadTask === self.activeTask, let asset = self.asset else { return }
            // ~10 repaints a second: every state change is a real
            // relabel on the message loop.
            let now = Date()
            guard now.timeIntervalSince(self.lastProgressReport) >= 0.1 else { return }
            self.lastProgressReport = now
            self.report(.downloading(received: totalBytesWritten, total: Int64(asset.size)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // `location` is deleted as soon as this returns: move it now, on
        // this queue, and verify it here too (off the message loop).
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PomoppiUpdate-\(UUID().uuidString)")
        let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "Pomoppi-Setup.exe"
        let setupExe = folder.appendingPathComponent(fileName)
        var moved = false
        if (200..<300).contains(httpStatus) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: setupExe)
                moved = true
            } catch {
                moved = false
            }
        }
        post { [weak self] in
            guard let self, downloadTask === self.activeTask, let asset = self.asset else { return }
            guard moved else {
                self.fail(.downloadFailed)
                return
            }
            self.report(.verifying)
            DispatchQueue.global().async { [weak self] in
                let failure = asset.verify(downloadedFileAt: setupExe)
                self?.post { [weak self] in
                    guard let self, downloadTask === self.activeTask else { return }
                    if let failure {
                        self.fail(failure)
                        return
                    }
                    self.launch(setupExe)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { return }
        post { [weak self] in
            guard let self, task === self.activeTask else { return }
            self.fail(.downloadFailed)
        }
    }

    // -- launching -------------------------------------------------------------

    private func launch(_ setupExe: URL) {
        activeTask = nil
        session?.finishTasksAndInvalidate()
        session = nil
        asset = nil
        let path = setupExe.withUnsafeFileSystemRepresentation { String(cString: $0!) }
            .replacingOccurrences(of: "/", with: "\\")
        // Only ever on a file whose size and digest just matched the
        // release's own. URLSession writes no Mark of the Web anyway; this
        // keeps an update free of SmartScreen prompts if that ever changes.
        _ = (path + ":Zone.Identifier").withCString(encodedAs: UTF16.self) { DeleteFileW($0) }

        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("Pomoppi-update.log")
            .withUnsafeFileSystemRepresentation { String(cString: $0!) }
            .replacingOccurrences(of: "/", with: "\\")
        let parameters = "/SILENT /SUPPRESSMSGBOXES /NORESTART /LOG=\"\(logPath)\""
        let result = "open".withCString(encodedAs: UTF16.self) { verb in
            path.withCString(encodedAs: UTF16.self) { file in
                parameters.withCString(encodedAs: UTF16.self) { params in
                    ShellExecuteW(nil, verb, file, params, nil, SW_SHOWNORMAL)
                }
            }
        }
        // ShellExecuteW's HINSTANCE is really an error code: > 32 is success.
        let code = Int(bitPattern: result)
        report(code > 32 ? .installerOpened : .failed(.installerLaunchFailed))
    }

    // -- which copies can self-update ------------------------------------------

    // Inno's per-user uninstall key for this AppId (Scripts/pomoppi.iss)
    // records where it installed Pomoppi. A copy running from anywhere else
    // (a dist\ build, an old unzipped portable copy) wasn't installed by
    // Inno: running the setup would install a second copy and leave this one
    // stale, so it gets the release page only.
    static var isRunningInstalledCopy: Bool {
        guard let installLocation = registryString(
                subKey: "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{EC3E39B4-1C22-4A15-A54C-769ACA07A1C8}_is1",
                value: "InstallLocation"),
              let exePath = runningExePath() else { return false }
        let exeFolder = (exePath as NSString).deletingLastPathComponent
        return normalized(exeFolder) == normalized(installLocation)
    }

    private static func normalized(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "/", with: "\\").lowercased()
        while p.hasSuffix("\\") { p.removeLast() }
        return p
    }

    private static func runningExePath() -> String? {
        var buffer = [UInt16](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func registryString(subKey: String, value: String) -> String? {
        var size: DWORD = 0
        let probe = subKey.withCString(encodedAs: UTF16.self) { subKeyPtr in
            value.withCString(encodedAs: UTF16.self) { valuePtr in
                RegGetValueW(HKEY_CURRENT_USER, subKeyPtr, valuePtr, DWORD(RRF_RT_REG_SZ), nil, nil, &size)
            }
        }
        guard probe == ERROR_SUCCESS, size > 1 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
        let status = subKey.withCString(encodedAs: UTF16.self) { subKeyPtr in
            value.withCString(encodedAs: UTF16.self) { valuePtr in
                buffer.withUnsafeMutableBytes { bytes in
                    RegGetValueW(HKEY_CURRENT_USER, subKeyPtr, valuePtr, DWORD(RRF_RT_REG_SZ), nil, bytes.baseAddress, &size)
                }
            }
        }
        guard status == ERROR_SUCCESS else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end], as: UTF16.self)
    }
}
