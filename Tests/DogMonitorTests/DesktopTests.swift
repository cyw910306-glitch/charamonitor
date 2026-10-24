import XCTest
@testable import DogMonitor

/// DesktopKit: the pure pieces the 데스크톱 친구 share.
final class DesktopTests: XCTestCase {

    // MARK: AlphaHit

    func testAlphaHitMapsViewPointsToPixelsTopRowFirst() {
        // 2x2: only the top-left pixel is drawn.
        let hit = AlphaHit(width: 2, height: 2, alpha: [255, 0, 0, 0])
        let size = CGSize(width: 20, height: 20)
        XCTAssertTrue(hit.hits(CGPoint(x: 5, y: 15), in: size))    // y up: top-left quarter
        XCTAssertFalse(hit.hits(CGPoint(x: 5, y: 5), in: size))
        XCTAssertFalse(hit.hits(CGPoint(x: 15, y: 15), in: size))
        XCTAssertFalse(hit.hits(CGPoint(x: -1, y: 15), in: size))  // outside
        XCTAssertFalse(AlphaHit(width: 1, height: 1, alpha: [60]).hits(.zero, in: size))   // faint edge: not the drawing
    }

    func testAlphaHitReadsAnImage() throws {
        let image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { _ in
            NSColor.black.setFill()
            CGRect(x: 0, y: 2, width: 4, height: 2).fill()   // top half
            return true
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: 4, height: 4))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = NSImage(size: CGSize(width: 4, height: 4))
        pixels.addRepresentation(rep)
        let hit = try XCTUnwrap(AlphaHit(pixels))
        XCTAssertEqual(hit.width, 4)
        XCTAssertTrue(hit.hits(CGPoint(x: 1, y: 3), in: CGSize(width: 4, height: 4)))
        XCTAssertFalse(hit.hits(CGPoint(x: 1, y: 1), in: CGSize(width: 4, height: 4)))
    }

    // MARK: ClickRecognizer

    func testClickRecognizerSingleWaitsForTheDoubleWindow() {
        var r = ClickRecognizer()
        let p = CGPoint(x: 10, y: 10)
        XCTAssertEqual(r.mouseDown(p, at: 0), [])
        XCTAssertEqual(r.mouseUp(p, at: 0.05), [])
        XCTAssertEqual(r.pollAt ?? 0, 0.05 + ClickRecognizer.doubleWindow, accuracy: 1e-9)
        XCTAssertEqual(r.poll(at: 0.2), [])
        XCTAssertEqual(r.poll(at: 0.4), [.single(p)])
        XCTAssertEqual(r.poll(at: 0.5), [])
    }

    func testClickRecognizerDouble() {
        var r = ClickRecognizer()
        let p = CGPoint(x: 10, y: 10)
        _ = r.mouseDown(p, at: 0); _ = r.mouseUp(p, at: 0.05)
        XCTAssertEqual(r.mouseDown(p, at: 0.2), [])
        XCTAssertEqual(r.mouseUp(p, at: 0.25), [.double(p)])
        XCTAssertEqual(r.poll(at: 1), [])
        // Too slow for a pair: two singles, the first one given at the second press.
        _ = r.mouseDown(p, at: 2); _ = r.mouseUp(p, at: 2.05)
        XCTAssertEqual(r.mouseDown(p, at: 2.5), [.single(p)])
    }

    /// A right click mid-press: the menu swallows the release, so cancel ends a drag in place and leaves nothing waiting.
    func testClickRecognizerCancelEndsADragAndDropsAWaitingClick() {
        var r = ClickRecognizer()
        let p = CGPoint(x: 30, y: 0)
        _ = r.mouseDown(.zero, at: 0); _ = r.mouseMoved(p, at: 0.01)
        XCTAssertEqual(r.cancel(at: p), [.dragEnded(p, velocity: .zero)])
        XCTAssertEqual(r.mouseUp(p, at: 0.5), [])            // the swallowed release, should it ever come, does nothing
        XCTAssertEqual(r.mouseMoved(.zero, at: 0.6), [])     // and no drag goes on
        // A click waiting for its pair never fires later (the timers keep polling while the menu is up).
        _ = r.mouseDown(p, at: 1); _ = r.mouseUp(p, at: 1.05)
        XCTAssertEqual(r.cancel(at: p), [])
        XCTAssertNil(r.pollAt)
        XCTAssertEqual(r.poll(at: 2), [])
    }

    /// Every friend's menu: its own items, then 오늘의 운세 ▸, 데스크톱 친구 ▸ and 설정 열기; a fresh submenu each time.
    func testFriendMenuEndsWithTheSharedItems() {
        var ran = false, settings = false
        FriendMenu.openSettings = { settings = true }
        defer { FriendMenu.openSettings = nil }
        let a = FriendMenu.build([FriendMenu.item("own") { ran = true }])
        XCTAssertEqual(a.items.map(\.title), ["own", "", L("오늘의 운세"), L("데스크톱 친구"), L("설정 열기")])
        XCTAssertEqual(a.items[2].submenu?.items.count, 2)   // 오늘 운세 보기, 다시 뽑기
        XCTAssertEqual(a.items[3].submenu?.items.count, DesktopFriends.toggles.count + 6)   // toggles, separator, 후원 친구 지금 보기, 집중, 숨 고르기, 놀이 ▸, 포스트잇 붙이기
        a.performActionForItem(at: 0)
        a.performActionForItem(at: 4)
        XCTAssertFalse(ran)   // runs once the menu has let go
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(ran)
        XCTAssertTrue(settings)
        XCTAssertFalse(FriendMenu.isOpen)
        let b = FriendMenu.build([])
        XCTAssertEqual(b.items.map(\.title), [L("오늘의 운세"), L("데스크톱 친구"), L("설정 열기")])
        XCTAssertFalse(a.items[3].submenu === b.items[1].submenu)
    }

    func testClickRecognizerDragAndThrow() {
        var r = ClickRecognizer()
        _ = r.mouseDown(.zero, at: 0)
        XCTAssertEqual(r.mouseMoved(CGPoint(x: 2, y: 0), at: 0.01), [])   // within slop
        XCTAssertEqual(r.mouseMoved(CGPoint(x: 10, y: 0), at: 0.02), [.dragBegan(.zero), .dragged(CGPoint(x: 10, y: 0))])
        XCTAssertEqual(r.mouseMoved(CGPoint(x: 20, y: 0), at: 0.03), [.dragged(CGPoint(x: 20, y: 0))])
        guard case let .dragEnded(_, v)? = r.mouseUp(CGPoint(x: 20, y: 0), at: 0.04).first else { return XCTFail("no drag end") }
        XCTAssertEqual(v.dx, 1000, accuracy: 1)   // 10 pt in 10 ms
        XCTAssertNil(r.pollAt)                    // a drag is never a click
        // Held still before letting go: dropped, not thrown.
        _ = r.mouseDown(.zero, at: 1); _ = r.mouseMoved(CGPoint(x: 30, y: 0), at: 1.01)
        XCTAssertEqual(r.mouseUp(CGPoint(x: 30, y: 0), at: 1.5), [.dragEnded(CGPoint(x: 30, y: 0), velocity: .zero)])
    }

    // MARK: Dangle

    func testDangleSettlesAtEquilibrium() {
        var d = Dangle(anchor: CGPoint(x: 100, y: 500), restLength: 60)
        XCTAssertTrue(d.isSettled)
        XCTAssertEqual(d.stretch, 1, accuracy: 1e-6)
        d.grab(at: CGPoint(x: 160, y: 460))
        XCTAssertTrue(d.held)
        d.release(velocity: CGVector(dx: 99_999, dy: 0))
        XCTAssertLessThanOrEqual(hypot(d.velocity.dx, d.velocity.dy), Dangle.maxThrow + 0.001)
        var swungRight = false
        for _ in 0..<(60 * 30) {   // 30 s at 60 fps
            d.step(dt: 1.0 / 60)
            swungRight = swungRight || d.angle > 0.3
            XCTAssertLessThanOrEqual(d.stretch * d.hangLength, d.restLength * d.maxStretch + 0.001)
        }
        XCTAssertTrue(swungRight)
        XCTAssertTrue(d.isSettled, "\(d.position)")
    }

    func testShortDangleSettlesAtItsLongestString() {
        var d = Dangle(anchor: .zero, restLength: 8)   // sag 15 pt would pass 2.5 x 8: it rests at the limit
        XCTAssertEqual(d.hangLength, 20, accuracy: 1e-6)
        d.grab(at: CGPoint(x: 15, y: -5)); d.release()
        for _ in 0..<(60 * 30) { d.step(dt: 1.0 / 60) }
        XCTAssertTrue(d.isSettled, "\(d.position)")
        XCTAssertEqual(d.stretch, 1, accuracy: 0.01)
    }

    func testDangleWindPushesItAside() {
        var d = Dangle(anchor: .zero, restLength: 60)
        for _ in 0..<600 { d.step(dt: 1.0 / 60, wind: 300) }
        XCTAssertGreaterThan(d.position.x, 5)
        XCTAssertGreaterThan(d.angle, 0)
        let calm = d.position
        d.grab(at: calm)
        d.step(dt: 1)
        XCTAssertEqual(d.position, calm)   // held: the hand decides, not the wind
    }

    // MARK: CursorMotion

    func testCursorMotionSpeedAndShake() {
        var m = CursorMotion()
        m.feed(.zero, at: 0)
        m.feed(CGPoint(x: 30, y: 40), at: 0.1)
        XCTAssertEqual(m.speed, 500, accuracy: 0.01)
        m.feed(CGPoint(x: 10_030, y: 40), at: 0.2)
        XCTAssertEqual(m.speed, CursorMotion.maxSpeed)
        XCTAssertFalse(m.isShaking)
        // Fast left-right: five sweeps of 100 pt in 50 ms = four reversals.
        m = CursorMotion()
        var x: CGFloat = 0, t = 1.0
        m.feed(CGPoint(x: x, y: 0), at: t)
        for i in 0..<5 { x += i % 2 == 0 ? 100 : -100; t += 0.05; m.feed(CGPoint(x: x, y: 0), at: t) }
        XCTAssertEqual(m.directionChanges, 4)
        XCTAssertTrue(m.isShaking)
        // Slow sweeps never count, and old reversals age out.
        m.feed(CGPoint(x: x + 10, y: 0), at: t + 1)
        XCTAssertEqual(m.directionChanges, 0)
        m.reset()
        XCTAssertFalse(m.isShaking)
    }
}

