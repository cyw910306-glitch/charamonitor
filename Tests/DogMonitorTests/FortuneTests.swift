import XCTest
@testable import DogMonitor

/// 오늘의 운세: the day seeds the draw, 다시 뽑기 once a day, the morning nudge, and the lines themselves.
final class FortuneTests: XCTestCase {
    private var store: UserDefaults!
    private let suite = "test.dogmonitor.fortune"

    override func setUp() {
        store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
    }

    override func tearDown() { store.removePersistentDomain(forName: suite) }

    private func date(_ s: String, hour: Int = 9) -> Date {
        var c = DateComponents()
        let p = s.split(separator: "-").map { Int($0)! }
        (c.year, c.month, c.day, c.hour) = (p[0], p[1], p[2], hour)
        return Calendar.current.date(from: c)!
    }

    func testSameDaySameReadingAndDaysDiffer() {
        XCTAssertEqual(Fortune.reading(day: "2026-10-24", draw: 0), Fortune.reading(day: "2026-10-24", draw: 0))
        let month = (1...30).map { Fortune.reading(day: String(format: "2026-11-%02d", $0), draw: 0).headline }
        XCTAssertGreaterThan(Set(month).count, 8)   // not one line all month
    }

    func testSeedIsStable() {   // a friend's Mac must draw the same: no per-process Hasher
        XCTAssertEqual(Fortune.fnv("a"), 0xaf63_dc4c_8601_ec8c)
    }

    func testRedrawChangesEveryLine() {
        for d in 1...28 {
            let day = String(format: "2026-12-%02d", d)
            let a = Fortune.reading(day: day, draw: 0), b = Fortune.reading(day: day, draw: 1)
            XCTAssertNotEqual(a.headline, b.headline)
            XCTAssertNotEqual(a.item, b.item)
            XCTAssertNotEqual(a.color, b.color)
            for (x, y) in zip(a.areas, b.areas) { XCTAssertNotEqual(x.line, y.line) }
            XCTAssertTrue((3...5).contains(a.stars))
        }
    }

    func testTodayKeepsAcrossRestartsAndRedrawsOncePerDay() {
        let now = date("2026-10-24")
        let first = Fortune.today(now: now, store: store)
        XCTAssertEqual(first.draw, 0)
        XCTAssertEqual(Fortune.today(now: now, store: store), first)   // an app restart reads the same
        XCTAssertTrue(Fortune.canRedraw(now: now, store: store))
        let again = Fortune.redraw(now: now, store: store)
        XCTAssertEqual(again?.draw, 1)
        XCTAssertEqual(Fortune.today(now: now, store: store), again)
        XCTAssertNil(Fortune.redraw(now: now, store: store))
        XCTAssertFalse(Fortune.canRedraw(now: now, store: store))
        // The next day starts over.
        let next = Fortune.today(now: date("2026-10-25"), store: store)
        XCTAssertEqual(next.draw, 0)
        XCTAssertTrue(Fortune.canRedraw(now: date("2026-10-25"), store: store))
    }

    func testSavedDrawOutOfRangeIsClamped() {
        XCTAssertEqual(Fortune.draw(on: "d", savedDay: "d", savedDraw: 99), Fortune.redrawsPerDay)
        XCTAssertEqual(Fortune.draw(on: "d", savedDay: "d", savedDraw: -3), 0)
        XCTAssertEqual(Fortune.draw(on: "d", savedDay: "x", savedDraw: 1), 0)
    }

    func testMorningNudge() {
        XCTAssertFalse(Fortune.morningDue(on: false, hour: 9, day: "d", shownDay: nil))   // off by default
        XCTAssertTrue(Fortune.morningDue(on: true, hour: 9, day: "d", shownDay: "yesterday"))
        XCTAssertFalse(Fortune.morningDue(on: true, hour: 9, day: "d", shownDay: "d"))      // already seen today
        XCTAssertFalse(Fortune.morningDue(on: true, hour: 14, day: "d", shownDay: nil))
        XCTAssertFalse(Fortune.morningDue(on: true, hour: 3, day: "d", shownDay: nil))
        XCTAssertFalse(AssistantSettings(defaults: store).fortuneMorning)
    }

    func testLinesAreOursAndEnough() {
        let all = Fortune.allLines
        XCTAssertGreaterThanOrEqual(all.count, 60)
        XCTAssertEqual(Set(all).count, all.count, "a line is repeated")
        XCTAssertFalse(all.contains { $0.contains("\u{2014}") }, "no long dashes")
        for bad in ["죽", "사고", "불행", "저주", "흉"] { XCTAssertFalse(all.contains { $0.contains(bad) }, bad) }
    }
}
