// UpdateInstaller.swift — the macOS side of the in-app update
// (UPDATE_PLAN.md S6c): download the release's .pkg, verify it, strip any
// quarantine marker, and hand it to Installer.app. Installer.app shows its
// own UI and password prompt; the pkg's postinstall kills and relaunches
// Pomoppi. If the user cancels the installer, nothing has changed.
//
// Owned by AppUpdateChecker, which publishes `state` to the settings row and
// the tray, so a download outlives the settings window. Verified packages
// are kept in ~/Library/Caches/Pomoppi/Updates, so pressing Update again
// (after closing Installer.app, or after relaunching Pomoppi) reuses one that
// still verifies instead of downloading it again; packages for versions at
// or below the running one are pruned at launch.
import AppKit
import Foundation
import PomoppiCore

final class UpdateInstaller: NSObject, URLSessionDownloadDelegate {
    var onStateChange: ((UpdateInstallState) -> Void)?
    // true when Installer.app is opened on the package, false when it quits:
    // AppDelegate drops the floating widget below it meanwhile.
    var onInstallerRunningChange: ((Bool) -> Void)?

    private var session: URLSession?
    private var asset: ReleaseAsset?
    private var downloadedPackage: URL?
    private var lastProgressReport = Date.distantPast

    static var cacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Pomoppi/Updates", isDirectory: true)
    }

    // Drops cached packages that are no newer than the running version: once
    // the update is installed, its package is just disk space.
    static func pruneCache(currentVersion: String) {
        guard let current = SemVer(currentVersion),
              let names = try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path) else { return }
        for name in names {
            let version = name.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
                .flatMap { SemVer(String(name[$0])) }
            if let version, version > current { continue }
            try? FileManager.default.removeItem(at: cacheFolder.appendingPathComponent(name))
        }
    }

    func start(_ asset: ReleaseAsset) {
        cancel()
        self.asset = asset
        let cached = Self.cacheFolder.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: cached.path) {
            verifyAndOpen(cached, asset: asset)
            return
        }
        // The delegate callbacks land on the main queue, where the state is
        // read; URLSession keeps its delegate alive until invalidated.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("Pomoppi/\(pomoppiVersion)", forHTTPHeaderField: "User-Agent")
        report(.downloading(received: 0, total: Int64(asset.size)))
        session.downloadTask(with: request).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        asset = nil
        report(.idle)
    }

    // Installer.app was closed or cancelled but the verified package is
    // still on disk: open it again rather than downloading it twice.
    func reopenInstaller() {
        guard let downloadedPackage, FileManager.default.fileExists(atPath: downloadedPackage.path) else {
            report(.failed(.installerLaunchFailed))
            return
        }
        report(openInstaller(downloadedPackage) ? .installerOpened : .failed(.installerLaunchFailed))
    }

    private var terminationObserver: NSObjectProtocol?

    private func openInstaller(_ package: URL) -> Bool {
        guard NSWorkspace.shared.open(package) else { return false }
        onInstallerRunningChange?(true)
        if terminationObserver == nil {
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.installer" else { return }
                self?.onInstallerRunningChange?(false)
            }
        }
        return true
    }

    private func report(_ state: UpdateInstallState) {
        onStateChange?(state)
    }

    private func fail(_ failure: UpdateInstallFailure) {
        session?.invalidateAndCancel()
        session = nil
        asset = nil
        report(.failed(failure))
    }

    // -- URLSessionDownloadDelegate -------------------------------------------

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard session === self.session, let asset else { return }
        // ~10 updates a second is plenty for a progress bar.
        let now = Date()
        guard now.timeIntervalSince(lastProgressReport) >= 0.1 else { return }
        lastProgressReport = now
        report(.downloading(received: totalBytesWritten, total: Int64(asset.size)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard session === self.session, let asset else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(.downloadFailed)
            return
        }
        // `location` is deleted as soon as this method returns, so the move
        // has to happen here, synchronously.
        let package = Self.cacheFolder.appendingPathComponent(asset.name)
        do {
            try FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.moveItem(at: location, to: package)
        } catch {
            fail(.downloadFailed)
            return
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        verifyAndOpen(package, asset: asset)
    }

    // Also the path for a package already in the cache: it's re-verified
    // every time, so a partial or tampered file is never opened.
    private func verifyAndOpen(_ package: URL, asset: ReleaseAsset) {
        report(.verifying)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = asset.verify(downloadedFileAt: package)
            DispatchQueue.main.async {
                guard let self, self.asset == asset else { return }
                if let failure {
                    try? FileManager.default.removeItem(at: package)
                    self.fail(failure)
                    return
                }
                // Only ever on a file whose size and digest just matched the
                // release's own. A URLSession download isn't quarantined in
                // the first place; this keeps an update free of Gatekeeper
                // prompts even if that default ever changes.
                removexattr(package.path, "com.apple.quarantine", 0)
                self.downloadedPackage = package
                self.asset = nil
                self.report(self.openInstaller(package) ? .installerOpened : .failed(.installerLaunchFailed))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, let error else { return }
        if (error as? URLError)?.code == .cancelled { return }
        fail(.downloadFailed)
    }
}
