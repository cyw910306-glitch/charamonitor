import XCTest
@testable import DogMonitor

/// 별 줍기: stars only where a player can get to, on screen; touching scores; the best survives a bad value.
final class StarGameTests: XCTestCase {
    private let ground = PlayPlatform(minX: 0, maxX: 1440, y: 80, solid: true)
    private let body = CGSize(width: 48, height: 48)

    func testOnlyEdgesWithinAHopChainAreReachable() {
        let low = PlayPlatform(minX: 200, maxX: 600, y: 280)        // 200 over the ground
        let step = PlayPlatform(minX: 650, maxX: 900, y: 480)       // 200 over `low`, 50 across
        let lone = PlayPlatform(minX: 1200, maxX: 1400, y: 900)     // far over everything
        let reached = StarRules.reachable([ground, low, step, lone])
        XCTAssertEqual(reached.count, 3)
        XCTAssertFalse(reached.contains(lone))
        XCTAssertFalse(StarRules.reachable([ground, PlayPlatform(minX: 0, maxX: 300, y: 500)]).contains { !$0.solid })
    }

    func testSpawnsSitOverAReachableEdgeAndOnScreen() {
        let low = PlayPlatform(minX: 200, maxX: 600, y: 280)
        let lone = PlayPlatform(minX: 1200, maxX: 1400, y: 900)
        let top: CGFloat = 1000, r: CGFloat = 12
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let s = StarRules.spawn(on: [ground, low, lone], top: top, radius: r, body: body, avoid: [], using: &rng)!
            let c = s.center
            XCTAssertLessThanOrEqual(c.y, top - r)
            XCTAssertFalse((1200...1400).contains(c.x) && c.y > 900)   // never over the edge nobody can reach
            let under = [ground, low].filter { c.x >= $0.minX + body.width / 2 && c.x <= $0.maxX - body.width / 2 && c.y >= $0.y + body.height / 2 }
            let lift = under.map { c.y - $0.y - body.height / 2 }.min()!
            XCTAssertTrue(lift == 0 || StarRules.lift.contains(lift), "\(c)")
        }
        XCTAssertNil(StarRules.spawn(on: [], top: top, radius: r, body: body, avoid: [], using: &rng))
    }

    func testSkyStarsAndEdgesStayUnderWhatAJumpAndFlightReach() {
        var b = PlayBody(x: 300, y: 80, onGround: true), peak: CGFloat = 0
        for i in 0..<240 {   // ↑ pressed and held: a jump, then 하늘날기 until the fuel is gone
            PlayPhysics.step(&b, input: PlayInput(jump: i == 0, up: true), platforms: [ground], walls: 0...1440, width: 48, dt: 1.0 / 60)
            peak = max(peak, b.y - 80)
        }
        XCTAssertGreaterThanOrEqual(peak - 60, StarRules.skyHop)
        XCTAssertGreaterThanOrEqual(peak - 60, StarRules.skyLift.upperBound)
        let high = PlayPlatform(minX: 200, maxX: 600, y: 480)   // 400 over the ground: only by flight
        XCTAssertFalse(StarRules.reachable([ground, high]).contains(high))
        XCTAssertTrue(StarRules.reachable([ground, high], hop: StarRules.skyHop).contains(high))
        var rng = SystemRandomNumberGenerator(), top: CGFloat = 0
        for _ in 0..<300 {
            let c = StarRules.spawn(on: [ground], top: 1200, radius: 12, body: body, avoid: [], sky: true, using: &rng)!.center
            XCTAssertLessThanOrEqual(c.y - 80 - body.height / 2, StarRules.skyLift.upperBound)
            top = max(top, c.y)
        }
        XCTAssertGreaterThan(top - 80 - body.height / 2, StarRules.lift.upperBound, "some only flight reaches")
    }

    func testTouchPicksUpAndTreatsCountMore() {
        let stars = [StarSpot(center: CGPoint(x: 100, y: 104)), StarSpot(center: CGPoint(x: 400, y: 104), treat: true)]
        XCTAssertEqual(StarRules.touched(stars, radius: 12, by: CGRect(x: 80, y: 80, width: 48, height: 48)), [0])
        XCTAssertEqual(StarRules.touched(stars, radius: 12, by: CGRect(x: 200, y: 80, width: 48, height: 48)), [])
        XCTAssertEqual(stars.map(\.points), [1, StarRules.treatPoints])
    }

    func testBestKeepsTheHighestAndReadsGarbageAsNone() {
        let suite = "StarGameTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StarRules.best(in: d), 0)
        d.set("lots", forKey: StarRules.bestKey)
        XCTAssertEqual(StarRules.best(in: d), 0)
        d.set(-4, forKey: StarRules.bestKey)
        XCTAssertEqual(StarRules.best(in: d), 0)
        XCTAssertTrue(StarRules.record(12, in: d))
        XCTAssertFalse(StarRules.record(8, in: d))
        XCTAssertFalse(StarRules.record(12, in: d))
        XCTAssertEqual(StarRules.best(in: d), 12)
    }
}
