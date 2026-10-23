import XCTest
@testable import DogMonitor

/// 같이 놀기: states survive the trip between screens, only our own invite is answered and only for 30 s, only the
/// session's friend plays in it, and one seed gives both Macs the same stars.
final class NetPlayTests: XCTestCase {
    private let duel = NetPlayLink.Game(friend: "a", game: .starDuel, seed: 7)

    func testStateRoundTripsBetweenVisibleFrames() {
        let mine = CGRect(x: 0, y: 25, width: 1440, height: 850), theirs = CGRect(x: -1920, y: 80, width: 1920, height: 1000)
        let b = PlayBody(x: 360, y: 450, vx: 288, vy: -85, onGround: false, crouching: true, facingLeft: true)
        let s = PlayNetState(b, in: mine, stars: 4)
        XCTAssertEqual(s.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.vx, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s.feet(in: mine).x, 360, accuracy: 1e-9)
        XCTAssertEqual(s.feet(in: mine).y, 450, accuracy: 1e-9)
        XCTAssertEqual(s.feet(in: theirs), CGPoint(x: -1440, y: 580))
        XCTAssertTrue(s.facingLeft && s.crouching && !s.onGround)
        var off = s
        off.x = 9; off.y = -3   // a friend's Mac sending nonsense stays on screen
        XCTAssertEqual(off.feet(in: mine), CGPoint(x: 1440, y: 25))
    }

    func testStrayAnswersAreIgnored() {
        var link = NetPlayLink()
        XCTAssertNil(link.answered(by: "a", now: 0))   // nothing sent
        XCTAssertTrue(link.invite(duel, now: 0))
        XCTAssertNil(link.answered(by: "b", now: 1))   // not who we asked
        XCTAssertEqual(link.answered(by: "a", now: 2), duel)
        XCTAssertNil(link.answered(by: "a", now: 3))   // used up
    }

    func testInviteExpiresAfter30Seconds() {
        var link = NetPlayLink()
        XCTAssertTrue(link.invite(duel, now: 0))
        XCTAssertFalse(link.invite(duel, now: 10))   // one at a time
        XCTAssertNil(link.answered(by: "a", now: 30))
        XCTAssertTrue(link.invite(duel, now: 31))
        XCTAssertTrue(link.invite(duel, now: 61))    // the last one ran out
        link.begin(duel, now: 62)
        XCTAssertFalse(link.invite(duel, now: 200))  // not during a session
    }

    func testOnlyTheSessionFriendPlays() {
        var link = NetPlayLink()
        let play = SocialMessage.play(PlayNetState(x: 0, y: 0, vx: 0, vy: 0, onGround: true, crouching: false, facingLeft: false, stars: 0))
        XCTAssertFalse(link.admits(play, from: "a"))
        link.begin(duel, now: 0)
        for m in [play, .starTaken(1), .playEnd] {
            XCTAssertTrue(link.admits(m, from: "a"))
            XCTAssertFalse(link.admits(m, from: "b"))
        }
        XCTAssertTrue(link.admits(.invite(.play, seed: 1), from: "b"))   // answered (declined) elsewhere
        XCTAssertFalse(link.silent(now: 4.9))
        XCTAssertTrue(link.silent(now: 5))
        link.end()
        XCTAssertFalse(link.silent(now: 99))
    }

    func testSameSeedSameStars() {
        let a = (0..<20).map { StarRules.netSpot(seed: 42, index: $0) }, b = (0..<20).map { StarRules.netSpot(seed: 42, index: $0) }
        XCTAssertEqual(a.map(\.x), b.map(\.x))
        XCTAssertEqual(a.map(\.up), b.map(\.up))
        XCTAssertEqual(a.map(\.treat), b.map(\.treat))
        XCTAssertEqual(a.map(\.life), b.map(\.life))
        XCTAssertNotEqual(a.map(\.x), (0..<20).map { StarRules.netSpot(seed: 43, index: $0).x })
        XCTAssertEqual(Set(a.map(\.x)).count, 20)   // each index its own star
        for s in a {
            XCTAssertTrue((0...1).contains(s.x) && (s.up == 0 || StarRules.lift.contains(s.up)) && StarRules.life.contains(s.life))
        }
    }
}
