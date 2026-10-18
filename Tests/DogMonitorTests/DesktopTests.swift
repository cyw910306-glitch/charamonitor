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
}
