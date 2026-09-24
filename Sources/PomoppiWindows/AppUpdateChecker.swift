// AppUpdateChecker.swift — Windows counterpart to
// Sources/PomoppiApp/AppUpdateChecker.swift: the real transport
// UpdateChecker.swift was built against, plus the object main.swift owns
// to actually run it — a check ~10s after launch, then every 24h for as
// long as the app keeps running, only while `checkForUpdates` is on. No
// persisted "last checked"/"skipped version" state, same reasoning as
// UpdateChecker.swift itself.
//
// Transport: URLSession/FoundationNetworking, same as macOS — a spike
// (VM-verified live) confirmed a real HTTPS GET against api.github.com
// works end-to-end on Windows Swift, and
// Scripts/make-windows-app.js's existing dumpbin-based DLL walk already
// discovers FoundationNetworking.dll on its own — it's just another
// Swift-toolchain DLL sitting in the same Runtimes\...\usr\bin folder as
// everything already copied, no changes needed to that script.
//
// Scheduling and thread-marshaling both differ from macOS's version, though,
// since this file has none of Foundation.Timer/DispatchQueue's usual
// integration with a Win32 message loop to lean on (nothing else in
// Sources/PomoppiWindows/ uses either — see WidgetWindow/TrayController's
// own SetTimer/WM_TIMER idiom): the 10s/24h schedule is two plain Win32
// SetTimer calls sharing WidgetWindow's own hwnd (a 3rd/4th timer ID
// alongside its ~60fps frame loop and TrayController's 500ms refresh), and
// URLSession's completion handler — which, confirmed by the same spike,
// fires on some Foundation-internal thread, not the message-loop thread —
// is marshaled back onto it via PostMessageW carrying a retained closure
// rather than DispatchQueue.main.async, which nothing here has ever relied
// on actually pumping. Mutating `latestResult` off that thread would be a
// real, live data race against TrayController's menu-build read of it
// (same class of hazard SessionLogger.swift's own nonisolated methods are
// deliberately written to avoid on this platform) — this sidesteps it
// entirely rather than assuming Swift's concurrency runtime hops threads
// safely here.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PomoppiCore
import WinSDK

