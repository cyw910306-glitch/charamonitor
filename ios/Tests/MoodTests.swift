import CharaCore
import XCTest

final class MoodTests: XCTestCase {
    func testIdleByBatteryAndTime() {
        XCTAssertEqual(Idle.now(battery: 0.1, charging: true, hour: 2), .eat)   // charging wins over low and night
        XCTAssertEqual(Idle.now(battery: 0.2, charging: false, hour: 2), .hungry)   // low wins over night
        XCTAssertEqual(Idle.now(battery: 0.21, charging: false, hour: 23), .sleepy)
        XCTAssertEqual(Idle.now(battery: 0.9, charging: false, hour: 5), .sleepy)
        XCTAssertEqual(Idle.now(battery: 0.9, charging: false, hour: 6), .stroll)
        XCTAssertEqual(Idle.now(battery: nil, charging: false, hour: 14), .stroll)   // the simulator: no battery reading
        XCTAssertEqual(Idle.eat.extra, .eat)
        XCTAssertEqual(Idle.hungry.extra, .hungry)
        XCTAssertEqual(Idle.sleepy.pose, .lying)
        XCTAssertNil(Idle.stroll.extra)
    }

    func testComboDizzyAtThreePoutAtFive() {
        var combo = TapCombo()
        let picks = (0..<5).map { combo.tap(at: Double($0) * 0.5) { _ in .hearts } }
        XCTAssertEqual(picks, [.hearts, .hearts, .dizzy, .hearts, .pout])
        XCTAssertEqual(combo.count, 0)   // starts over after the pout
        XCTAssertEqual(combo.tap(at: 2.5) { _ in .jump }, .jump)
        XCTAssertEqual(combo.count, 1)
    }

    func testComboResetsAfterAGap() {
        var combo = TapCombo()
        _ = combo.tap(at: 0) { _ in .hearts }
        _ = combo.tap(at: 0.5) { _ in .hearts }
        XCTAssertEqual(combo.tap(at: 0.5 + TapCombo.gap + 0.01) { _ in .spin }, .spin)   // too slow: not dizzy
        XCTAssertEqual(combo.count, 1)
    }

    func testReactionMovesEndFlat() {
        for r in Reaction.allCases {
            let end = r.pose(r.duration)
            XCTAssertEqual(end.lift, 0); XCTAssertEqual(end.angle, 0); XCTAssertEqual(end.sx, 1); XCTAssertEqual(end.sy, 1)
            XCTAssertFalse(r.lines.isEmpty)
        }
        XCTAssertGreaterThan(Reaction.jump.pose(0.3).lift, 0.5)
    }

    func testFocusClock() {
        XCTAssertEqual(FocusTalk.clock(25 * 60), "25:00")
        XCTAssertEqual(FocusTalk.clock(59.2), "01:00")   // rounds up: never shows 00:00 before the end
        XCTAssertEqual(FocusTalk.clock(-3), "00:00")
    }

    func testFocusCountsOnTheDayItEnded() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let lateNight = Date(timeIntervalSince1970: 1_792_683_000)   // 2026-10-23 00:30 in Seoul, still the 22nd in UTC
        XCTAssertEqual(FocusTalk.day(lateNight, in: seoul), "2026-10-23")
        XCTAssertEqual(FocusTalk.tally(25, on: "2026-10-23", kept: ("2026-10-23", 50)).minutes, 75)
        XCTAssertEqual(FocusTalk.tally(25, on: "2026-10-23", kept: ("2026-10-22", 50)).minutes, 25)   // a new day
        XCTAssertEqual(FocusTalk.tally(25, on: "2026-10-22", kept: ("2026-10-23", 50)).day, "2026-10-23")   // older: dropped
        XCTAssertEqual(FocusTalk.tally(25, on: "2026-10-22", kept: ("2026-10-23", 50)).minutes, 50)
    }
}
