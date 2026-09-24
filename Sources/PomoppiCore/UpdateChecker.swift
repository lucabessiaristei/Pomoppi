// UpdateChecker.swift — pure, testable "is a newer Pomoppi release
// available" logic. No
// networking lives here: the actual URLSession-based (macOS) / whatever-
// works (Windows) transport, the `checkForUpdates` settings toggle, the
// 24h recheck policy and the tray/settings UI live elsewhere — this file
// only knows how to compare version numbers and parse GitHub's response
// shape, driven through an injected fetch closure so it's exercisable
// without a real network call.
//
// Endpoint this file's shapes are built around (R6 calls it, not this file):
//   GET https://api.github.com/repos/lucabessiaristei/Pomoppi/releases/latest
// Required headers when actually fetching (GitHub returns 403 with no
// User-Agent at all):
//   User-Agent: Pomoppi/<version>
//   Accept: application/vnd.github+json
//   X-GitHub-Api-Version: 2022-11-28
// "/releases/latest" already excludes drafts/prereleases server-side —
// nothing to reimplement client-side for that. A 404 means the repo has no
// releases yet, not a real error — checkForUpdate below folds it (and any
// other fetch failure, or an unparseable response) into "no update
// available" rather than surfacing it as an error.
import Foundation

// Numeric, per-component version comparison — "0.10.0" must sort above
// "0.9.0", which a plain string compare gets wrong. Tolerates an optional
// leading "v" ("v0.2.0" parses the same as "0.2.0"), since GitHub tag names
// use that convention. Failable rather than throwing: malformed input (an
// empty string, a non-numeric component) is just "not a version", not
// something worth a Swift error type of its own.
public struct SemVer: Comparable {
    public let components: [Int]

    public init?(_ string: String) {
        var s = Substring(string)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        self.components = parsed
    }

    // Missing trailing components compare as 0 ("1.2" == "1.2.0"), so
    // differently-shaped-but-equal version strings still compare sanely.
    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

// One downloadable file attached to a release, as `/releases/latest`
// reports it. `size` comes from the API rather than the download's
// Content-Length, so a progress bar is determinate from the first byte.
// `sha256` is GitHub's own per-asset `digest` ("sha256:<hex>") with the
// prefix dropped and lowercased; nil when the release predates digests or
// the field is anything else. It proves the bytes arrived intact, not who
// published them (same trust root as the check itself, SPEC.md §15).
public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL
    public let size: Int
    public let sha256: String?

    public init(name: String, downloadURL: URL, size: Int, sha256: String?) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.sha256 = sha256
    }
}

// Which installer the running app wants. The extension alone tells the
// platforms apart, so the `_macOS`/`_Windows` name suffixes (added for
// humans after 0.3.0) are deliberately not required: 0.3.0's own
// `Pomoppi-0.3.0.pkg` / `Pomoppi-Setup-0.3.0.exe` match too.
public enum UpdatePlatform {
    case macOS
    case windows

    public static var current: UpdatePlatform {
        #if os(Windows)
        return .windows
        #else
        return .macOS
        #endif
    }

    var assetPrefix: String {
        switch self {
        case .macOS: return "pomoppi-"
        case .windows: return "pomoppi-setup-"
        }
    }

    var assetExtension: String {
        switch self {
        case .macOS: return ".pkg"
        case .windows: return ".exe"
        }
    }
}

public enum UpdateChecker {
    // -- the endpoint (constants/documentation — R6 does the actual fetch) --

    public static let repositorySlug = "lucabessiaristei/Pomoppi"
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!

