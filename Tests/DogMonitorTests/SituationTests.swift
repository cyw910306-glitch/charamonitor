import XCTest
@testable import DogMonitor

final class SituationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let all = Set(ExtraMotion.allCases)

    private func battery(_ p: Int, charging: Bool = false) -> BatteryStats {
        BatteryStats(percent: p, isCharging: charging, isPluggedIn: charging, isCharged: false, minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
    }

    /// Seconds (0..<n) where the engine shows `m`, fed once per second from t0.
    private func timeline(_ e: inout SituationEngine, _ n: Int, battery b: BatteryStats?, pose: DogPose = .walk,
                          available: Set<ExtraMotion>? = nil, m: ExtraMotion) -> [Int] {
        (0..<n).filter { e.update(battery: b, pose: pose, available: available ?? all, now: t0.addingTimeInterval(Double($0))) == m }
    }

    func testHungryCadence() {
        var e = SituationEngine()
        let shown = timeline(&e, 90, battery: battery(20), m: .hungry)
        XCTAssertEqual(shown, Array(0..<8) + Array(40..<48) + Array(80..<88))
        var high = SituationEngine()
        XCTAssertTrue(timeline(&high, 90, battery: battery(21), m: .hungry).isEmpty)
    }

    func testChargingBurstThenEveryFiveMinutes() {
        var e = SituationEngine()
        let shown = timeline(&e, 620, battery: battery(15, charging: true), m: .eat)
        XCTAssertEqual(shown, Array(0..<20) + Array(300..<310) + Array(600..<610))
        // Low battery while charging is not hungry.
        var e2 = SituationEngine()
        XCTAssertTrue(timeline(&e2, 60, battery: battery(10, charging: true), m: .hungry).isEmpty)
    }

    func testChargingRestartsBurst() {
        var e = SituationEngine()
        _ = e.update(battery: battery(50, charging: true), pose: .walk, available: all, now: t0)
        XCTAssertNil(e.update(battery: battery(50, charging: true), pose: .walk, available: all, now: t0 + 100))
        XCTAssertNil(e.update(battery: battery(50), pose: .walk, available: all, now: t0 + 101))
        XCTAssertEqual(e.update(battery: battery(50, charging: true), pose: .walk, available: all, now: t0 + 102), .eat)
    }

    func testSpecialOnlyForCharactersThatHaveIt() {
        var e = SituationEngine()
        XCTAssertEqual(timeline(&e, 65, battery: nil, pose: .sprint, m: .special), Array(0..<6) + Array(30..<36) + Array(60..<65))
        var none = SituationEngine()
        XCTAssertTrue(timeline(&none, 65, battery: nil, pose: .exhausted, available: [.hungry, .eat], m: .special).isEmpty)
        var calm = SituationEngine()
        XCTAssertTrue(timeline(&calm, 65, battery: nil, pose: .run, m: .special).isEmpty)
    }

    func testDesktopNeverHungryOrEats() {
        var e = SituationEngine()
        for s in 0..<400 {
            let m = e.update(battery: nil, pose: .walk, available: all, now: t0.addingTimeInterval(Double(s)))
            XCTAssertNil(m)
        }
    }

    func testPrefsChoiceAndFrequency() {
        var p = MotionPrefs()
        p.lowBattery = .init(choice: .motion(.special), frequency: .often)
        p.busy.choice = .off
        var e = SituationEngine(prefs: p)
        XCTAssertEqual(timeline(&e, 45, battery: battery(5), pose: .sprint, m: .special), Array(0..<8) + Array(20..<28) + Array(40..<45))
    }

    func testPrefsCodableAndPersist() throws {
        var p = MotionPrefs()
        p.charging = .init(choice: .motion(.hungry), frequency: .rarely)
        p.busy.choice = .off
        let back = try JSONDecoder().decode(MotionPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        let suite = "SituationTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MotionPrefs.load(d), .defaults)
        p.save(d)
        XCTAssertEqual(MotionPrefs.load(d), p)
        d.set(Data("junk".utf8), forKey: MotionPrefs.key)
        XCTAssertEqual(MotionPrefs.load(d), .defaults)
    }

    // MARK: Cursor buddy math

    private let size = CGSize(width: 68, height: 40)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testBuddyRestsLowerRightOfCursor() {
        let c = CGPoint(x: 500, y: 500)
        let o = BuddyMath.target(cursor: c, size: size)
        XCTAssertGreaterThan(o.x, c.x)
        XCTAssertLessThan(o.y + size.height, c.y)
        XCTAssertFalse(BuddyMath.covers(o, size: size, cursor: c))
    }

    func testBuddyLagsAtConstantSpeed() {
        let p = BuddyMath.step(from: .zero, to: CGPoint(x: 1000, y: 0), dt: 1.0 / 30)
        XCTAssertEqual(p.x, BuddyMath.speed / 30, accuracy: 0.001)
        XCTAssertEqual(p.y, 0)
        XCTAssertEqual(BuddyMath.step(from: .zero, to: CGPoint(x: 3, y: 4), dt: 1), CGPoint(x: 3, y: 4))
    }

    func testBuddyRunsWhenCursorGotFarAheadUntilItArrives() {
        XCTAssertFalse(BuddyMath.runs(distance: 40, wasRunning: false))   // slow cursor: walks after it
        XCTAssertTrue(BuddyMath.runs(distance: BuddyMath.runStart + 1, wasRunning: false))
        XCTAssertTrue(BuddyMath.runs(distance: 20, wasRunning: true))     // keeps running once it started
        XCTAssertFalse(BuddyMath.runs(distance: 0, wasRunning: true))
        XCTAssertGreaterThan(BuddyMath.runSpeed, BuddyMath.speed)
    }

    func testBuddyEatsOnlyOnTheCharger() {
        let base = BatteryStats(percent: 60, isCharging: false, isPluggedIn: false, isCharged: false, minutesRemaining: nil,
                                cycleCount: nil, healthPercent: nil)
        var plugged = base; plugged.isPluggedIn = true
        var charging = base; charging.isCharging = true
        XCTAssertFalse(BuddyMath.eats(base))
        XCTAssertTrue(BuddyMath.eats(plugged))
        XCTAssertTrue(BuddyMath.eats(charging))
        XCTAssertFalse(BuddyMath.eats(nil))   // desktop Mac: sleeps
    }

    func testBuddyClampsAndAvoidsHotSpot() {
        let off = BuddyMath.place(CGPoint(x: 2000, y: -50), size: size, cursor: CGPoint(x: 700, y: 400), in: screen)
        XCTAssertEqual(off, CGPoint(x: screen.maxX - size.width, y: 0))
        // Bottom-right corner: lower right would be clamped onto the cursor, so it goes upper left.
        let corner = CGPoint(x: 1430, y: 10)
        let o = BuddyMath.place(BuddyMath.target(cursor: corner, size: size), size: size, cursor: corner, in: screen)
        XCTAssertFalse(BuddyMath.covers(o, size: size, cursor: corner))
        XCTAssertTrue(screen.contains(CGRect(origin: o, size: size)))
        // Mid-chase right on top of the cursor.
        let c = CGPoint(x: 600, y: 600)
        let mid = BuddyMath.place(CGPoint(x: 580, y: 590), size: size, cursor: c, in: screen)
        XCTAssertFalse(BuddyMath.covers(mid, size: size, cursor: c))
    }

    // MARK: Cursor buddy speed, size and idle life

    func testBuddyBoostGrowsWithSpeedUpToItsMax() {
        XCTAssertEqual(BuddyMath.boost(speed: 0, max: 1.6), 1)
        XCTAssertEqual(BuddyMath.boost(speed: 500, max: 1.6), 1)
        XCTAssertEqual(BuddyMath.boost(speed: 3000, max: 1.6), 1.6, accuracy: 0.0001)
        XCTAssertEqual(BuddyMath.boost(speed: 2500, max: 2), 2, accuracy: 0.0001)
        XCTAssertEqual(BuddyMath.boost(speed: 4000, max: 1), 1, "off: never grows")
        var last: CGFloat = 1
        for v in stride(from: CGFloat(0), through: 3000, by: 100) {
            let b = BuddyMath.boost(speed: v, max: 1.6)
            XCTAssertGreaterThanOrEqual(b, last)
            last = b
        }
    }

    func testBuddyEaseSettlesWithinHalfASecond() {
        var up: CGFloat = 1, down: CGFloat = 2
        for _ in 0..<15 {   // 0.5 s at 30 fps
            up = BuddyMath.ease(up, to: 2, dt: 1.0 / 30)
            down = BuddyMath.ease(down, to: 1, dt: 1.0 / 30)
        }
        XCTAssertGreaterThan(up, 1.99)
        XCTAssertLessThan(down, 1.01)
        XCTAssertGreaterThan(BuddyMath.ease(1, to: 2, dt: 1.0 / 30) - 1, 2 - BuddyMath.ease(2, to: 1, dt: 1.0 / 30), "grows faster than it shrinks")
    }

    func testBuddySizesAreWholeRetinaPixels() {
        XCTAssertEqual(BuddySize.allCases.map(\.pixelSize), [1.5, 2, 3, 4])
        for s in BuddySize.allCases { XCTAssertEqual((s.pixelSize * 2).rounded(), s.pixelSize * 2) }
        XCTAssertEqual(BuddyBoost.allCases.map(\.maxScale), [1, 1.3, 1.6, 2])
    }

    func testBuddyLeanAndParking() {
        let l = BuddyMath.lean(k: 1, dir: 1)
        XCTAssertEqual(l.angle, -12 * .pi / 180, accuracy: 0.0001)   // running right: leans right (clockwise)
        XCTAssertEqual(l.sx, 1.15, accuracy: 0.0001)
        XCTAssertEqual(l.sy, 0.9, accuracy: 0.0001)
        XCTAssertEqual(BuddyMath.lean(k: 0, dir: -1).angle, 0)
        // Parked: the pointer anywhere on it does not chase it off.
        XCTAssertFalse(BuddyMath.leaves(distance: hypot(size.width + BuddyMath.gap, size.height + BuddyMath.gap), size: size))
        XCTAssertTrue(BuddyMath.leaves(distance: 200, size: size))
        // Pivot: the feet stay put whatever the anchor point.
        let t = BuddyMath.transform(angle: 0.3, sx: 1.2, sy: 0.8, pivot: CGPoint(x: 34, y: 0), anchor: .zero, size: size)
        XCTAssertEqual(CGPoint(x: 34, y: 0).applying(t).x, 34, accuracy: 0.0001)
        XCTAssertEqual(CGPoint(x: 34, y: 0).applying(t).y, 0, accuracy: 0.0001)
    }

    func testBuddyPerchSitsOnTheWindowTop() {
        let win = CGRect(x: 200, y: 100, width: 600, height: 500)
        let p = BuddyMath.perch(on: win, x: 900, size: size, in: screen)
        XCTAssertEqual(p, CGPoint(x: 800 - size.width, y: 598))
        XCTAssertEqual(BuddyMath.perch(on: win, x: 300, size: size, in: screen)?.x, 300)
        XCTAssertNil(BuddyMath.perch(on: CGRect(x: 0, y: 0, width: 1440, height: 875), x: 10, size: size, in: screen), "full height: no room")
        XCTAssertNil(BuddyMath.perch(on: CGRect(x: 10, y: 10, width: 40, height: 100), x: 10, size: size, in: screen), "too narrow")
    }

    func testBuddyGripNeverFlipsADrag() {
        let origin = CGPoint(x: 500, y: 400)
        for cursor in [CGPoint(x: 534, y: 420), CGPoint(x: 501, y: 401), CGPoint(x: 567, y: 439)] {   // pressed inside the drawing
            var d = Dangle(anchor: cursor, restLength: 12)
            d.grab(at: BuddyMath.grip(origin: origin, size: size, cursor: cursor))
            XCTAssertLessThanOrEqual(abs(d.angle), .pi / 2 + 0.001, "starts below the cursor, never upside down")
        }
        let cling = CGPoint(x: origin.x - BuddyMath.gap, y: origin.y + size.height + BuddyMath.gap)
        XCTAssertEqual(BuddyMath.grip(origin: origin, size: size, cursor: cling), CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height), "clinging: the head")
    }

    func testBuddyPlayIsOnByDefault() {
        let suite = "buddy-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MotionStore(defaults: d).buddyPlay)
        MotionStore(defaults: d).buddyPlay = false
        XCTAssertFalse(MotionStore(defaults: d).buddyPlay)
    }

    func testBuddyPlaysHalfAsOftenAtWork() {
        XCTAssertEqual(BuddyMath.playGap(working: false, random: 0), 60)
        XCTAssertEqual(BuddyMath.playGap(working: false, random: 1), 120)
        XCTAssertEqual(BuddyMath.playGap(working: true, random: 0.5), 180)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let monday10 = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))!
        let saturday10 = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10))!
        var w = WorkHours()
        XCTAssertFalse(w.working(monday10, calendar: cal), "no 업무 시간 line on: never at work")
        w.greet = [.leave]
        XCTAssertTrue(w.working(monday10, calendar: cal))
        XCTAssertFalse(w.working(saturday10, calendar: cal))
        XCTAssertFalse(w.working(cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18))!, calendar: cal))
    }

    func testButterflyStoryTimeline() {
        XCTAssertEqual(ButterflyStory.phase(0), .approach)
        XCTAssertEqual(ButterflyStory.phase(3), .chase)
        XCTAssertEqual(ButterflyStory.phase(4.6), .hop)
        XCTAssertEqual(ButterflyStory.phase(5.5), .escape)
        XCTAssertEqual(ButterflyStory.phase(7), .sulk)
        XCTAssertEqual(ButterflyStory.phase(9), .done)
        let st = ButterflyStory(from: CGPoint(x: 900, y: 300), spot: CGPoint(x: 600, y: 200))
        XCTAssertEqual(st.away, -1)
        XCTAssertEqual(st.butterfly(0)?.x ?? 0, 900, accuracy: 0.001)
        XCTAssertEqual(st.butterfly(ButterflyStory.approach - 0.0001)?.x ?? 0, 600, accuracy: 0.5)
        XCTAssertLessThan(st.butterfly(4.4)?.x ?? .infinity, 600, "keeps flying the same way")
        XCTAssertNil(st.butterfly(7), "got away")
        XCTAssertEqual(ButterflyStory.lift(1), 0)
        XCTAssertGreaterThan(ButterflyStory.lift(ButterflyStory.approach + ButterflyStory.chase + ButterflyStory.jump / 2), 0.7)
    }
}
