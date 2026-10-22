import XCTest
@testable import DogMonitor

final class ClickGamesTests: XCTestCase {
    func testHideRoundsCountThreeAndTheHint() {
        var r = HideRounds(at: 100)
        XCTAssertEqual(r.hintAt, 115)
        XCTAssertEqual(r.found(at: 104), 4)
        r.begin(at: 110)
        XCTAssertEqual(r.round, 1)
        XCTAssertEqual(r.found(at: 112.5), 2.5)
        r.begin(at: 120)
        XCTAssertFalse(r.isOver)
        XCTAssertEqual(r.found(at: 119), 0)   // a clock that went back never makes a negative time
        XCTAssertTrue(r.isOver)
        XCTAssertNil(r.found(at: 130))
        XCTAssertEqual(r.total, 6.5)
    }

    func testHideSpotsFitAndAvoidTheLastOne() {
        let size = CGSize(width: 40, height: 50)
        let floor = PlayPlatform(minX: 0, maxX: 1000, y: 0, solid: true)
        let win = PlayPlatform(minX: 100, maxX: 300, y: 400)
        let narrow = PlayPlatform(minX: 500, maxX: 550, y: 300)
        let underBar = PlayPlatform(minX: 0, maxX: 400, y: 790)
        XCTAssertEqual(HideSpots.usable([floor, win, narrow, underBar], size: size, top: 800), [floor, win])

        // A window while there is one (2 of 3), the bottom otherwise, never the same edge twice.
        XCTAssertEqual(HideSpots.pick([floor, win], size: size, last: nil, random: { _ in 0 }, unit: { 0 })?.edge, win)
        XCTAssertEqual(HideSpots.pick([floor, win], size: size, last: win, random: { _ in 0 }, unit: { 0 })?.edge, floor)
        XCTAssertEqual(HideSpots.pick([floor], size: size, last: floor, random: { _ in 0 }, unit: { 0 })?.edge, floor)
        XCTAssertNil(HideSpots.pick([], size: size, last: nil))

        // Its middle stays on the edge with all of it.
        XCTAssertEqual(HideSpots.pick([win], size: size, last: nil, unit: { 0 })?.x, 120)
        XCTAssertEqual(HideSpots.pick([win], size: size, last: nil, unit: { 1 })?.x, 280)
    }

    func testMolesQuickenAndKeepApart() {
        XCTAssertEqual(MoleRules.gap(0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(MoleRules.gap(30), 0.45, accuracy: 1e-9)
        XCTAssertGreaterThan(MoleRules.up(5), MoleRules.up(25))
        XCTAssertEqual([0, 9.9, 10, 25, 99].map(MoleRules.most), [1, 1, 2, 3, 3])

        XCTAssertEqual(MoleRules.spot(lo: 0, hi: 100, width: 20, taken: [], unit: { 0 }), 10)
        XCTAssertEqual(MoleRules.spot(lo: 0, hi: 100, width: 20, taken: [], unit: { 1 }), 90)
        var tries = [CGFloat(0), 1].makeIterator()   // the first lands on one already up, the second is clear
        XCTAssertEqual(MoleRules.spot(lo: 0, hi: 100, width: 20, taken: [12], unit: { tries.next() ?? 1 }), 90)
        XCTAssertNil(MoleRules.spot(lo: 0, hi: 100, width: 20, taken: [50], unit: { 0.5 }))
        XCTAssertNil(MoleRules.spot(lo: 0, hi: 10, width: 20, taken: []))
    }

    func testMoleScoreKeepsTheBest() {
        var s = MoleScore(best: 2)
        s.bonk(); s.bonk()
        XCTAssertFalse(s.finish())   // a tie is not a new best
        s.bonk()
        XCTAssertTrue(s.finish())
        XCTAssertEqual(s.best, 3)
        XCTAssertEqual(MoleScore(best: -4).best, 0)
    }

    func testBallGoalsOnTheRugAndReach() {
        let rug = CGRect(x: 100, y: 0, width: 200, height: 80)
        XCTAssertTrue(BallRules.goal(CGPoint(x: 150, y: 40), rug: rug))
        XCTAssertTrue(BallRules.goal(CGPoint(x: 150, y: 80), rug: rug))   // resting on its top edge
        XCTAssertFalse(BallRules.goal(CGPoint(x: 50, y: 0), rug: rug))
        XCTAssertFalse(BallRules.goal(CGPoint(x: 150, y: 40), rug: nil))

        let body = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertTrue(BallRules.reaches(body, ball: CGPoint(x: 48, y: 20), radius: 10))
        XCTAssertFalse(BallRules.reaches(body, ball: CGPoint(x: 60, y: 20), radius: 10))
    }
}
