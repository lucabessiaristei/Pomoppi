import XCTest
@testable import PomoppiCore

final class SettingsTests: XCTestCase {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PomoppiSettingsTests-\(UUID().uuidString)")
    }

    func testOnChangeFiresAfterUpdateWithTheNewValue() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(storageDir: dir)

        var received: PomoppiSettings?
        store.onChange = { received = $0 }
        store.update { $0.opacity = 0.5 }

        XCTAssertEqual(received?.opacity, 0.5)
    }

    func testMissingFileFallsBackToDefaultsAndCreatesFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(storageDir: dir)
        XCTAssertEqual(store.get(), PomoppiSettings.defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
    }

    func testClampingRejectsOutOfRangeAndUnknownValues() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(storageDir: dir)

        store.update {
            $0.focusMinutes = 999
            $0.longBreakEvery = 1
            $0.friend = "not-a-real-friend"
            $0.scale = 7
            $0.inkColor = "abc"
        }

        let s = store.get()
        XCTAssertEqual(s.focusMinutes, 180)
        XCTAssertEqual(s.longBreakEvery, 2)
        XCTAssertEqual(s.friend, PomoppiSettings.defaults.friend)
        XCTAssertEqual(s.scale, PomoppiSettings.defaults.scale)
        XCTAssertEqual(s.inkColor, "#AABBCC")
    }

    func testEqualInkAndPaperColorsResetBothToDefaults() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(storageDir: dir)

        store.update {
            $0.inkColor = "#123456"
            $0.paperColor = "#123456"
        }

        let s = store.get()
        XCTAssertEqual(s.inkColor, PomoppiSettings.defaults.inkColor)
        XCTAssertEqual(s.paperColor, PomoppiSettings.defaults.paperColor)
    }

    func testPersistedValuesSurviveReload() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(storageDir: dir)
        store.update { $0.focusMinutes = 50 }

        let reloaded = SettingsStore(storageDir: dir)
        XCTAssertEqual(reloaded.get().focusMinutes, 50)
    }

    func testReverseTrayClickDefaultsToFalseAndFallsBackWhenMissingFromJSON() throws {
        XCTAssertEqual(PomoppiSettings.defaults.reverseTrayClick, false)

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("settings.json")
        try "{}".write(to: filePath, atomically: true, encoding: .utf8)

        let store = SettingsStore(storageDir: dir)
        XCTAssertEqual(store.get().reverseTrayClick, false)
    }

    func testColorSchemeDefaultsToAutoAndFallsBackWhenMissingFromJSON() throws {
        XCTAssertEqual(PomoppiSettings.defaults.colorScheme, "auto")

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("settings.json")
        try "{}".write(to: filePath, atomically: true, encoding: .utf8)

        let store = SettingsStore(storageDir: dir)
        XCTAssertEqual(store.get().colorScheme, "auto")
    }

    func testColorSchemeRoundTripsAndRejectsUnknownValues() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(storageDir: dir)

        store.update { $0.colorScheme = "dark" }
        XCTAssertEqual(store.get().colorScheme, "dark")

        let reloaded = SettingsStore(storageDir: dir)
        XCTAssertEqual(reloaded.get().colorScheme, "dark")

        store.update { $0.colorScheme = "not-a-real-scheme" }
        XCTAssertEqual(store.get().colorScheme, PomoppiSettings.defaults.colorScheme)
    }

    // diaryLastSyncedCount was dropped from the schema in the 2026-09-20
    // Diary redesign (sync no longer uses a cursor) — an old settings.json
    // still carrying that key must decode fine, JSONDecoder ignoring an
    // unknown key for free.
    func testOldDiaryLastSyncedCountKeyIsIgnoredOnDecode() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("settings.json")
        try #"{"diaryLastSyncedCount": 12, "diaryFolderPath": "/tmp/diary"}"#.write(to: filePath, atomically: true, encoding: .utf8)

        let store = SettingsStore(storageDir: dir)
        XCTAssertEqual(store.get().diaryFolderPath, "/tmp/diary")
    }

    func testCorruptFileFallsBackToDefaultsAndBacksUpOriginal() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("settings.json")
        try "not valid json".write(to: filePath, atomically: true, encoding: .utf8)

        let store = SettingsStore(storageDir: dir)
        XCTAssertEqual(store.get(), PomoppiSettings.defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.appendingPathExtension("bak").path))
    }
}
