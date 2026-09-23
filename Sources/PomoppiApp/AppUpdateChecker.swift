import AppKit
import Foundation
import PomoppiCore

// Cross-platform release/update plan, phase R6a (macOS side): the real
// URLSession transport UpdateChecker.swift was built against, plus the
// object AppDelegate owns to actually run it — a check ~10s after launch,
// then every 24h for as long as the app keeps running, only while
// `checkForUpdates` is on. No persisted "last checked"/"skipped version"
// state, same reasoning as UpdateChecker.swift itself: `/releases/latest`
// already excludes drafts/prereleases, so there's nothing worth
// remembering across launches.
enum URLSessionUpdateFetch {
    // Matches UpdateChecker.Fetch's shape exactly, so it can be handed
    // straight to `checkForUpdate(currentVersion:fetch:completion:)`.
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

// Owned by AppDelegate, one instance for the process's life. Keeps the
// latest result in memory (published so the tray menu and the settings
// footer can both read it) and owns the 10s/24h scheduling — see `start()`.
final class AppUpdateChecker: ObservableObject {
    @Published private(set) var latestResult: UpdateChecker.CheckResult?

    private let currentVersion: String
    private let fetch: UpdateChecker.Fetch
    private var initialTimer: Timer?
    private var recurringTimer: Timer?

    init(currentVersion: String = pomoppiVersion, fetch: @escaping UpdateChecker.Fetch = URLSessionUpdateFetch.fetch) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    // ~10s after launch, then every 24h thereafter for as long as the app
    // keeps running. Idempotent: a second call tears down and reschedules
    // rather than stacking timers, so AppDelegate can call this again every
    // time `checkForUpdates` flips back on without double-checking.
    func start() {
        stop()
        initialTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.runBackgroundCheck()
            self?.scheduleRecurring()
        }
    }

    func stop() {
        initialTimer?.invalidate()
        initialTimer = nil
        recurringTimer?.invalidate()
        recurringTimer = nil
    }

    private func scheduleRecurring() {
        recurringTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.runBackgroundCheck()
        }
    }

    // The silent path: any fetch failure or unparseable response folds into
    // .noUpdate via checkForUpdate's own contract, so a background failure
    // never changes what the tray/settings footer show.
    private func runBackgroundCheck() {
        UpdateChecker.checkForUpdate(currentVersion: currentVersion, fetch: fetch) { [weak self] result in
            DispatchQueue.main.async { self?.latestResult = result }
        }
    }

    // The settings footer's manual "Check for updates" button. Unlike the
    // background path, a genuine fetch failure here is worth surfacing
    // ("Couldn't check — try again"), so this fetches once itself and only
    // then replays that same result through checkForUpdate (reusing its
    // parse/compare logic verbatim rather than re-deriving it) — a real
    // transport failure short-circuits to .failure before that replay ever
    // happens. An unparseable-but-successfully-fetched response (the same
    // "not a real error" case UpdateChecker.swift documents for a 404) still
    // resolves to .noUpdate, same as the background path.
    func checkExplicitly(completion: @escaping (Result<UpdateChecker.CheckResult, Error>) -> Void) {
        fetch(UpdateChecker.latestReleaseAPIURL) { [weak self] fetchResult in
            guard let self else { return }
            if case .failure(let error) = fetchResult {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            UpdateChecker.checkForUpdate(currentVersion: self.currentVersion, fetch: { _, replay in replay(fetchResult) }) { [weak self] result in
                DispatchQueue.main.async {
                    self?.latestResult = result
                    completion(.success(result))
                }
            }
        }
    }
}
