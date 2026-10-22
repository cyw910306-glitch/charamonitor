import XCTest
@testable import DogMonitor

/// 장난감 상자: where toys sit, what old or odd settings decode to, and how the toys push the 놀이 모드 player.
final class ToyBoxTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 80, width: 1440, height: 795)

    func testToysStayWhollyOnTheScreen() {
        for kind in ToyKind.allCases {
            let s = kind.size
            for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.3), (-4.0, 9.0), (Double.nan, Double.infinity)] {
                let f = Toy(kind: kind, x: x, y: y).frame(in: screen)
                XCTAssertEqual(f.size, s)
                XCTAssertTrue(screen.contains(f), "\(kind) at \(x), \(y): \(f)")
            }
            // A screen smaller than the toy: pinned to its bottom left, never NaN.
            let tiny = CGRect(x: 10, y: 20, width: 5, height: 5)
            XCTAssertEqual(Toy(kind: kind, x: 1, y: 1).frame(in: tiny).origin, CGPoint(x: 10, y: 20))
        }
        // Back and forth through shares keeps the spot.
        let f = CGRect(x: 300, y: 200, width: 96, height: 46)
        XCTAssertEqual(Toy(kind: .trampoline, frame: f, in: screen).frame(in: screen).origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(Toy(kind: .trampoline, frame: f, in: screen).frame(in: screen).origin.y, 200, accuracy: 0.001)
    }

    func testDecodeKeepsWhatItKnows() throws {
        let json = #"{"toys":[{"kind":"rocket","x":0.2,"y":0},{"kind":"ball","x":1e300,"y":-3},{"kind":"slide"},"#
            + #"{"kind":"cushion","x":"far"}]}"#
        let p = try JSONDecoder().decode(ToyPrefs.self, from: Data(json.utf8))
        XCTAssertFalse(p.on)
        XCTAssertEqual(p.toys.map(\.kind), [.ball, .slide, .cushion])   // a toy from a newer version stays in the box
        XCTAssertEqual(p.toys[0].x, 1); XCTAssertEqual(p.toys[0].y, 0)
        XCTAssertEqual(p.toys[1].x, 0.5); XCTAssertEqual(p.toys[2].x, 0.5)

        XCTAssertEqual(try JSONDecoder().decode(ToyPrefs.self, from: Data(#"{"on":true,"toys":3}"#.utf8)), ToyPrefs(on: true, toys: []))
        let many = "{\"toys\":[" + Array(repeating: #"{"kind":"ball","x":0,"y":0}"#, count: 9).joined(separator: ",") + "]}"
        XCTAssertEqual(try JSONDecoder().decode(ToyPrefs.self, from: Data(many.utf8)).toys.count, ToyPrefs.maxCount)

        var full = ToyPrefs()
        for _ in 0..<ToyPrefs.maxCount { XCTAssertTrue(full.add(.cushion)) }
        XCTAssertFalse(full.add(.ball))
        XCTAssertEqual(try JSONDecoder().decode(ToyPrefs.self, from: JSONEncoder().encode(full)), full)
    }

    func testTrampolineLaunchesFarHigherThanAJump() {
        let still = ToyPhysics.launch(fall: 0)
        XCTAssertEqual(still, ToyPhysics.superJump)
        XCTAssertGreaterThan(still, PlayPhysics.jump * 1.5)
        XCTAssertGreaterThan(ToyPhysics.launch(fall: -900), still)            // a longer fall bounces higher
        XCTAssertEqual(ToyPhysics.launch(fall: -1e6), ToyPhysics.maxLaunch)   // but never off the top
        XCTAssertEqual(ToyPhysics.launch(fall: 500), still)                   // rising onto it counts as no fall

        // Through the real step: landing on the mat at its top goes about 430 pt up.
        let mat = PlayPlatform(minX: 100, maxX: 200, y: 300)
        var b = PlayBody(x: 150, y: 300, vy: still)
        var top: CGFloat = 0
        for _ in 0..<120 {
            PlayPhysics.step(&b, input: PlayInput(), platforms: [mat], walls: 0...1440, width: 40, dt: 1.0 / 60)
            top = max(top, b.y)
        }
        XCTAssertGreaterThan(top - 300, 380)
        XCTAssertEqual(ToyPhysics.cushion(fall: -300), 0)   // the cushion just takes a small fall
        XCTAssertGreaterThan(ToyPhysics.cushion(fall: -1800), 0)
    }

    func testChuteRunsDownAndTheBallStops() {
        let f = CGRect(x: 0, y: 80, width: 104, height: 78)
        let c = ToyKind.chute(f)
        XCTAssertEqual(ToyPhysics.chute(f, x: c.top.x), c.top.y)
        XCTAssertLessThan(ToyPhysics.chute(f, x: (c.top.x + c.bottom.x) / 2) ?? .infinity, c.top.y)
        XCTAssertNil(ToyPhysics.chute(f, x: c.bottom.x))   // off its end the player falls the last bit
        XCTAssertEqual(ToyKind.slide.stand(in: f)?.maxY ?? 0, c.top.y, accuracy: 0.001)   // the deck meets the chute

        var x: CGFloat = 500, v: CGFloat = 320, frames = 0
        while v != 0, frames < 1000 { (x, v) = ToyPhysics.roll(x: x, vx: v, dt: 1.0 / 60, lo: 0, hi: 1440); frames += 1 }
        XCTAssertEqual(v, 0)
        XCTAssertEqual(x - 500, ToyPhysics.rollDistance(320), accuracy: 6)
        let wall = ToyPhysics.roll(x: 1438, vx: 300, dt: 0.1, lo: 0, hi: 1440)
        XCTAssertEqual(wall.x, 1440)
        XCTAssertLessThan(wall.vx, 0)   // bounces back off the edge
    }
}