    public static func requestHeaders(appVersion: String) -> [String: String] {
        [
            "User-Agent": "Pomoppi/\(appVersion)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
    }

    // -- transport, injected so this stays Foundation-only and testable ---

    public typealias Fetch = (URL, @escaping (Result<Data, Error>) -> Void) -> Void

    // -- parsing --------------------------------------------------------------

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [AssetResponse]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    // Every field optional so one odd asset entry is skipped by
    // `releaseAsset` below instead of failing the whole release decode.
    private struct AssetResponse: Decodable {
        let name: String?
        let state: String?
        let size: Int?
        let digest: String?
        let browserDownloadURL: String?

        enum CodingKeys: String, CodingKey {
            case name, state, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        // Only fully "uploaded" assets survive: while CI is still attaching
        // a file GitHub lists it as "starter", and its URL would 404.
        var releaseAsset: ReleaseAsset? {
            guard state == "uploaded",
                  let name = name,
                  let size = size, size > 0,
                  let urlString = browserDownloadURL,
                  let url = URL(string: urlString) else { return nil }
            return ReleaseAsset(name: name, downloadURL: url, size: size, sha256: UpdateChecker.sha256Hex(fromDigest: digest))
        }
    }

    // "sha256:<64 hex>" -> lowercase hex; anything else (absent, another
    // algorithm, malformed) -> nil, which callers treat as "size check only".
    static func sha256Hex(fromDigest digest: String?) -> String? {
        guard let digest = digest else { return nil }
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    // Decodes GitHub's releases-API JSON shape, keeping only the fields
    // Pomoppi needs. Returns nil rather than throwing on
    // malformed/empty/field-missing JSON (including a 404's own
    // `{"message": "Not Found", ...}` body) — this needs to be safe to
    // call on garbage input, not just well-formed responses. A missing
    // `assets` array is just an empty one. `assets` keeps API order and
    // only the entries whose `state` is "uploaded".
    public static func parseLatestRelease(_ data: Data) -> (tag: String, pageURL: URL, assets: [ReleaseAsset])? {
        guard let response = try? JSONDecoder().decode(ReleaseResponse.self, from: data),
              let url = URL(string: response.htmlURL) else { return nil }
        return (response.tagName, url, (response.assets ?? []).compactMap { $0.releaseAsset })
    }

    // First asset, in API order, whose name starts with the platform's
    // prefix and ends with its extension, case-insensitively. nil is
    // normal: a release is published before CI finishes attaching its
    // installers, and for that window the UI falls back to the release page.
    public static func matchingAsset(in assets: [ReleaseAsset], for platform: UpdatePlatform = .current) -> ReleaseAsset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasPrefix(platform.assetPrefix) && name.hasSuffix(platform.assetExtension)
        }
    }

    // -- comparison -------------------------------------------------------------

    // Pure version compare, no fetch involved — true only when latestTag
    // parses to a strictly newer version than currentVersion. Malformed
    // input on either side (shouldn't happen for our own Version.swift, but
    // a tag name is someone else's data) answers false rather than crashing.
    public static func isUpdateAvailable(currentVersion: String, latestTag: String) -> Bool {
        guard let current = SemVer(currentVersion), let latest = SemVer(latestTag) else { return false }
        return latest > current
    }

    // -- orchestration ------------------------------------------------------------

    public enum CheckResult: Equatable {
        // `asset` is the running platform's installer, nil when the release
        // has none (yet).
        case updateAvailable(tag: String, pageURL: URL, asset: ReleaseAsset?)
        case noUpdate
    }

    // Fetches the latest-release endpoint through `fetch`, parses it, and
    // compares against `currentVersion` — the one place SemVer comparison,
    // parseLatestRelease, and the transport actually come together. Any
    // fetch failure (a network error, or a 404 "no releases yet" once R6's
    // transport turns that into an Error) and any unparseable response both
    // fold into .noUpdate — there's nothing here worth surfacing as a
    // distinct error case; R6 decides what, if anything, to do about a
    // genuinely failed check.
    public static func checkForUpdate(
        currentVersion: String,
        platform: UpdatePlatform = .current,
        fetch: @escaping Fetch,
        completion: @escaping (CheckResult) -> Void
    ) {
        fetch(latestReleaseAPIURL) { result in
            guard case .success(let data) = result,
                  let release = parseLatestRelease(data),
                  isUpdateAvailable(currentVersion: currentVersion, latestTag: release.tag)
            else {
                completion(.noUpdate)
                return
            }
            completion(.updateAvailable(
                tag: release.tag,
                pageURL: release.pageURL,
                asset: matchingAsset(in: release.assets, for: platform)))
        }
    }
}