/// 대롱대롱 친구's taut strings, pokes and the notch; 풀밭 친구들's walking; 집중 타이머; 할 일 진척.
final class DesktopFriendsMoreTests: XCTestCase {
    func testTautStringKeepsItsLengthThroughABigSwing() {
        var d = Dangle(anchor: CGPoint(x: 0, y: 500), restLength: 100)
        d.taut = true; d.damping = 0.6
        d.release(velocity: CGVector(dx: 1200, dy: 0))
        var widest: CGFloat = 0
        for _ in 0..<(60 * 2) {
            d.step(dt: 1.0 / 60)
            XCTAssertEqual(hypot(d.position.x - d.anchor.x, d.position.y - d.anchor.y), d.hangLength, accuracy: 0.5)
            widest = max(widest, abs(d.angle))
        }
        XCTAssertGreaterThan(widest, 0.5)   // it really swung out
    }

    func testNudgeOnlyMovesAFreeFriend() {
        var d = Dangle(anchor: .zero, restLength: 80)
        d.nudge(CGVector(dx: 300, dy: 0))
        XCTAssertEqual(d.velocity.dx, 300)
        d.grab(at: CGPoint(x: 10, y: -90))
        d.nudge(CGVector(dx: 300, dy: 0))
        XCTAssertEqual(d.velocity, .zero)
        d.release()
        d.nudge(CGVector(dx: 99_999, dy: 0))
        XCTAssertEqual(d.velocity.dx, Dangle.maxThrow, accuracy: 0.001)
    }

