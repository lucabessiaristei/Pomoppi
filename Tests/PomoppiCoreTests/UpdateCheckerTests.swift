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

    func testCheckForUpdateReportsUpdateAvailableWhenFetchReturnsNewerRelease() {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0"}
        """
        let fetch: UpdateChecker.Fetch = { _, completion in completion(.success(Data(json.utf8))) }

        var result: UpdateChecker.CheckResult?
        UpdateChecker.checkForUpdate(currentVersion: "0.2.0", fetch: fetch) { result = $0 }

        XCTAssertEqual(result, .updateAvailable(tag: "v0.3.0", pageURL: URL(string: "https://github.com/lucabessiaristei/Pomoppi/releases/tag/v0.3.0")!))
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
}
