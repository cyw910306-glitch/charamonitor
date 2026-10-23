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

/// 놀이 기술: 하늘날기 (↑ 꾹), 높이 점프 (↑↑), 대시 (←← / →→), and the quick-pair detector behind the last two.
final class PlayMovesTests: XCTestCase {
    private let walls: ClosedRange<CGFloat> = 0...1440
    private let dt = 1.0 / 60
    private var ground: PlayPlatform { PlayPlatform(minX: 0, maxX: 1440, y: 80, solid: true) }

    private func step(_ b: inout PlayBody, _ input: PlayInput, ceiling: CGFloat = .greatestFiniteMagnitude) {
        PlayPhysics.step(&b, input: input, platforms: [ground], walls: walls, width: 40, dt: dt, ceiling: ceiling)
    }

    /// The highest the feet get after a ground jump, pressing `second` (once) on frame `at`.
    private func apex(second: PlayInput?, at: Int) -> CGFloat {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        step(&b, PlayInput(jump: true))
        var top = b.y
        for f in 1..<240 {
            step(&b, f == at ? (second ?? PlayInput()) : PlayInput())
            top = max(top, b.y)
        }
        return top - 80
    }

    func testDoubleTapIsTheSameKeyQuicklyAndThenStartsOver() {
        var t = DoubleTap()
        XCTAssertFalse(t.press(126, at: 0))
        XCTAssertTrue(t.press(126, at: 0.2))
        XCTAssertFalse(t.press(126, at: 0.3), "a third press starts a new pair")
        XCTAssertFalse(t.press(123, at: 0.4), "another key")
        XCTAssertFalse(t.press(124, at: 0.45))
        XCTAssertFalse(t.press(124, at: 0.8), "too slow")
    }

    func testHoldingUpFliesUntilTheFuelIsGoneThenFallsAndRefills() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        step(&b, PlayInput(jump: true, up: true))
        for _ in 0..<20 { step(&b, PlayInput(up: true)) }   // past the 0.2 s hold
        XCTAssertTrue(b.flying)
        XCTAssertLessThan(b.fuel, PlayPhysics.fuelMax)
        for _ in 0..<30 { step(&b, PlayInput(up: true)) }
        XCTAssertEqual(b.vy, PlayPhysics.flyRise, accuracy: 5, "eases to the rise speed, no gravity")
        var frames = 50
        while b.flying, frames < 400 { step(&b, PlayInput(up: true)); frames += 1 }
        XCTAssertEqual(b.fuel, 0)
        XCTAssertEqual(frames, 12 + 90, accuracy: 2, "1.5 s of flight after the 0.2 s hold")
        XCTAssertFalse(b.onGround)
        for _ in 0..<300 { step(&b, PlayInput(up: true)) }
        XCTAssertTrue(b.onGround, "out of fuel it falls")
        var ground = PlayBody(x: 300, y: 80, onGround: true, fuel: 0)
        for _ in 0..<118 { step(&ground, PlayInput()) }
        XCTAssertLessThan(ground.fuel, PlayPhysics.fuelMax)
        for _ in 0..<3 { step(&ground, PlayInput()) }
        XCTAssertEqual(ground.fuel, PlayPhysics.fuelMax, "full again in 2 s")
    }

    func testLettingGoOfUpFallsAtOnce() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        step(&b, PlayInput(jump: true, up: true))
        for _ in 0..<40 { step(&b, PlayInput(up: true)) }
        XCTAssertTrue(b.flying)
        step(&b, PlayInput())
        XCTAssertFalse(b.flying)
        XCTAssertEqual(b.upHeld, 0)
    }

    func testFlyingStopsAtTheCeiling() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        step(&b, PlayInput(jump: true, up: true), ceiling: 300)
        for _ in 0..<80 { step(&b, PlayInput(up: true), ceiling: 300) }
        XCTAssertEqual(b.y, 300)
        XCTAssertLessThanOrEqual(b.vy, PlayPhysics.flyRise)
    }

    func testHighJumpTopsOutAboutOnePointEightJumps() {
        let plain = apex(second: nil, at: 0)
        let high = apex(second: PlayInput(highJump: true), at: 6)
        XCTAssertEqual(high / plain, PlayPhysics.highJumpScale, accuracy: PlayPhysics.highJumpScale * 0.05)
        let double = apex(second: PlayInput(jump: true), at: 6)
        XCTAssertLessThan(double, high, "the old 2단 점프 stays lower")
    }

    func testHighJumpOnTheGroundIsAPlainJump() {
        var b = PlayBody(x: 300, y: 80, onGround: true)
        step(&b, PlayInput(highJump: true))
        XCTAssertEqual(b.vy, PlayPhysics.jump - PlayPhysics.gravity * CGFloat(dt), accuracy: 0.01)
        XCTAssertEqual(b.jumps, 1)
    }

    func testDashBeatsShiftAndCrouchingStopsIt() {
        var b = PlayBody(x: 100, y: 80, onGround: true)
        for _ in 0..<60 { step(&b, PlayInput(right: true, run: true, dash: true)) }
        XCTAssertEqual(b.x, 100 + PlayPhysics.dash, accuracy: 1)
        XCTAssertGreaterThan(PlayPhysics.dash, PlayPhysics.run)
        step(&b, PlayInput(right: true, down: true, dash: true))
        XCTAssertEqual(b.vx, 0)
    }
}