enum URLSessionUpdateFetch {
    // Matches UpdateChecker.Fetch's shape exactly, so it can be handed
    // straight to `checkForUpdate(currentVersion:fetch:completion:)` — same
    // shape as macOS's own URLSessionUpdateFetch.fetch.
    static let fetch: UpdateChecker.Fetch = { url, completion in
        var request = URLRequest(url: url)
        for (field, value) in UpdateChecker.requestHeaders(appVersion: pomoppiVersion) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            // A 404 (no releases yet) still arrives here as `data`, not
            // `error` — same "not a real error" contract UpdateChecker.swift
            // documents; parseLatestRelease is what turns that into
            // .noUpdate, not this transport.
            guard let data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

// Owned by main.swift, one instance for the process's life — set onto
// WidgetWindow.updateChecker right after construction, same "own object,
// set post-construction, forwarded to from WidgetWindow.handleMessage"
// shape as TrayController/GlobalShortcutManager. TrayController reads
// `latestResult` directly (its menu is rebuilt fresh on every open, no push
// needed); SettingsWindow's footer is the one consumer that needs to know
// when a background check resolves while it's already open, via `onUpdate`.
final class AppUpdateChecker {
    // WM_APP-based custom message carrying a marshaled closure back onto
    // this hwnd's own thread — see handlePendingResult below. A different
    // value than TrayController.callbackMessageID (WM_APP + 1): both share
    // the same hwnd/WndProc, so WM_APP arithmetic has to stay unique the
    // same way TrayController's own comment already explains for itself.
    static let resultMessageID: UINT32 = UINT32(WM_APP + 2)

    private static let initialTimerID: UINT_PTR = 3
    private static let recurringTimerID: UINT_PTR = 4

    private(set) var latestResult: UpdateChecker.CheckResult?
    var onUpdate: (() -> Void)?
    // The in-app update's progress (UPDATE_PLAN.md S6e). Lives here, not on
    // the settings window, which is destroyed on close.
    private(set) var installState: UpdateInstallState = .idle
    // Set by main.swift: whether a focus or break is under way, so the
    // Updates row can confirm before an install closes the app mid-session.
    var isSessionActive: () -> Bool = { false }
    private lazy var installer: UpdateInstaller = {
        let installer = UpdateInstaller(post: { [weak self] work in self?.postToMainThread(work) })
        installer.onStateChange = { [weak self] state in
            self?.installState = state
            self?.onUpdate?()
        }
        return installer
    }()

    // The asset of the update on offer, when this copy can install it
    // in-app; nil means "release page only" (no asset yet, or a copy that
    // Inno didn't install).
    var installableAsset: ReleaseAsset? {
        guard case .updateAvailable(_, _, let asset) = latestResult, UpdateInstaller.isRunningInstalledCopy else { return nil }
        return asset
    }

    func startUpdate() {
        guard !installState.isBusy, let asset = installableAsset else { return }
        installer.start(asset)
    }

    func cancelUpdate() {
        installer.cancel()
    }

    private let hwnd: HWND
    private let currentVersion: String
    private let fetch: UpdateChecker.Fetch

    init(hwnd: HWND, currentVersion: String = pomoppiVersion, fetch: @escaping UpdateChecker.Fetch = URLSessionUpdateFetch.fetch) {
        self.hwnd = hwnd
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    // ~10s after launch, then every 24h thereafter for as long as the app
    // keeps running. Idempotent: a second call tears down and reschedules
    // rather than stacking timers, so main.swift can call this again every
    // time `checkForUpdates` flips back on without double-checking.
    func start() {
        stop()
        SetTimer(hwnd, Self.initialTimerID, 10_000, nil)
    }

    func stop() {
        KillTimer(hwnd, Self.initialTimerID)
        KillTimer(hwnd, Self.recurringTimerID)
    }

    // Called from WidgetWindow.handleMessage's WM_TIMER case for any timer
    // ID that isn't its own frame loop or TrayController's — mirrors
    // TrayController.handleTimer's own "ignore an ID that isn't mine" gate.
    func handleTimer(id: UINT_PTR) {
        switch id {
        case Self.initialTimerID:
            KillTimer(hwnd, Self.initialTimerID)
            runBackgroundCheck()
            SetTimer(hwnd, Self.recurringTimerID, UINT(24 * 60 * 60 * 1000), nil)
        case Self.recurringTimerID:
            runBackgroundCheck()
        default:
            break
        }
    }

    // The silent path: any fetch failure or unparseable response folds into
    // .noUpdate via checkForUpdate's own contract, so a background failure
    // never changes what the tray/settings footer show.
    private func runBackgroundCheck() {
        UpdateChecker.checkForUpdate(currentVersion: currentVersion, fetch: fetch) { [weak self] result in
            self?.postToMainThread { self?.latestResult = result }
        }
    }

    // The settings footer's manual "Check for updates" button. Unlike the
    // background path, a genuine fetch failure here is worth surfacing
    // ("Couldn't check — try again"), so this fetches once itself and only
    // then replays that same result through checkForUpdate (reusing its
    // parse/compare logic verbatim rather than re-deriving it) — a real
    // transport failure short-circuits to .failure before that replay ever
    // happens. `completion` itself always arrives marshaled onto this
    // hwnd's own thread, same as `latestResult`'s own updates — the
    // settings window's Win32 controls it goes on to touch are only safe
    // to reach from there.
    func checkExplicitly(completion: @escaping (Result<UpdateChecker.CheckResult, Error>) -> Void) {
        fetch(UpdateChecker.latestReleaseAPIURL) { [weak self] fetchResult in
            guard let self else { return }
            if case .failure(let error) = fetchResult {
                self.postToMainThread { completion(.failure(error)) }
                return
            }
            UpdateChecker.checkForUpdate(currentVersion: self.currentVersion, fetch: { _, replay in replay(fetchResult) }) { [weak self] result in
                self?.postToMainThread {
                    self?.latestResult = result
                    completion(.success(result))
                }
            }
        }
    }

    // -- cross-thread marshaling ------------------------------------------

    // URLSession's completion handler (confirmed live by this phase's own
    // transport spike) fires on some Foundation-internal thread, never this
    // hwnd's own — PostMessageW is thread-safe to call from anywhere and
    // queues into the target thread's own message loop, the standard Win32
    // way to hand work back to a specific window's owning thread. The work
    // itself travels as a retained closure box rather than trying to pack
    // an UpdateChecker.CheckResult (an enum with String/URL associated
    // values) into a single machine word the way wParam/lParam elsewhere in
    // this codebase carry a raw HWND or numeric ID.
    private final class PendingWork {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private func postToMainThread(_ work: @escaping () -> Void) {
        let box = Unmanaged.passRetained(PendingWork(work)).toOpaque()
        PostMessageW(hwnd, Self.resultMessageID, 0, LPARAM(Int(bitPattern: box)))
    }

    // Called from WidgetWindow.handleMessage for resultMessageID —
    // reconstructs and runs the boxed closure PostMessageW's lParam carried
    // over, then notifies whoever's listening (currently just the settings
    // footer, while it's open) that latestResult may have moved.
    func handleResultMessage(lParam: LPARAM) {
        // Same Int(lParam)-then-UInt(bitPattern:) round-trip
        // SettingsWindow.swift's own WM_NOTIFY/WM_DRAWITEM pointer
        // reconstructions already use — Int(bitPattern:) itself has no
        // overload for LPARAM (Int64), only UInt/ObjectIdentifier.
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(bitPattern: Int(lParam))) else { return }
        Unmanaged<PendingWork>.fromOpaque(pointer).takeRetainedValue().run()
        onUpdate?()
    }
}