    func testStrandsStayOutOfTheNotch() {
        let gap: ClosedRange<CGFloat> = 640...800
        XCTAssertEqual(HangingFriends.outOfNotch(x: 300, half: 20, gap: gap), 300)
        XCTAssertEqual(HangingFriends.outOfNotch(x: 650, half: 20, gap: gap), 616)   // nearer the left side
        XCTAssertEqual(HangingFriends.outOfNotch(x: 790, half: 20, gap: gap), 824)
    }

    func testOldHangSettingsKeepTheirValues() throws {
        let old = #"{"on":true,"count":2,"slots":[],"wind":"fresh","sound":false,"volume":0.2,"onTop":true}"#
        let p = try JSONDecoder().decode(HangPrefs.self, from: Data(old.utf8))
        XCTAssertTrue(p.on); XCTAssertEqual(p.count, 2); XCTAssertEqual(p.wind, .fresh); XCTAssertTrue(p.onTop)
        XCTAssertTrue(p.fromTop); XCTAssertEqual(p.feel, .taut)   // new fields: their defaults
        XCTAssertTrue(HangSlot(character: nil, imagePath: nil, charm: .none, rope: .vine, x: 0.5, length: 90, display: nil).grips)
        XCTAssertFalse(HangSlot.defaults[0].grips)
    }

    // MARK: Fling (커서 친구 던지기)

    private func fly(_ f: inout Fling, seconds: Double = 5, check: (Fling) -> Void = { _ in }) {
        for _ in 0..<Int(seconds * 60) where !f.isSettled { f.step(dt: 1.0 / 60); check(f) }
    }

    func testFlingBouncesOffWallsAndSettlesOnTheFloor() {
        let walls = CGRect(x: 0, y: 0, width: 800, height: 600)
        var f = Fling(at: CGPoint(x: 400, y: 300), velocity: CGVector(dx: 2800, dy: 400), walls: walls)
        fly(&f) { XCTAssertTrue(walls.minX...walls.maxX ~= $0.position.x) }
        XCTAssertTrue(f.isSettled)
        XCTAssertGreaterThanOrEqual(f.bounces, 1)
        XCTAssertEqual(f.position.y, 0)
        XCTAssertFalse(f.landedOnLedge)
        XCTAssertEqual(f.spin, 0, accuracy: 0.05)   // back on its feet
    }

    func testFlingWithoutVelocityFallsStraight() {
        var f = Fling(at: CGPoint(x: 100, y: 300), velocity: .zero, walls: CGRect(x: 0, y: 0, width: 800, height: 600))
        fly(&f)
        XCTAssertTrue(f.isSettled)
        XCTAssertEqual(f.position, CGPoint(x: 100, y: 0))
        XCTAssertLessThan(f.impact, 1500)   // a short fall: no dizzy landing
    }

