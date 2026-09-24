import XCTest
@testable import PomoppiCore

final class UpdateCheckerTests: XCTestCase {
    // Pinned as a literal: a local build once shipped with the slug pointed at
    // cli/cli for a manual test and reported GitHub CLI releases as Pomoppi
    // updates. Any such edit now fails `swift test` on the machine carrying it.
    func testEndpointTargetsPomoppiRepository() {
        XCTAssertEqual(UpdateChecker.repositorySlug, "lucabessiaristei/Pomoppi")
        XCTAssertEqual(
            UpdateChecker.latestReleaseAPIURL.absoluteString,
            "https://api.github.com/repos/lucabessiaristei/Pomoppi/releases/latest")
    }

    // -- SemVer ---------------------------------------------------------------

    func testSemVerOrderingNewerAndOlder() throws {
        let older = try XCTUnwrap(SemVer("0.1.0"))
        let newer = try XCTUnwrap(SemVer("0.2.0"))
        XCTAssertTrue(newer > older)
        XCTAssertTrue(older < newer)
    }

    func testSemVerEquality() throws {
        let a = try XCTUnwrap(SemVer("0.2.0"))
        let b = try XCTUnwrap(SemVer("0.2.0"))
        XCTAssertEqual(a, b)
    }

    func testSemVerToleratesLeadingVPrefix() throws {
        let prefixed = try XCTUnwrap(SemVer("v1.2.3"))
        let plain = try XCTUnwrap(SemVer("1.2.3"))
        XCTAssertEqual(prefixed, plain)
    }

    // The critical case: component-wise numeric compare, not a string
    // compare — "0.10.0" must sort above "0.9.0".
    func testSemVerComparesComponentsNumericallyNotAsStrings() throws {
        let tenPointO = try XCTUnwrap(SemVer("0.10.0"))
        let ninePointO = try XCTUnwrap(SemVer("0.9.0"))
        XCTAssertTrue(tenPointO > ninePointO)
    }

