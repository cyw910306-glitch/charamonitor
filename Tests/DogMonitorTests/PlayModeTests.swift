import XCTest
@testable import DogMonitor

/// 놀이 모드: the platformer step (gravity, jumps, landing, drop-through, walls) and what it stands on.
final class PlayModeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 80, width: 1440, height: 795)   // a visible frame above an 80 pt Dock
    private let walls: ClosedRange<CGFloat> = 0...1440
    private let dt = 1.0 / 60
    private var ground: PlayPlatform { PlayPlatform(minX: 0, maxX: 1440, y: 80, solid: true) }

    /// `frames` steps holding `input` (its `jump` only on the first one).
    private func run(_ b: inout PlayBody, _ input: PlayInput, _ platforms: [PlayPlatform], frames: Int) -> [PlayEvent] {
        var events: [PlayEvent] = []
        var i = input
        for _ in 0..<frames {
            events += PlayPhysics.step(&b, input: i, platforms: platforms, walls: walls, width: 40, dt: dt)
            i.jump = false
        }
        return events
    }

    func testFallsAndLandsOnTheGround() {
        var b = PlayBody(x: 300, y: 400)
        let events = run(&b, PlayInput(), [ground], frames: 120)
        XCTAssertTrue(b.onGround)
        XCTAssertEqual(b.y, 80)
        XCTAssertEqual(events, [.landed])
    }

    func testNeverFallsThroughTheGroundEvenOnALongFrame() {
        var b = PlayBody(x: 300, y: 90, vy: -1800)
        PlayPhysics.step(&b, input: PlayInput(), platforms: [ground], walls: walls, width: 40, dt: 1)
        XCTAssertEqual(b.y, 80)
        XCTAssertTrue(b.onGround)
    }

    func testWalksRunsAndStopsAtTheWalls() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        _ = run(&b, PlayInput(right: true), [ground], frames: 60)
        XCTAssertEqual(b.x, 300 + PlayPhysics.walk, accuracy: 1)
        _ = run(&b, PlayInput(left: true, run: true), [ground], frames: 60)
        XCTAssertEqual(b.x, 300 + PlayPhysics.walk - PlayPhysics.run, accuracy: 1)
        XCTAssertTrue(b.facingLeft)
        _ = run(&b, PlayInput(left: true, run: true), [ground], frames: 120)
        XCTAssertEqual(b.x, 20)   // half its width in from the wall
    }

    func testJumpsUpThroughAWindowEdgeAndLandsOnIt() {
        let ledge = PlayPlatform(minX: 200, maxX: 600, y: 200)
        var b = PlayBody(x: 300, y: 80, onGround: true)
        let events = run(&b, PlayInput(jump: true), [ground, ledge], frames: 90)
        XCTAssertEqual(events, [.jumped, .landed])
        XCTAssertEqual(b.y, 200)   // up through it from below, down onto it from above
        XCTAssertTrue(b.onGround)
    }

    func testDoubleJumpOnceInTheAir() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        _ = run(&b, PlayInput(jump: true), [ground], frames: 10)
        let first = b.vy
        _ = run(&b, PlayInput(jump: true), [ground], frames: 1)
        XCTAssertGreaterThan(b.vy, first)
        XCTAssertEqual(b.jumps, 2)
        let vy = b.vy
        _ = run(&b, PlayInput(jump: true), [ground], frames: 1)   // a third press does nothing
        XCTAssertLessThan(b.vy, vy)
    }

    func testDownAndJumpDropsThroughAWindowEdgeButNotTheGround() {
        let ledge = PlayPlatform(minX: 200, maxX: 600, y: 300)
        var b = PlayBody(x: 300, y: 300, onGround: true)
        let events = run(&b, PlayInput(down: true, jump: true), [ground, ledge], frames: 120)
        XCTAssertEqual(b.y, 80)
        XCTAssertEqual(events, [.landed])   // no jump, a drop

        var g = PlayBody(x: 300, y: 80, onGround: true)
        PlayPhysics.step(&g, input: PlayInput(down: true), platforms: [ground], walls: walls, width: 40, dt: dt)
        XCTAssertTrue(g.crouching)
        XCTAssertEqual(g.vx, 0)
        XCTAssertEqual(PlayPhysics.step(&g, input: PlayInput(down: true, jump: true), platforms: [ground], walls: walls, width: 40, dt: dt), [.jumped])
    }

    func testWalksOffAnEdgeAndRidesASmallNudge() {
        let ledge = PlayPlatform(minX: 200, maxX: 400, y: 300)
        var b = PlayBody(x: 390, y: 300, onGround: true)
        _ = run(&b, PlayInput(), [ground, PlayPlatform(minX: 200, maxX: 400, y: 304)], frames: 1)
        XCTAssertEqual(b.y, 304)   // the window moved up a little: it goes along
        _ = run(&b, PlayInput(right: true), [ground, ledge], frames: 120)
        XCTAssertEqual(b.y, 80)
        XCTAssertEqual(b.jumps, 0)
    }

    func testPlatformsAreVisibleWindowTopsAndTheRug() {
        let me: pid_t = 9
        let list = [
            ListedWindow(id: 1, pid: 1, frame: CGRect(x: 100, y: 300, width: 400, height: 200)),   // front, top at 500
            ListedWindow(id: 2, pid: 2, frame: CGRect(x: 0, y: 200, width: 800, height: 400)),     // behind, top at 600
            ListedWindow(id: 3, pid: 3, frame: CGRect(x: 300, y: 100, width: 600, height: 300)),   // top at 400, mostly under 1 and 2
            ListedWindow(id: 4, pid: me, frame: CGRect(x: 1000, y: 100, width: 300, height: 300)), // ours
            ListedWindow(id: 5, pid: 5, layer: 25, frame: CGRect(x: 1000, y: 100, width: 300, height: 300)),
            ListedWindow(id: 6, pid: 6, frame: CGRect(x: 1000, y: 100, width: 60, height: 30)),    // too small
            ListedWindow(id: 7, pid: 7, frame: CGRect(x: 1300, y: 80, width: 140, height: 795)),  // against the menu bar
        ]
        let rug = CGRect(x: 1000, y: 90, width: 200, height: 60)
        let got = PlayPhysics.platforms(list, me: me, screen: screen, rug: rug)
        XCTAssertEqual(got.first, ground)
        XCTAssertEqual(Array(got.dropFirst()), [
            PlayPlatform(minX: 100, maxX: 500, y: 500),
            PlayPlatform(minX: 0, maxX: 800, y: 600),   // 1's top is lower: it hides none of this one
            PlayPlatform(minX: 800, maxX: 900, y: 400),   // 1 and 2 hide the rest
            PlayPlatform(minX: 1000, maxX: 1200, y: 150),
        ])
    }

    func testASessionWithNoKeyEndsAfterTwoMinutesUnlessAGameRuns() {
        XCTAssertFalse(PlayMode.idleOver(now: 119, lastKey: 0, game: false))
        XCTAssertTrue(PlayMode.idleOver(now: 120, lastKey: 0, game: false))
        XCTAssertFalse(PlayMode.idleOver(now: 500, lastKey: 0, game: true), "a game keeps it going")
    }
}
