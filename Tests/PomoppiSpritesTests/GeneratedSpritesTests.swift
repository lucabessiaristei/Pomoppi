import XCTest
import PomoppiCore
@testable import PomoppiSprites

final class GeneratedSpritesTests: XCTestCase {
    func testAllFiveIconsArePresentAtTheDeclaredSize() {
        let expectedNames: Set<String> = ["play", "pause", "reset", "skip", "heart"]
        XCTAssertEqual(Set(GeneratedSprites.icons.keys), expectedNames)
        for (name, rows) in GeneratedSprites.icons {
            XCTAssertEqual(rows.count, GeneratedSprites.iconSize, "\(name) row count")
            for row in rows {
                XCTAssertEqual(row.count, GeneratedSprites.iconSize, "\(name) row width")
            }
        }
    }

    // Every friend PomoppiSettings.friendIDs validates against now has real
    // frame data, not just a name that falls back to the default at render
    // time.
    func testEveryFriendInTheFullRosterHasAtLeastOneFullSizeFrame() {
        let expectedIDs: Set<String> = ["namidappi", "onanippi", "gemuppin", "jankuppin", "utsupon"]
        XCTAssertEqual(Set(GeneratedSprites.friendFrames.keys), expectedIDs)
        for (id, frames) in GeneratedSprites.friendFrames {
            XCTAssertFalse(frames.isEmpty, "\(id) has no frames")
            for frame in frames {
                XCTAssertEqual(frame.count, GeneratedSprites.friendHeight, "\(id) frame height")
                for row in frame {
                    XCTAssertEqual(row.count, GeneratedSprites.friendWidth, "\(id) frame width")
                }
            }
        }
    }

    // Every background PomoppiSettings.backgroundIDs validates against now
    // has a real pattern.
    func testEveryBackgroundInTheFullRosterHasAUniformRowWidth() {
        let expectedIDs = Set(PomoppiSettings.backgroundIDs)
        XCTAssertEqual(Set(GeneratedSprites.backgroundPatterns.keys), expectedIDs)
        for (id, pattern) in GeneratedSprites.backgroundPatterns {
            XCTAssertFalse(pattern.isEmpty, "\(id) has no rows")
            let widths = Set(pattern.map(\.count))
            XCTAssertEqual(widths.count, 1, "\(id): expected every pattern row to share one width")
        }
    }

    func testZzzDataMatchesSourceShape() {
        XCTAssertEqual(GeneratedSprites.zzz, ["###", "..#", ".#.", "#..", "###"])
        XCTAssertEqual(GeneratedSprites.zzzFrames.count, 2)
    }

    func testTrayFramesAre16x16() {
        XCTAssertFalse(GeneratedSprites.trayFrames.isEmpty)
        for frame in GeneratedSprites.trayFrames {
            XCTAssertEqual(frame.count, 16)
            for row in frame {
                XCTAssertEqual(row.count, 16)
            }
        }
    }
}
