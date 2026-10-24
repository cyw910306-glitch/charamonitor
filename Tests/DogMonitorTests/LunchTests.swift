import XCTest
@testable import DogMonitor

/// 점심 뽑기: the groups filter, 최근 3일 빼기 (and its fallback), one result a day, the reel stops on it, the 11:30 nudge.
final class LunchTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testPoolFollowsTheTickedGroupsAndMine() {
        let p = LunchRules.pool(mine: ["국수집"], categories: [.chinese, .mine], history: [], skipRecent: true, now: at(2026, 10, 26), calendar: cal)
        XCTAssertTrue(p.allSatisfy { $0.category == .chinese || $0.category == .mine })
        XCTAssertTrue(p.contains(LunchMenu(name: "국수집", category: .mine)))
        XCTAssertFalse(LunchRules.pool(mine: ["국수집"], categories: [.korean], history: [], skipRecent: false, now: Date()).contains { $0.category == .mine })
        XCTAssertTrue(LunchRules.pool(mine: [], categories: [], history: [], skipRecent: false, now: Date()).isEmpty)
        XCTAssertTrue(Set(LunchRules.builtIn.map(\.category)).isSuperset(of: LunchCategory.allCases.filter { $0 != .mine }))
    }

    func testRecentDaysLeaveTheReelUnlessNothingIsLeft() {
        let now = at(2026, 10, 26)
        let menu = { (n: String) in LunchMenu(name: n, category: .snack) }
        let history = [LunchPick(menu: menu("떡볶이"), date: at(2026, 10, 23)),   // 3 days ago: out
                       LunchPick(menu: menu("김밥"), date: at(2026, 10, 22))]      // 4 days ago: back in
        let p = LunchRules.pool(mine: [], categories: [.snack], history: history, skipRecent: true, now: now, calendar: cal)
        XCTAssertFalse(p.contains(menu("떡볶이")))
        XCTAssertTrue(p.contains(menu("김밥")))
        XCTAssertTrue(LunchRules.pool(mine: [], categories: [.snack], history: history, skipRecent: false, now: now, calendar: cal).contains(menu("떡볶이")))
        // Only one menu and it was just eaten: it still comes out rather than nothing.
        let one = LunchRules.pool(mine: ["국수집"], categories: [.mine], history: [LunchPick(menu: LunchMenu(name: "국수집", category: .mine), date: now)],
                                  skipRecent: true, now: now, calendar: cal)
        XCTAssertEqual(one.map(\.name), ["국수집"])
    }

    func testOneResultADayAndTheNewestKept() {
        let m = LunchMenu(name: "짜장면", category: .chinese), n = LunchMenu(name: "짬뽕", category: .chinese)
        var h = LunchRules.record(LunchPick(menu: m, date: at(2026, 10, 26, 11)), into: [], calendar: cal)
        h = LunchRules.record(LunchPick(menu: n, date: at(2026, 10, 26, 11, 5)), into: h, calendar: cal)
        XCTAssertEqual(h.map(\.menu), [n])
        for d in 1...20 { h = LunchRules.record(LunchPick(menu: m, date: at(2026, 11, d)), into: h, calendar: cal) }
        XCTAssertEqual(h.count, LunchRules.keepHistory)
        XCTAssertEqual(h.last?.date, at(2026, 11, 20))
    }

    func testReelStopsOnTheResultAndSlowsDown() {
        var rng = SplitMix64(seed: 1)
        let pool = LunchRules.builtIn
        let s = LunchRules.strip(to: pool[3], from: pool, using: &rng)
        XCTAssertEqual(s.last, pool[3])
        XCTAssertEqual(s.count, 19)
        let d = LunchRules.delays(18)
        XCTAssertEqual(d.count, 18)
        XCTAssertEqual(d, d.sorted())
        XCTAssertLessThan(d.reduce(0, +), 4)   // a pull is over in a few seconds
    }

    func testCleanTidiesAndCapsNames() {
        XCTAssertEqual(LunchRules.clean("  회사 앞\n  국수집 "), "회사 앞 국수집")
        XCTAssertNil(LunchRules.clean(" \n\t"))
        XCTAssertEqual(LunchRules.clean(String(repeating: "가", count: 100))?.count, LunchRules.maxName)
    }

    func testNudgeOnWorkdaysAt1130OnceADay() {
        let days: Set<Int> = [2, 3, 4, 5, 6]
        XCTAssertTrue(LunchRules.nudgeDue(now: at(2026, 10, 26, 11, 30), days: days, lastDay: nil, calendar: cal))   // a Monday
        XCTAssertTrue(LunchRules.nudgeDue(now: at(2026, 10, 26, 11, 59), days: days, lastDay: "2026-10-23", calendar: cal))
        XCTAssertFalse(LunchRules.nudgeDue(now: at(2026, 10, 26, 11, 29), days: days, lastDay: nil, calendar: cal))
        XCTAssertFalse(LunchRules.nudgeDue(now: at(2026, 10, 26, 12, 0), days: days, lastDay: nil, calendar: cal))
        XCTAssertFalse(LunchRules.nudgeDue(now: at(2026, 10, 26, 11, 40), days: days, lastDay: "2026-10-26", calendar: cal))
        XCTAssertFalse(LunchRules.nudgeDue(now: at(2026, 10, 25, 11, 30), days: days, lastDay: nil, calendar: cal))  // Sunday
        XCTAssertFalse(LunchRules.nudgeDue(now: at(2026, 10, 9, 11, 30), days: days, lastDay: nil, calendar: cal))   // 한글날
    }

    func testPullRecordsTodayForOtherFeatures() {
        let suite = "test.lunch"
        let saved = AppDefaults.store
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
        defer { AppDefaults.store.removePersistentDomain(forName: suite); AppDefaults.store = saved }
        let lunch = Lunch()
        XCTAssertTrue(lunch.add(" 국수집 "))
        XCTAssertFalse(lunch.add("국수집"))
        lunch.categories = [.mine]
        var rng = SplitMix64(seed: 3)
        let r = lunch.pull(using: &rng)
        XCTAssertEqual(r?.pick.menu.name, "국수집")
        XCTAssertEqual(r?.strip.last?.name, "국수집")
        XCTAssertEqual(Lunch().history.last?.menu.name, "국수집")   // saved and read back
        lunch.categories = []
        XCTAssertNil(lunch.pull(using: &rng))
    }
}
