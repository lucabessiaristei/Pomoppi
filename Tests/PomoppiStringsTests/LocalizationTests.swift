import XCTest
@testable import PomoppiStrings

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L.configure(systemLanguages: [])
        L.apply(setting: "system")
    }

    private var english: [String: String] { GeneratedStrings.tables["en"]! }

    func testEnglishComesFirstAndEveryLanguageHasATable() {
        XCTAssertEqual(L.languageIDs.first, "en")
        for id in L.languageIDs {
            XCTAssertNotNil(GeneratedStrings.tables[id], id)
        }
    }

    func testEveryLanguageHasEveryEnglishKeyAndANameOfItsOwn() {
        for id in L.languageIDs {
            let table = GeneratedStrings.tables[id]!
            XCTAssertEqual(Set(table.keys), Set(english.keys), id)
            XCTAssertFalse(L.displayName(of: id).isEmpty, id)
        }
    }

    func testTranslationsOnlyUsePlaceholdersTheirEnglishSourceHas() {
        let pattern = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ s: String) -> Set<String> {
            Set(pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) })
        }
        for id in L.languageIDs where id != "en" {
            for (key, value) in GeneratedStrings.tables[id]! {
                XCTAssertTrue(placeholders(value).isSubset(of: placeholders(english[key]!)), "\(id): \(key)")
            }
        }
    }

    func testUnknownKeyRendersTheKeyItself() {
        XCTAssertEqual(L.t("no.such.key"), "no.such.key")
    }

    func testPlaceholdersAreReplacedPositionally() {
        XCTAssertEqual(L.t("no.such {1} key {0}", "a", 2), "no.such 2 key a")
    }

    func testSystemLanguageMatchesOnThePrimarySubtag() {
        XCTAssertEqual(L.match("en-GB"), "en")
        XCTAssertEqual(L.match("EN_us"), "en")
        XCTAssertNil(L.match("xx-YY"))
    }

    func testUnknownSystemLanguageFallsBackToEnglish() {
        L.configure(systemLanguages: ["xx-YY"])
        L.apply(setting: "system")
        XCTAssertEqual(L.current, "en")
    }

    func testUnknownSettingFallsBackToTheSystemLanguage() {
        L.configure(systemLanguages: ["en-US"])
        L.apply(setting: "klingon")
        XCTAssertEqual(L.current, "en")
    }
}