    func testSemVerMalformedInputReturnsNil() {
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("v"))
        XCTAssertNil(SemVer("not-a-version"))
        XCTAssertNil(SemVer("1.x.0"))
    }

    // -- parseLatestRelease -----------------------------------------------------

    func testParseLatestReleaseExtractsTagAndURLFromValidJSON() throws {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0"}
        """
        let result = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(result.tag, "v0.3.0")
        XCTAssertEqual(result.pageURL, URL(string: "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0"))
    }

    func testParseLatestReleaseReturnsNilForMalformedJSON() {
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("not json at all".utf8)))
    }

    func testParseLatestReleaseReturnsNilForEmptyData() {
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data()))
    }

    // GitHub's own 404 body shape ({"message": "Not Found", ...}) — missing
    // both fields this cares about.
    func testParseLatestReleaseReturnsNilWhenFieldsAreMissing() {
        let json = """
        {"message": "Not Found", "documentation_url": "https://docs.github.com/rest"}
        """
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(json.utf8)))
    }

    // -- isUpdateAvailable --------------------------------------------------------

    func testIsUpdateAvailableWhenCurrentIsOlder() {
        XCTAssertTrue(UpdateChecker.isUpdateAvailable(currentVersion: "0.2.0", latestTag: "v0.3.0"))
    }

    func testIsUpdateAvailableWhenCurrentEqualsLatest() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "0.2.0", latestTag: "v0.2.0"))
    }

    // Shouldn't normally happen (a dev build ahead of the last tagged
    // release), but must not crash or claim an update either.
    func testIsUpdateAvailableWhenCurrentIsNewer() {
        XCTAssertFalse(UpdateChecker.isUpdateAvailable(currentVersion: "0.3.0", latestTag: "v0.2.0"))
    }

    // -- checkForUpdate (fetch + parse + compare glued together) ----------------

    private struct StubFetchError: Error {}

    // Published before CI attached its installers: nothing to install yet.
    func testCheckForUpdateReportsNoUpdateWhenNewerReleaseHasNoAsset() {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0", "assets": []}
        """
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.success(Data(json.utf8))) }

        var result: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.0", fetch: fetch) { result = $0 }

        XCTAssertEqual(result, .noUpdate)
    }

    func testCheckForUpdateReportsNoUpdateWhenFetchReturnsSameVersion() {
        let json = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.2.0"}
        """
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.success(Data(json.utf8))) }

        var result: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.0", fetch: fetch) { result = $0 }

        XCTAssertEqual(result, .noUpdate)
    }

    // A 404 (no releases exist yet) — however R6's real transport ends up
    // representing that (a fetch failure here) — must resolve to
    // .noUpdate, never propagate as an error.
    func testCheckForUpdateTreatsA404ShapedFetchFailureAsNoUpdateNotAnError() {
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.failure(StubFetchError())) }

        var result: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.0", fetch: fetch) { result = $0 }

        XCTAssertEqual(result, .noUpdate)
    }

    // The other plausible shape for a 404: fetch "succeeds" with GitHub's
    // own {"message": "Not Found", ...} body. Unparseable, so this also
    // has to resolve to .noUpdate rather than crashing.
    func testCheckForUpdateTreatsA404BodyAsNoUpdate() {
        let json = """
        {"message": "Not Found", "documentation_url": "https://docs.github.com/rest"}
        """
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.success(Data(json.utf8))) }

        var result: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.0", fetch: fetch) { result = $0 }

        XCTAssertEqual(result, .noUpdate)
    }

    // -- assets ----------------------------------------------------------------

    // Captured from the real GET /releases/latest for v0.3.0 on 2026-09-24,
    // trimmed to the fields Pomoppi reads plus a few it must ignore
    // (uploader, content_type, counts). 0.3.0 predates the _macOS/_Windows
    // name suffixes and still carries the since-dropped Pomoppi-win.zip.
    private static let v030Fixture = """
    {
      "url": "https://api.github.com/repos/lucabessiaristei/Pomoppi/releases/250000000",
      "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0",
      "tag_name": "v0.3.0",
      "name": "v0.3.0",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "Pomoppi-0.3.0.pkg",
          "label": "",
          "uploader": {"login": "github-actions[bot]", "type": "Bot"},
          "content_type": "application/octet-stream",
          "state": "uploaded",
          "size": 2415631,
          "digest": "sha256:a411cb45d08e302b7a30044862207a4a4b685ed5ef8c131fea1d68e8bc7f3382",
          "download_count": 3,
          "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.3.0/Pomoppi-0.3.0.pkg"
        },
        {
          "name": "Pomoppi-Setup-0.3.0.exe",
          "label": "",
          "uploader": {"login": "github-actions[bot]", "type": "Bot"},
          "content_type": "application/x-msdownload",
          "state": "uploaded",
          "size": 17766470,
          "digest": "sha256:a30e04891bbb14de5da9c2cb24b54590c93475f10c2e1bd119afe95043985afc",
          "download_count": 2,
          "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.3.0/Pomoppi-Setup-0.3.0.exe"
        },
        {
          "name": "Pomoppi-win.zip",
          "label": "",
          "uploader": {"login": "github-actions[bot]", "type": "Bot"},
          "content_type": "application/zip",
          "state": "uploaded",
          "size": 24220432,
          "digest": "sha256:d65654ece7a840631a038e027c71b76c7522487afcc2eb01d4b167af25e04850",
          "download_count": 1,
          "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.3.0/Pomoppi-win.zip"
        }
      ]
    }
    """

    private static let v030Pkg = ReleaseAsset(
        name: "Pomoppi-0.3.0.pkg",
        downloadURL: URL(string: "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.3.0/Pomoppi-0.3.0.pkg")!,
        size: 2415631,
        sha256: "a411cb45d08e302b7a30044862207a4a4b685ed5ef8c131fea1d68e8bc7f3382")

    private static let v030Setup = ReleaseAsset(
        name: "Pomoppi-Setup-0.3.0.exe",
        downloadURL: URL(string: "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.3.0/Pomoppi-Setup-0.3.0.exe")!,
        size: 17766470,
        sha256: "a30e04891bbb14de5da9c2cb24b54590c93475f10c2e1bd119afe95043985afc")

    private func asset(_ name: String, sha256: String? = nil) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.invalid/\(name)")!, size: 1, sha256: sha256)
    }

    func testParseLatestReleaseDecodesRealFixtureAssetsInAPIOrder() throws {
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(Self.v030Fixture.utf8)))
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.assets.map(\.name), ["Pomoppi-0.3.0.pkg", "Pomoppi-Setup-0.3.0.exe", "Pomoppi-win.zip"])
        XCTAssertEqual(release.assets[0], Self.v030Pkg)
        XCTAssertEqual(release.assets[1], Self.v030Setup)
    }

    func testParseLatestReleaseWithoutAssetsFieldHasNoAssets() throws {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0"}
        """
        XCTAssertEqual(try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8))).assets, [])
    }

    func testMatchingAssetPicksEachPlatformsInstallerFromRealFixture() throws {
        let assets = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(Self.v030Fixture.utf8))).assets
        XCTAssertEqual(UpdateChecker.matchingAsset(in: assets, for: .macOS), Self.v030Pkg)
        XCTAssertEqual(UpdateChecker.matchingAsset(in: assets, for: .windows), Self.v030Setup)
    }

    func testMatchingAssetAcceptsSuffixedNamesAndIgnoresCase() {
        let assets = [asset("pomoppi-0.4.0_MACOS.PKG"), asset("POMOPPI-SETUP-0.4.0_Windows.EXE")]
        XCTAssertEqual(UpdateChecker.matchingAsset(in: assets, for: .macOS)?.name, "pomoppi-0.4.0_MACOS.PKG")
        XCTAssertEqual(UpdateChecker.matchingAsset(in: assets, for: .windows)?.name, "POMOPPI-SETUP-0.4.0_Windows.EXE")
    }

    // Only the other platform's installer (and the portable zip) attached:
    // no match, never a wrong-platform file.
    func testMatchingAssetIgnoresOtherPlatformsFiles() {
        XCTAssertNil(UpdateChecker.matchingAsset(in: [asset("Pomoppi-Setup-0.4.0_Windows.exe"), asset("Pomoppi-win.zip")], for: .macOS))
        XCTAssertNil(UpdateChecker.matchingAsset(in: [asset("Pomoppi-0.4.0_macOS.pkg"), asset("Pomoppi-win.zip")], for: .windows))
        XCTAssertNil(UpdateChecker.matchingAsset(in: [asset("Other-0.4.0.pkg"), asset("Setup-0.4.0.exe")], for: .macOS))
    }

    func testMatchingAssetTakesFirstMatchInAPIOrder() {
        let assets = [asset("Pomoppi-0.4.0_macOS.pkg"), asset("Pomoppi-0.4.0-extra.pkg")]
        XCTAssertEqual(UpdateChecker.matchingAsset(in: assets, for: .macOS)?.name, "Pomoppi-0.4.0_macOS.pkg")
    }

    // A release is published before CI attaches its files; while an upload
    // is in flight GitHub lists it with state "starter".
    func testAssetsNotYetUploadedAreSkipped() throws {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.4.0",
         "assets": [
          {"name": "Pomoppi-0.4.0_macOS.pkg", "state": "starter", "size": 100,
           "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.4.0/Pomoppi-0.4.0_macOS.pkg"}
         ]}
        """
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.assets, [])
        XCTAssertNil(UpdateChecker.matchingAsset(in: release.assets, for: .macOS))
    }

    func testAssetWithoutDigestHasNilSHA256() throws {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.4.0",
         "assets": [
          {"name": "Pomoppi-0.4.0_macOS.pkg", "state": "uploaded", "size": 100,
           "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.4.0/Pomoppi-0.4.0_macOS.pkg"},
          {"name": "Pomoppi-Setup-0.4.0_Windows.exe", "state": "uploaded", "size": 200, "digest": null,
           "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.4.0/Pomoppi-Setup-0.4.0_Windows.exe"}
         ]}
        """
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.assets.count, 2)
        XCTAssertNil(release.assets[0].sha256)
        XCTAssertNil(release.assets[1].sha256)
        XCTAssertEqual(release.assets[0].size, 100)
    }

    // One malformed entry (no URL, no size) is dropped without taking the
    // rest of the release down with it.
    func testMalformedAssetEntryIsSkippedNotFatal() throws {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.4.0",
         "assets": [
          {"name": "broken", "state": "uploaded"},
          {"name": "Pomoppi-0.4.0_macOS.pkg", "state": "uploaded", "size": 100,
           "browser_download_url": "https://github.com/lucabessiaristei/Pomoppi/releases/download/v0.4.0/Pomoppi-0.4.0_macOS.pkg"}
         ]}
        """
        let release = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.assets.map(\.name), ["Pomoppi-0.4.0_macOS.pkg"])
    }

    func testSHA256HexFromDigest() {
        let hex = "a411cb45d08e302b7a30044862207a4a4b685ed5ef8c131fea1d68e8bc7f3382"
        XCTAssertEqual(UpdateChecker.sha256Hex(fromDigest: "sha256:\(hex)"), hex)
        XCTAssertEqual(UpdateChecker.sha256Hex(fromDigest: "SHA256:\(hex.uppercased())"), hex)
        XCTAssertNil(UpdateChecker.sha256Hex(fromDigest: nil))
        XCTAssertNil(UpdateChecker.sha256Hex(fromDigest: hex))
        XCTAssertNil(UpdateChecker.sha256Hex(fromDigest: "sha512:\(hex)"))
        XCTAssertNil(UpdateChecker.sha256Hex(fromDigest: "sha256:abc"))
        XCTAssertNil(UpdateChecker.sha256Hex(fromDigest: "sha256:" + String(repeating: "g", count: 64)))
    }

    func testCheckForUpdateCarriesThePlatformsAsset() {
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.success(Data(Self.v030Fixture.utf8))) }
        let pageURL = URL(string: "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0")!

        var mac: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.9", platform: .macOS, fetch: fetch) { mac = $0 }
        XCTAssertEqual(mac, .updateAvailable(tag: "v0.3.0", pageURL: pageURL, asset: Self.v030Pkg))

        var win: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.9", platform: .windows, fetch: fetch) { win = $0 }
        XCTAssertEqual(win, .updateAvailable(tag: "v0.3.0", pageURL: pageURL, asset: Self.v030Setup))
    }

    // -- ReleaseAsset.verify ---------------------------------------------------

    private func writeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pomoppi-verify-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // sha256("abc"), NIST FIPS 180-2.
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testVerifyPassesOnMatchingSizeAndDigest() throws {
        let url = try writeTempFile(Array("abc".utf8))
        let a = ReleaseAsset(name: "Pomoppi-0.4.0.pkg", downloadURL: url, size: 3, sha256: abcSHA256)
        XCTAssertNil(a.verify(downloadedFileAt: url))
    }

    func testVerifyWithoutDigestChecksSizeOnly() throws {
        let url = try writeTempFile(Array("abc".utf8))
        XCTAssertNil(ReleaseAsset(name: "x.pkg", downloadURL: url, size: 3, sha256: nil).verify(downloadedFileAt: url))
        XCTAssertEqual(ReleaseAsset(name: "x.pkg", downloadURL: url, size: 4, sha256: nil).verify(downloadedFileAt: url), .incompleteDownload)
    }

    func testVerifyReportsChecksumMismatch() throws {
        let url = try writeTempFile(Array("abd".utf8))
        let a = ReleaseAsset(name: "x.pkg", downloadURL: url, size: 3, sha256: abcSHA256)
        XCTAssertEqual(a.verify(downloadedFileAt: url), .checksumMismatch)
    }

    func testVerifyReportsMissingFileAsDownloadFailure() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pomoppi-missing-\(UUID().uuidString)")
        let a = ReleaseAsset(name: "x.pkg", downloadURL: url, size: 3, sha256: abcSHA256)
        XCTAssertEqual(a.verify(downloadedFileAt: url), .downloadFailed)
    }

    func testInstallStateBusyness() {
        XCTAssertFalse(UpdateInstallState.idle.isBusy)
        XCTAssertTrue(UpdateInstallState.downloading(received: 1, total: 2).isBusy)
        XCTAssertTrue(UpdateInstallState.verifying.isBusy)
        XCTAssertTrue(UpdateInstallState.installerOpened.isBusy)
        XCTAssertFalse(UpdateInstallState.failed(.checksumMismatch).isBusy)
        XCTAssertEqual(UpdateInstallFailure.checksumMismatch.clause, "the download didn't match its checksum")
    }
}
