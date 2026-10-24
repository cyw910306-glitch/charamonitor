import XCTest
@testable import DogMonitor

/// HotspotPanel: the clickable shape matches the hit test, and a press, drag past 5 pt, release or right click reach
/// the friend as before while the hotspot grows over the screen and comes back.
final class HotspotTests: XCTestCase {
    /// 4 x 2 frame, top row first: ##.. / .#.#
    private let hit = AlphaHit(width: 4, height: 2, alpha: [255, 255, 0, 0, 0, 255, 0, 255])

    func testPathIsTheDrawnPixels() {
        let size = CGSize(width: 40, height: 20)
        for flipped in [false, true] {
            let path = HotspotShape(hit: hit, drawn: CGRect(origin: .zero, size: size), flipped: flipped).path
            for x in stride(from: CGFloat(1), to: 40, by: 2) {
                for y in stride(from: CGFloat(1), to: 20, by: 2) {
                    let lx = flipped ? size.width - x : x
                    XCTAssertEqual(path.contains(CGPoint(x: x, y: y)), hit.hits(CGPoint(x: lx, y: y), in: size), "\(flipped) \(x),\(y)")
                }
            }
        }
    }

    func testNoMaskIsTheBoxAndExtraAndTransformApply() {
        var s = HotspotShape(drawn: CGRect(x: 0, y: 10, width: 10, height: 10))
        s.extra = [CGRect(x: 0, y: 0, width: 10, height: 10)]
        XCTAssertTrue(s.path.contains(CGPoint(x: 5, y: 15)))
        XCTAssertTrue(s.path.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(s.path.contains(CGPoint(x: 15, y: 5)))
        s.transform = CGAffineTransform(translationX: 100, y: 0)
        XCTAssertTrue(s.path.contains(CGPoint(x: 105, y: 5)))
        XCTAssertFalse(s.path.contains(CGPoint(x: 5, y: 5)))
        XCTAssertTrue(HotspotShape().path.isEmpty)
    }

    func testGrowsOnlyPastFivePoints() {
        XCTAssertEqual(HotspotPanel.growAfter, 5)
        XCTAssertFalse(HotspotPanel.grows(from: .zero, to: CGPoint(x: 3, y: 3.9)))
        XCTAssertTrue(HotspotPanel.grows(from: .zero, to: CGPoint(x: 3, y: 4)))
        XCTAssertEqual(HotspotPanel.alpha, 1.0 / 255)
    }

    func testFlippedRugOutlineIsCoveredBothWays() {
        let walls = CGRect(x: 0, y: 0, width: 800, height: 600)
        var c = ClothSheet(origin: CGPoint(x: 100, y: 100), walls: walls)
        _ = c.grab(at: CGPoint(x: 100, y: 100)); c.drag(to: CGPoint(x: 260, y: 260))
        for _ in 0..<60 { c.step(dt: 1.0 / 60) }
        let path = c.outline()
        for x in stride(from: CGFloat(0), to: 500, by: 7) {
            for y in stride(from: CGFloat(0), to: 500, by: 7) {
                XCTAssertEqual(path.contains(CGPoint(x: x, y: y), using: .winding), c.covers(CGPoint(x: x, y: y)), "\(x),\(y)")
            }
        }
    }

    /// Mouse events sent straight to the panel, as AppKit would: every one reaches `onMouse` once and in order, a drag
    /// past 5 pt grows it over its screen one level up, and the release (or a right click) puts it back.
    @MainActor
    func testEventsReachTheFriendAndTheDragGrowsAndShrinks() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        HotspotPanel.qaInert = true   // never on the real screen
        let hot = HotspotPanel()
        defer { hot.hide() }
        var seen: [NSEvent.EventType] = []
        hot.onMouse = { seen.append($0.type) }
        let home = CGRect(x: screen.visibleFrame.midX.rounded(), y: screen.visibleFrame.midY.rounded(), width: 40, height: 20)   // whole points: the window server snaps frames
        hot.place(home, HotspotShape(drawn: CGRect(x: 0, y: 0, width: 40, height: 20)), level: .floating)
        XCTAssertEqual(hot.frame, home)

        func send(_ type: NSEvent.EventType, _ dx: CGFloat, flags: NSEvent.ModifierFlags = []) {
            let at = CGPoint(x: home.minX + 10 + dx, y: home.minY + 10)
            let local = hot.convertPoint(fromScreen: at)
            guard let e = NSEvent.mouseEvent(with: type, location: local, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: hot.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            hot.sendEvent(e)
        }
        // A click and a fast second one (연타): each press and release goes through, nothing grows.
        for _ in 0..<2 { send(.leftMouseDown, 0); send(.leftMouseUp, 0) }
        XCTAssertEqual(seen, [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertFalse(hot.grown)

        // A wiggle under 5 pt stays small; past it the hotspot covers the screen one level up.
        seen = []
        send(.leftMouseDown, 0)
        send(.leftMouseDragged, 3)
        XCTAssertFalse(hot.grown)
        XCTAssertEqual(hot.frame, home)
        send(.leftMouseDragged, 30)
        XCTAssertTrue(hot.grown)
        XCTAssertEqual(hot.frame, screen.visibleFrame)
        XCTAssertEqual(hot.level.rawValue, NSWindow.Level.floating.rawValue + 1)
        send(.leftMouseDragged, 300)   // far off the friend's box: still its drag (throw)
        // The friend moves under the drag: nothing moves the grown hotspot until the release.
        hot.place(home.offsetBy(dx: 50, dy: 0), HotspotShape(drawn: CGRect(x: 0, y: 0, width: 40, height: 20)), level: .floating)
        XCTAssertEqual(seen, [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged])
        send(.leftMouseUp, 300)
        XCTAssertEqual(seen.last, .leftMouseUp)
        XCTAssertFalse(hot.grown)
        XCTAssertEqual(hot.frame, home.offsetBy(dx: 50, dy: 0))
        XCTAssertEqual(hot.level, .floating)
    }

    @MainActor
    func testRightClickReachesTheFriendAndAMissedReleaseShrinks() {
        HotspotPanel.qaInert = true
        let hot = HotspotPanel()
        defer { hot.hide() }
        var seen: [NSEvent.EventType] = []
        hot.onMouse = { seen.append($0.type) }
        let home = CGRect(x: 200, y: 200, width: 40, height: 40)
        hot.place(home, HotspotShape(drawn: CGRect(x: 0, y: 0, width: 40, height: 40)), level: .floating)
        func event(_ type: NSEvent.EventType, _ at: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: hot.convertPoint(fromScreen: at), modifierFlags: [], timestamp: 0,
                               windowNumber: hot.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.rightMouseDown, CGPoint(x: 210, y: 210)) { hot.sendEvent(e) }
        XCTAssertEqual(seen, [.rightMouseDown])
        // Grown by a drag whose release went elsewhere (a menu, another app): the next placing puts it back.
        for (t, p) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 210, y: 210)), (.leftMouseDragged, CGPoint(x: 260, y: 210))] {
            if let e = event(t, p) { hot.sendEvent(e) }
        }
        XCTAssertTrue(hot.grown)
        hot.place(home, HotspotShape(drawn: CGRect(x: 0, y: 0, width: 40, height: 40)), level: .floating)   // no button is down for real
        XCTAssertFalse(hot.grown)
        XCTAssertEqual(hot.frame, home)
    }
}