    func testFlingLandsOnALedgeOnlyFromAbove() {
        let walls = CGRect(x: 0, y: 0, width: 800, height: 600)
        var above = Fling(at: CGPoint(x: 300, y: 500), velocity: CGVector(dx: 50, dy: 0), walls: walls, ledge: (100, 600, 250))
        fly(&above)
        XCTAssertTrue(above.isSettled && above.landedOnLedge)
        XCTAssertEqual(above.position.y, 250)
        // From under the window's top it passes up through, then lands on it on the way down.
        var under = Fling(at: CGPoint(x: 300, y: 50), velocity: CGVector(dx: 0, dy: 1200), walls: walls, ledge: (100, 600, 250))
        var top: CGFloat = 0
        fly(&under) { top = max(top, $0.position.y) }
        XCTAssertGreaterThan(top, 250)
        XCTAssertEqual(under.position.y, 250)
        // Off the ledge's side it falls past to the floor.
        var beside = Fling(at: CGPoint(x: 700, y: 500), velocity: .zero, walls: walls, ledge: (100, 600, 250))
        fly(&beside)
        XCTAssertEqual(beside.position.y, 0)
        XCTAssertFalse(beside.landedOnLedge)
    }

    func testFlingCapsItsSpeed() {
        let f = Fling(at: .zero, velocity: CGVector(dx: 9000, dy: 9000), walls: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertLessThanOrEqual(hypot(f.velocity.dx, f.velocity.dy), Dangle.maxThrow + 0.001)
    }

    func testWindupSquishCurve() {
        XCTAssertTrue(BuddyMath.windup(held: 0.05) == (1, 1))
        let full = BuddyMath.windup(held: 0.5)
        XCTAssertEqual(full.sx, 1.18, accuracy: 0.001); XCTAssertEqual(full.sy, 0.78, accuracy: 0.001)
        XCTAssertTrue(BuddyMath.windup(held: 2) == full)   // held there
        XCTAssertGreaterThan(BuddyMath.windup(held: 0.3).sx, 1)
    }

    // MARK: Click reactions (커서 친구 누르기)

    func testComboEscalatesToDizzyThenPout() {
        var c = ClickCombo()
        let first: ([Reaction]) -> Reaction = { $0[0] }
        XCTAssertEqual(c.click(at: 0, pick: first), .hearts)
        XCTAssertEqual(c.click(at: 0.3, pick: first), .hearts)
        XCTAssertEqual(c.click(at: 0.6, pick: first), .dizzy)
        XCTAssertEqual(c.click(at: 0.9, pick: first), .hearts)
        XCTAssertEqual(c.click(at: 1.2, pick: first), .pout)
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(c.click(at: 1.5, pick: first), .hearts)   // starts over
        XCTAssertEqual(c.count, 1)
    }

    func testComboResetsAfterAGap() {
        var c = ClickCombo()
        _ = c.click(at: 0); _ = c.click(at: 0.5)
        XCTAssertEqual(c.count, 2)
        XCTAssertNotEqual(c.click(at: 0.5 + ClickCombo.gap + 0.1), .dizzy)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(Reaction.cute.contains(c.click(at: 5)))
    }

    func testReactionPoseEndsAndStillIsFlat() {
        for r in Reaction.allCases {
            XCTAssertTrue(r.pose(r.duration, still: false) == (0, 0, 1, 1), r.rawValue)
            XCTAssertTrue(r.pose(r.duration * 0.4, still: true) == (0, 0, 1, 1), r.rawValue)
            XCTAssertGreaterThan(r.duration, 0.5)
        }
        XCTAssertGreaterThan(Reaction.jump.pose(0.3, still: false).lift, 0.5)
        XCTAssertGreaterThan(Reaction.spin.pose(0.3, still: false).angle, 1)
        XCTAssertLessThan(Reaction.sneeze.pose(0.45, still: false).sy, 1)
    }

    func testEveryReactionHasAPoseAndCuteOnesNeverEscalate() {
        let shown: Set<BuddyGait> = [.special, .stand, .dizzy, .sulk]   // special falls back to eat, then walk
        for r in Reaction.allCases { XCTAssertTrue(shown.contains(r.gait), r.rawValue) }
        XCTAssertFalse(Reaction.cute.contains(.dizzy) || Reaction.cute.contains(.pout))
        XCTAssertEqual(Reaction.pout.mark?.text, L("흥!"))
    }

    func testMeadowWalkWalksHopsAndLands() {
        var w = MeadowWalk(x: 100)
        w.walk(to: 145)
        for _ in 0..<120 { w.step(dt: 1.0 / 60) }
        XCTAssertEqual(w.x, 145, accuracy: 0.001)
        XCTAssertEqual(w.state, .idle)
        w.hop()
        var top: CGFloat = 0
        for _ in 0..<120 { w.step(dt: 1.0 / 60); top = max(top, w.y) }
        XCTAssertGreaterThan(top, 20)
        XCTAssertEqual(w.y, 0); XCTAssertEqual(w.state, .idle)
        w.drop(from: 200)
        for _ in 0..<120 { w.step(dt: 1.0 / 60) }
        XCTAssertEqual(w.y, 0)
    }

    func testMeadowNeighboursKeepTheirRoom() {
        var walks = [MeadowWalk(x: 100), MeadowWalk(x: 110), MeadowWalk(x: 5)]
        MeadowWalk.separate(&walks, widths: [40, 40, 40], gap: 6, lo: 0, hi: 400)
        let xs = walks.map(\.x).sorted()
        XCTAssertGreaterThanOrEqual(xs[1] - xs[0], 45.9)
        XCTAssertGreaterThanOrEqual(xs[2] - xs[1], 45.9)
        XCTAssertGreaterThanOrEqual(xs[0], 20)   // inside the band
        var pinned = [MeadowWalk(x: 100), MeadowWalk(x: 110)]
        MeadowWalk.separate(&pinned, widths: [40, 40], gap: 6, lo: 0, hi: 400, pinned: 0)
        XCTAssertEqual(pinned[0].x, 100)   // the held one stays in the hand
    }

    func testMeadowWalkCustomSpeed() {
        var slow = MeadowWalk(x: 0), fast = MeadowWalk(x: 0)
        fast.speed = 140
        slow.walk(to: 100); fast.walk(to: 100)
        for _ in 0..<30 { slow.step(dt: 1.0 / 30); fast.step(dt: 1.0 / 30) }   // one second
        XCTAssertEqual(fast.x, 100)
        XCTAssertEqual(fast.state, .idle)
        XCTAssertEqual(slow.x, MeadowWalk.speed, accuracy: 0.5)
        XCTAssertEqual(slow.state, .walk)
    }

    func testMeadowClickCombosAndPosesItHas() {
        var combo = ClickCombo()
        let all: (BuddyGait) -> Bool = { _ in true }
        let first = MeadowReaction.click(&combo, at: 0, has: all, key: "test.meadow") { $0[1] }
        XCTAssertEqual(first, MeadowReaction.plays[1])   // an everyday one, from the pick
        _ = MeadowReaction.click(&combo, at: 0.3, has: all, key: "test.meadow") { $0[0] }
        XCTAssertEqual(MeadowReaction.click(&combo, at: 0.6, has: all, key: "test.meadow").reaction, .dizzy)
        _ = MeadowReaction.click(&combo, at: 0.9, has: all, key: "test.meadow")
        let pout = MeadowReaction.click(&combo, at: 1.2, has: all, key: "test.meadow")
        XCTAssertEqual(pout, MeadowReaction(reaction: .pout, gait: .stand))   // its back turned, not its hungry frames
        // No 특기 or 냠냠 frames: never asks for them; standing ones always remain.
        let plain = MeadowReaction.plays(has: { $0 != .special && $0 != .eat })
        XCTAssertFalse(plain.contains { $0.gait == .special || $0.gait == .eat })
        XCTAssertFalse(MeadowReaction.plays(has: { _ in false }).isEmpty)
        // Varied: several poses and moves, and each says something.
        XCTAssertGreaterThanOrEqual(Set(MeadowReaction.plays.map { "\($0.gait)" }).count, 4)
        for r in MeadowReaction.plays + [MeadowReaction(reaction: .dizzy, gait: .dizzy), MeadowReaction(reaction: .pout, gait: .stand), .pet] {
            XCTAssertFalse(r.lines.isEmpty)
            XCTAssertGreaterThan(r.duration, 0.5)
            XCTAssertFalse(r.lines.joined().contains("\u{2014}"))
        }
        XCTAssertEqual(MeadowReaction.plays.filter(\.sits), [MeadowReaction(reaction: .hearts, gait: .sleep)])   // the flop down sits
    }

    func testMeadowClicksNeverRepeatTheSamePlay() {
        var combo = ClickCombo()
        var last: MeadowReaction?
        for k in 0..<20 {   // far apart: never a combo
            let r = MeadowReaction.click(&combo, at: Double(k) * 2, has: { _ in true }, key: "test.meadow.repeat")
            XCTAssertNotEqual(r, last)
            XCTAssertTrue(MeadowReaction.plays.contains(r))
            last = r
        }
    }

    func testMeadowNeighbourIsTheNearestWithinReach() {
        let xs: [CGFloat] = [100, 160, 300, 90]
        XCTAssertEqual(MeadowWalk.neighbour(of: 0, in: xs, reach: 100), 3)
        XCTAssertEqual(MeadowWalk.neighbour(of: 1, in: xs, reach: 100), 0)
        XCTAssertNil(MeadowWalk.neighbour(of: 2, in: xs, reach: 100))
        XCTAssertNil(MeadowWalk.neighbour(of: 7, in: xs, reach: 100))
    }

    func testPetRubNeedsARubOnOneFriend() {
        var rub = PetRub()
        var t: TimeInterval = 0
        func stroke(_ who: Int?, _ n: Int, dx: CGFloat = 40, dt: TimeInterval = 0.05) -> Bool {
            var pet = false
            for k in 0..<n { t += dt; pet = rub.feed(CGPoint(x: k % 2 == 0 ? 0 : dx, y: 10), over: who, at: t) || pet }
            return pet
        }
        XCTAssertTrue(stroke(0, 8))   // back and forth over friend 0: 280 pt
        XCTAssertFalse(stroke(0, 3))  // starts over after a pet
        XCTAssertFalse(stroke(1, 5))  // moved onto another: starts over (160 pt)
        t += 1                        // a pause
        XCTAssertFalse(stroke(1, 3))
        XCTAssertFalse(rub.feed(CGPoint(x: 0, y: 10), over: nil, at: t + 0.05))   // off them
        XCTAssertEqual(rub.rubbed, 0)
        // Lingering without moving (a tick looking again) adds nothing and keeps nothing alive.
        XCTAssertFalse(rub.feed(CGPoint(x: 5, y: 5), over: 2, at: 10))
        XCTAssertFalse(rub.feed(CGPoint(x: 5, y: 5), over: 2, at: 10.4))
        XCTAssertFalse(rub.feed(CGPoint(x: 5, y: 5), over: 2, at: 10.8))
        XCTAssertFalse(rub.feed(CGPoint(x: 205, y: 5), over: 2, at: 11.2))   // 1.2 s since it last moved: starts over
        XCTAssertEqual(rub.rubbed, 0)
    }

    // MARK: 복제 친구

    func testClonePrefsDecodeOldAndCapAtEight() throws {
        let old = try JSONDecoder().decode(ClonePrefs.self, from: Data("{}".utf8))
        XCTAssertEqual(old, ClonePrefs())
        XCTAssertFalse(old.on)
        XCTAssertTrue(old.moves)
        XCTAssertTrue(old.interacts)
        let kept = try JSONDecoder().decode(ClonePrefs.self, from: Data(#"{"on":true,"moves":false}"#.utf8))
        XCTAssertTrue(kept.on)
        XCTAssertFalse(kept.moves)
        XCTAssertTrue(kept.interacts)
        var p = ClonePrefs()
        for i in 0..<ClonePrefs.maxCount { XCTAssertTrue(p.add(CloneSpot(character: nil, x: Double(i) / 8, y: 0))) }
        XCTAssertFalse(p.add(CloneSpot(character: nil, x: 0.5, y: 0.5)))
        XCTAssertEqual(p.clones.count, 8)
    }

    func testCloneSpotRoundTripsAndClamps() {
        let r = CGRect(x: 100, y: 50, width: 1000, height: 600), size = CGSize(width: 40, height: 30)
        let s = CloneSpot(point: CGPoint(x: 600, y: 200), in: r, character: "x")
        XCTAssertEqual(s.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.character, "x")
        XCTAssertEqual(s.point(in: r, size: size), CGPoint(x: 600, y: 200))
        let off = CloneSpot(point: CGPoint(x: -500, y: 9000), in: r, character: nil)
        XCTAssertEqual(off.x, 0)
        XCTAssertEqual(off.y, 1)
        // The whole drawing stays inside: feet at least half its width from the sides, its head under the top.
        XCTAssertEqual(off.point(in: r, size: size), CGPoint(x: 120, y: 620))
        XCTAssertEqual(CloneSpot(character: nil, x: 1, y: 0).point(in: r, size: size), CGPoint(x: 1080, y: 50))
    }

    func testCloneStoreSavesPositionsWithoutLosingIds() {
        let suite = "test.clones.defaults"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let a = CloneStore(defaults: d)
        XCTAssertEqual(a.prefs, ClonePrefs())
        let spot = CloneSpot(character: "orig", x: 0.3, y: 0.1)
        XCTAssertTrue(a.prefs.add(spot))
        a.prefs.clones[0].x = 0.7
        let b = CloneStore(defaults: d)
        XCTAssertEqual(b.prefs.clones.map(\.id), [spot.id])
        XCTAssertEqual(b.prefs.clones[0].x, 0.7)
        XCTAssertEqual(b.prefs.clones[0].character, "orig")
    }

    func testCloneSocialPicksOnlyNearIdlePairs() {
        XCTAssertNil(CloneSocial.pick(distance: CloneSocial.reach + 1, random: 0))
        XCTAssertEqual(CloneSocial.pick(distance: 50, random: 0), .greet)
        XCTAssertEqual(CloneSocial.pick(distance: 50, random: 0.5), .chase)
        XCTAssertEqual(CloneSocial.pick(distance: CloneSocial.reach, random: 0.99), .follow)
    }

    func testFocusTimeLeavesOutThePauses() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = FocusSession(start: t0)
        XCTAssertEqual(s.elapsed(t0 + 3), 3)
        s.pause(t0 + 10)
        XCTAssertEqual(s.elapsed(t0 + 50), 10)   // nothing counts while paused
        s.resume(t0 + 70)
        XCTAssertEqual(s.elapsed(t0 + 75), 15)
        XCTAssertEqual(FocusSession.clock(3), "00:03")
        XCTAssertEqual(FocusSession.clock(25 * 60), "25:00")
        XCTAssertEqual(FocusSession.clock(3723), "1:02:03")
    }

    func testFocusProgressToTheGoal() {
        XCTAssertNil(FocusSession.progress(600, goal: 0))   // 끄기
        XCTAssertEqual(FocusSession.progress(0, goal: 25), 0)
        XCTAssertEqual(FocusSession.progress(750, goal: 25), 0.5)
        XCTAssertEqual(FocusSession.progress(3600, goal: 25), 1)   // past the goal stays full
    }

    func testFocusMoodByStageAndHour() {
        let cases: [(min: Double, hour: Int, paused: Bool, polite: Bool, line: String)] = [
            (10, 14, true, false, "잠깐 쉬는 중 ☕"),
            (2, 14, false, false, "시작이 반!"),
            (2, 7, false, false, "아침 집중 ☀️"),
            (30, 7, false, false, "몰입 중이야 ✨"),   // morning is only for a start
            (10, 14, false, false, "집중 시작!"),
            (30, 14, false, true, "몰입 중이에요 ✨"),
            (60, 14, false, false, "대단해, 오래 버텼어!"),
            (60, 23, false, false, "늦은 밤 집중 🌙"),
            (2, 3, false, true, "늦은 밤 집중 🌙"),
            (2, 3, true, true, "잠깐 쉬는 중 ☕"),   // a pause wins over the hour
        ]
        for c in cases {
            XCTAssertEqual(FocusSession.mood(elapsed: c.min * 60, hour: c.hour, paused: c.paused, polite: c.polite), c.line, "\(c)")
        }
    }

    func testFocusSettingsDefaultForExistingUsers() {
        let suite = "test.focus.defaults"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(false, forKey: "focus.menuBar")   // an owner who set only the old key
        let c = FocusCenter(defaults: d)
        XCTAssertFalse(c.showInMenuBar)
        XCTAssertEqual(c.theme, .lavender)
        XCTAssertEqual(c.size, .normal)
        XCTAssertEqual(c.goalMinutes, 25)
        XCTAssertTrue(c.sound)
        XCTAssertTrue(c.menuEmoji)
        c.theme = .mint; c.goalMinutes = 0
        let again = FocusCenter(defaults: d)
        XCTAssertEqual(again.theme, .mint)
        XCTAssertEqual(again.goalMinutes, 0)
    }

    func testQuickAskGreetingFollowsTheHourAndPersona() {
        XCTAssertEqual(FriendQuickAsk.greeting(hour: 8, polite: true), "좋은 아침이에요! 뭐 궁금해요?")
        XCTAssertEqual(FriendQuickAsk.greeting(hour: 8, polite: false), "좋은 아침! 뭐 궁금해?")
        XCTAssertEqual(FriendQuickAsk.greeting(hour: 12, polite: true), "점심 먹었어요? 뭐 궁금해요?")
        XCTAssertEqual(FriendQuickAsk.greeting(hour: 23, polite: false), "밤이 깊었네. 뭐 도와줄까?")
        XCTAssertEqual(FriendQuickAsk.greeting(hour: 3, polite: true), "밤이 깊었네요. 뭐 도와줄까요?")
        for h in 0..<24 { XCTAssertFalse(FriendQuickAsk.greeting(hour: h, polite: false).contains("요"), "\(h)") }
    }

    func testQuickAskCardAndConfetti() {
        XCTAssertEqual(FriendQuickAsk.card(for: .progress, progress: TodoProgress(done: 4, total: 4)), .proud)
        XCTAssertEqual(FriendQuickAsk.card(for: .progress, progress: TodoProgress(done: 1, total: 4)), .cheer)
        XCTAssertEqual(FriendQuickAsk.card(for: .progress, progress: nil), .cheer)
        XCTAssertEqual(FriendQuickAsk.card(for: .next, progress: nil), .wave)
        XCTAssertEqual(FriendQuickAsk.card(for: .dance, progress: nil), .dance)
        XCTAssertEqual(FriendQuickAsk.confetti(month: 4).first, "🌸")
        XCTAssertEqual(FriendQuickAsk.confetti(month: 12).first, "⛄️")
        for m in 1...12 { XCTAssertFalse(FriendQuickAsk.confetti(month: m).isEmpty) }
    }

    func testQuickAskSettingsDefaultForExistingUsers() {
        let suite = "test.quickask.defaults"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: MotionStore.buddyKey)   // an owner from before 퀵물어보기 had settings
        let m = MotionStore(defaults: d)
        XCTAssertTrue(m.cursorBuddy)
        XCTAssertEqual(m.quickAskTheme, .peach)
        XCTAssertEqual(m.quickAskTextSize, .regular)
        XCTAssertEqual(m.quickAskMotion, .bouncy)
        XCTAssertFalse(m.quickAskSound)
        XCTAssertTrue(m.quickAskShowAvatar)
        m.quickAskTheme = .mint; m.quickAskShowAvatar = false; m.quickAskTextSize = .large
        let again = MotionStore(defaults: d)
        XCTAssertEqual(again.quickAskTheme, .mint)
        XCTAssertEqual(again.quickAskTextSize, .large)
        XCTAssertFalse(again.quickAskShowAvatar)
    }

    func testTodoProgressPraisesOnlyANewTick() {
        let a = TodoProgress(done: 1, total: 4), b = TodoProgress(done: 2, total: 4), all = TodoProgress(done: 4, total: 4)
        XCTAssertNil(TodoProgress.milestone(old: nil, new: b, style: .friendly))   // the first read is no news
        XCTAssertNil(TodoProgress.milestone(old: b, new: b, style: .friendly))
        XCTAssertNil(TodoProgress.milestone(old: b, new: a, style: .friendly))     // one was unticked
        XCTAssertTrue(TodoProgress.milestone(old: a, new: b, style: .friendly)?.contains("2/4") ?? false)
        XCTAssertTrue(TodoProgress.milestone(old: b, new: all, style: .proud)?.contains("제법") ?? false)
        XCTAssertEqual(TodoProgress.next(["보고서", "메일", "장보기", "운동"], polite: true), "지금은 '보고서'부터 해 보면 좋겠어요.\n• 메일\n• 장보기")
    }

    func testFocusAndProgressQuestionsStayOnThisMac() {
        XCTAssertEqual(AssistantIntent.route("집중 시작", hasHistory: false), .focus)
        XCTAssertEqual(AssistantIntent.route("집중 그만할래", hasHistory: false), .focus)
        XCTAssertEqual(AssistantIntent.route("오늘 할 일 얼마나 했어?", hasHistory: false), .todoProgress)
        XCTAssertEqual(AssistantIntent.route("오늘 할 일 뭐 있어?", hasHistory: false), .schedule)
    }

    // MARK: 꾸미기

    func testDecorSettingsDefaultAndSave() {
        let suite = "decor-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        XCTAssertEqual(s.palette, .strawberry)
        XCTAssertEqual(s.motionLevel, .auto)
        XCTAssertTrue(s.friendSounds)
        XCTAssertFalse(s.settingsTextLarge)
        XCTAssertFalse(s.expandDetails)
        s.palette = .mint; s.motionLevel = .calm; s.friendSounds = false; s.settingsTextLarge = true; s.expandDetails = true
        let again = AppSettings(defaults: d)
        XCTAssertEqual(again.palette, .mint)
        XCTAssertEqual(again.motionLevel, .calm)
        XCTAssertFalse(again.friendSounds)
        XCTAssertTrue(again.settingsTextLarge)
        XCTAssertTrue(again.expandDetails)
        d.set("neon", forKey: "palette"); d.set("wild", forKey: "motionLevel")
        XCTAssertEqual(AppSettings(defaults: d).palette, .strawberry)
        XCTAssertEqual(AppSettings(defaults: d).motionLevel, .auto)
    }

    func testPaletteTints() {
        XCTAssertEqual(AppPalette.stickers.count, DesktopTool.allCases.count)
        XCTAssertNil(AppPalette.plain.tint(.cursor))
        XCTAssertNotEqual(AppPalette.strawberry.tint(.cursor), AppPalette.strawberry.tint(.meadow))
        XCTAssertEqual(AppPalette.mint.tint(.rug), AppPalette.mint.accent)
    }

    func testGreetingByHourAndSeason() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func at(_ m: Int, _ d: Int, _ h: Int) -> String {
            DesktopSettingsView.greeting(cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!, calendar: cal)
        }
        XCTAssertEqual(at(5, 3, 8), L("좋은 아침이에요"))
        XCTAssertEqual(at(5, 3, 15), L("오늘도 같이 놀아요"))
        XCTAssertEqual(at(5, 3, 23), L("늦었어요, 살살 놀아요"))
        XCTAssertEqual(at(5, 3, 2), L("늦었어요, 살살 놀아요"))
        XCTAssertEqual(at(10, 30, 9), L("🎃 오늘은 살짝 으스스하게"))
        XCTAssertEqual(at(12, 5, 9), L("🎄 포근한 12월이에요"))
    }
    /// White words sit on every accent (그만하기, 더 물어보기), in light and dark: WCAG AA, 4.5:1.
    func testWhiteOnAccentsIsReadable() {
        func lum(_ hex: String) -> Double {
            let v = Int(hex.dropFirst(), radix: 16) ?? 0
            let bytes: [Int] = [v >> 16, (v >> 8) & 255, v & 255]
            let c: [Double] = bytes.map { b in
                let x = Double(b) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        let accents = [false, true].flatMap { dark in
            FocusTheme.allCases.map { $0.hexes(dark: dark).accent } + QuickAskTheme.allCases.map { $0.hexes(dark: dark).accent }
        }
        for a in accents { XCTAssertGreaterThanOrEqual(1.05 / (lum(a) + 0.05), 4.5, a) }
    }
}
