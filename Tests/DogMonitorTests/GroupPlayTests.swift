import XCTest
@testable import DogMonitor

/// 친구들끼리: 술래잡기 picking and fleeing, the 기차놀이 path, 줄넘기 timing and streak, the 단체 춤 beat, and old
/// settings decoding with every game off.
final class GroupPlayTests: XCTestCase {
    func testTheItChasesTheNearestButNotWhoJustTaggedIt() {
        let points = [CGPoint(x: 100, y: 0), CGPoint(x: 140, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 900, y: 0)]
        XCTAssertEqual(CloneTag.quarry(it: 0, at: points, immune: nil), 1)
        XCTAssertEqual(CloneTag.quarry(it: 0, at: points, immune: 1), 2)
        // Only the one who tagged it is left: it is chased after all.
        XCTAssertEqual(CloneTag.quarry(it: 0, at: Array(points.prefix(2)), immune: 1), 1)
        XCTAssertNil(CloneTag.quarry(it: 5, at: points, immune: nil))
    }

    func testATouchTagsTheNearestWithinReachNeverTheImmune() {
        let points = [CGPoint(x: 100, y: 0), CGPoint(x: 130, y: 0), CGPoint(x: 120, y: 10), CGPoint(x: 600, y: 0)]
        XCTAssertEqual(CloneTag.tagged(it: 0, at: points, reach: 40, immune: nil), 2)
        XCTAssertEqual(CloneTag.tagged(it: 0, at: points, reach: 40, immune: 2), 1)
        XCTAssertNil(CloneTag.tagged(it: 0, at: points, reach: 10, immune: nil))
    }

    func testRunnersRunAwayAndDoubleBackWhenCornered() {
        XCTAssertEqual(CloneTag.flee(me: 500, it: 400, lo: 20, hi: 1000, run: 150), 650)
        XCTAssertEqual(CloneTag.flee(me: 300, it: 400, lo: 20, hi: 1000, run: 150), 150)
        // Some room left: to the wall.
        XCTAssertEqual(CloneTag.flee(me: 940, it: 900, lo: 20, hi: 1000, run: 150), 1000)
        // Against the wall: back past the 술래.
        XCTAssertEqual(CloneTag.flee(me: 995, it: 950, lo: 20, hi: 1000, run: 150), 800)
    }

    func testTheTrainFollowsTheWayTheLeaderWent() {
        var path = TrainPath(maxLength: 1000)
        XCTAssertNil(path.point(behind: 10))
        path.add(CGPoint(x: 0, y: 0))
        path.add(CGPoint(x: 100, y: 0))
        path.add(CGPoint(x: 100, y: 100))   // went right, then up
        XCTAssertEqual(path.point(behind: 0), CGPoint(x: 100, y: 100))
        XCTAssertEqual(path.point(behind: 50), CGPoint(x: 100, y: 50))
        XCTAssertEqual(path.point(behind: 150), CGPoint(x: 50, y: 0))   // round the corner, not across it
        XCTAssertEqual(path.point(behind: 900), CGPoint(x: 0, y: 0))   // shorter than asked: the oldest point
        path.add(CGPoint(x: 101, y: 100))   // under 2 points: not a step
        XCTAssertEqual(path.points.count, 3)
    }

    func testTheTrainPathForgetsWhatIsTooFarBehind() {
        var path = TrainPath(maxLength: 150)
        for x in stride(from: 0, through: 500, by: 50) { path.add(CGPoint(x: CGFloat(x), y: 0)) }
        XCTAssertEqual(path.points.last, CGPoint(x: 500, y: 0))
        XCTAssertLessThanOrEqual(path.points.count, 5)
        XCTAssertGreaterThanOrEqual(500 - (path.points.first?.x ?? 500), 150)   // still as long as asked
    }

    func testJumpersAreUpInTheAirAsTheRopePassesTheirFeet() {
        let rope = JumpRope(start: 10)
        XCTAssertEqual(rope.swing(at: 10), 1, accuracy: 1e-6)   // over their heads at the start
        XCTAssertEqual(rope.swing(at: rope.under(0)), -1, accuracy: 1e-6)
        XCTAssertEqual(rope.passes(at: 10), 0)
        XCTAssertEqual(rope.passes(at: rope.under(0) + 0.01), 1)
        XCTAssertEqual(rope.passes(at: rope.under(2) + 0.01), 3)
        // A hop started at hop(k) is at its top at under(k) and still up a moment later.
        var walk = MeadowWalk(x: 0)
        walk.hop()
        var t = rope.hop(1)
        while t < rope.under(1) + 0.03 { walk.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertTrue(walk.airborne)
    }

    func testAStreakOfTenCheersOnceAndAMissStartsOver() {
        var s = RopeStreak()
        XCTAssertEqual((0..<9).map { _ in s.pass(cleared: true) }, Array(repeating: false, count: 9))
        XCTAssertTrue(s.pass(cleared: true))
        XCTAssertFalse(s.pass(cleared: true))
        XCTAssertFalse(s.pass(cleared: false))
        XCTAssertEqual(s.count, 0)
    }

    func testTheDanceKeepsOneBeatForTenSeconds() {
        XCTAssertEqual(GroupDance.beat(0), 0)
        XCTAssertEqual(GroupDance.beat(1.2), 2)
        XCTAssertNil(GroupDance.beat(GroupDance.length))
        XCTAssertNil(GroupDance.beat(-1))
        XCTAssertEqual(GroupDance.move(0).hop, true)
        XCTAssertEqual(GroupDance.move(0).note, true)
        XCTAssertEqual(GroupDance.move(1).facingLeft, true)
        XCTAssertEqual(GroupDance.move(1).hop, false)
    }

    func testOldSettingsDecodeWithEveryGameOff() throws {
        let clones = try JSONDecoder().decode(ClonePrefs.self, from: Data(#"{"on":true,"clones":[],"moves":true,"interacts":true}"#.utf8))
        XCTAssertFalse(clones.tag)
        XCTAssertFalse(clones.train)
        let meadow = try JSONDecoder().decode(MeadowPrefs.self, from: Data(#"{"on":true,"count":4}"#.utf8))
        XCTAssertFalse(meadow.jumpRope)
        XCTAssertFalse(ClonePrefs().tag || ClonePrefs().train || MeadowPrefs().jumpRope)
    }
}
