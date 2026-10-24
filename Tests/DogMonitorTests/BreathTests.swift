import XCTest
@testable import DogMonitor

final class BreathTests: XCTestCase {
    func testPlanIsFourCyclesOfFourAndFour() {
        XCTAssertEqual(BreathPlan.seconds, 32)
        XCTAssertEqual(BreathPlan.phase(0).phase, .inhale)
        XCTAssertEqual(BreathPlan.phase(3.9).phase, .inhale)
        XCTAssertEqual(BreathPlan.phase(4).phase, .exhale)
        XCTAssertEqual(BreathPlan.phase(8.1).phase, .inhale)
        XCTAssertEqual(BreathPlan.phase(31.9).phase, .exhale)
        XCTAssertEqual(BreathPlan.phase(32).phase, .done)
        XCTAssertEqual(BreathPlan.phase(-1).phase, .inhale)   // a clock a hair behind the start
    }

    func testCircleFillsOnInhaleAndEmptiesOnExhale() {
        XCTAssertEqual(BreathPlan.circle(0), 0, accuracy: 1e-9)
        XCTAssertEqual(BreathPlan.circle(2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BreathPlan.circle(4), 1, accuracy: 1e-9)
        XCTAssertEqual(BreathPlan.circle(6), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BreathPlan.circle(40), 0)
        for t in stride(from: 0.0, to: 32, by: 0.37) { XCTAssertTrue((0...1).contains(BreathPlan.circle(t))) }
    }

    func testCountRunsFourToOne() {
        XCTAssertEqual([0, 1.1, 2.1, 3.1, 4, 7.9].map(BreathPlan.count), [4, 3, 2, 1, 4, 1])
        XCTAssertEqual(BreathPlan.count(32), 0)
    }

    func testTallyCountsPerDay() {
        var t = BreathTally()
        t.add("2026-10-24"); t.add("2026-10-24")
        XCTAssertEqual(t.today("2026-10-24"), 2)
        XCTAssertEqual(t.today("2026-10-25"), 0)
        t.add("2026-10-25")
        XCTAssertEqual(t, BreathTally(day: "2026-10-25", count: 1))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(BreathTally.key(Date(timeIntervalSince1970: 1_792_800_000), calendar: cal), "2026-10-24")
    }

    func testPraiseByCountAndStyle() {
        XCTAssertNotEqual(BreathTally.praise(1, polite: true), BreathTally.praise(1, polite: false))
        XCTAssertNotEqual(BreathTally.praise(1, polite: true), BreathTally.praise(2, polite: true))
        XCTAssertTrue(BreathTally.praise(5, polite: true).contains("5"))
        for n in 0...6 { XCTAssertFalse(BreathTally.praise(n, polite: n % 2 == 0).contains("\u{2014}")) }
    }

    func testBowlIsSoftAtBothEndsAndWithinRange() {
        let s = SingingBowl.samples(seconds: 2)
        XCTAssertEqual(s.count, Int(2 * SingingBowl.sampleRate))
        XCTAssertLessThanOrEqual(s.map { abs($0) }.max() ?? 1, 1)
        XCTAssertEqual(s.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertLessThan(abs(s.last ?? 1), 1e-3)
        let early = s[4_000..<8_000].map { abs($0) }.max() ?? 0, late = s[80_000..<84_000].map { abs($0) }.max() ?? 1
        XCTAssertGreaterThan(early, late)   // it rings out
        XCTAssertGreaterThan(early, 0.1)
        XCTAssertTrue(SingingBowl.samples(seconds: 0).isEmpty)
    }

    func testCenterRemembersSettingsAndCount() {
        let suite = "test.breath.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let a = BreathCenter(defaults: d)
        XCTAssertEqual(a.scene, .dusk)
        XCTAssertTrue(a.sound)
        XCTAssertFalse(a.offerAfterFocus)   // off by default
        a.scene = .rainForest; a.sound = false; a.offerAfterFocus = true
        d.set(BreathTally.key(Date()), forKey: "breath.day"); d.set(3, forKey: "breath.count")
        let b = BreathCenter(defaults: d)
        XCTAssertEqual(b.scene, .rainForest)
        XCTAssertFalse(b.sound)
        XCTAssertTrue(b.offerAfterFocus)
        XCTAssertEqual(b.todayCount, 3)
        d.set("2000-01-01", forKey: "breath.day")
        XCTAssertEqual(BreathCenter(defaults: d).todayCount, 0)
    }
}
