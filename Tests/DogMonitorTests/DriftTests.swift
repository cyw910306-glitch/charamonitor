import XCTest
@testable import DogMonitor

/// 딴짓 지킴이: DriftRules and its pure pieces.
final class DriftTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    /// 2026-10-26 is a Monday.
    private func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
    }

    private func look(_ app: String, url: String? = nil, at d: Date = Date()) -> DriftSample {
        DriftSample(at: d, app: app, appName: app, url: url)
    }

    // MARK: Rules

    func testHostDropsWwwAndMobile() {
        XCTAssertEqual(DriftRules.host("https://www.YouTube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(DriftRules.host("https://m.instagram.com/p/x"), "instagram.com")
        XCTAssertNil(DriftRules.host("about:blank"))
        XCTAssertEqual(DriftRules.normalized(" https://www.Coupang.com/np "), "coupang.com")
        XCTAssertEqual(DriftRules.normalized("WWW.Reddit.com"), "reddit.com")
        XCTAssertEqual(DriftRules.normalized("reddit.com/r/swift"), "reddit.com")
        XCTAssertEqual(DriftRules.normalized("com.valvesoftware.steam"), "com.valvesoftware.steam")
        XCTAssertEqual(DriftRules.normalized("com.google.Chrome"), "com.google.Chrome")
    }

    func testDefaultListsLabelSitesAndApps() {
        let none = DriftLists()
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://www.youtube.com/watch?v=a"), lists: none, profile: ""), .drift)
        XCTAssertEqual(DriftRules.rule(look("com.apple.Safari", url: "https://github.com/x/y"), lists: none, profile: ""), .focus)
        XCTAssertEqual(DriftRules.rule(look("com.valvesoftware.steam"), lists: none, profile: ""), .drift)
        XCTAssertEqual(DriftRules.rule(look("com.apple.dt.Xcode"), lists: none, profile: ""), .focus)
        // A subdomain of a listed site counts; a sibling of a listed subdomain does not.
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://music.youtube.com/"), lists: none, profile: ""), .drift)
        XCTAssertNil(DriftRules.rule(look("com.google.Chrome", url: "https://blog.naver.com/a"), lists: none, profile: ""))
        // A browser with no tab read is neutral; an unknown app is not known.
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome"), lists: none, profile: ""), .neutral)
        XCTAssertNil(DriftRules.rule(look("com.example.unknown"), lists: none, profile: ""))
        // A site decides over a default 딴짓 app id it might share nothing with.
        XCTAssertEqual(DriftRules.rule(look("com.apple.Safari", url: "https://netflix.com/"), lists: none, profile: ""), .drift)
    }

    func testOwnerListsWinOverDefaults() {
        var lists = DriftLists()
        lists.add("youtube.com", to: .focus)
        lists.add("https://www.example.org/x", to: .drift)
        lists.add("com.apple.dt.Xcode", to: .drift)
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://youtube.com/x"), lists: lists, profile: ""), .focus)
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://example.org/"), lists: lists, profile: ""), .drift)
        XCTAssertEqual(DriftRules.rule(look("com.apple.dt.Xcode"), lists: lists, profile: ""), .drift)
        // Adding to one list takes it off the other.
        lists.add("youtube.com", to: .drift)
        XCTAssertFalse(lists.focus.contains("youtube.com"))
        XCTAssertTrue(lists.drift.contains("youtube.com"))
    }

    func testProfileTurnsAKindNeutral() {
        let none = DriftLists()
        let yt = look("com.google.Chrome", url: "https://youtube.com/watch")
        XCTAssertEqual(DriftRules.rule(yt, lists: none, profile: "유튜브 영상 편집자"), .neutral)
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://instagram.com/"), lists: none, profile: "유튜브 영상 편집자"), .drift)
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://instagram.com/"), lists: none, profile: "SNS 마케터"), .neutral)
        // "md" is a whole word, not a part of "command".
        XCTAssertEqual(DriftRules.workKinds("패션 MD"), [.shopping])
        XCTAssertEqual(DriftRules.workKinds("command line dev"), [])
    }

    func testCorrectionMovesAndLogs() {
        var lists = DriftLists()
        lists.correct("https://www.youtube.com/watch?v=1", to: .focus, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(lists.focus, ["youtube.com"])
        XCTAssertEqual(lists.corrections.last?.key, "youtube.com")
        XCTAssertEqual(DriftRules.rule(look("com.google.Chrome", url: "https://youtube.com/"), lists: lists, profile: ""), .focus)
        for i in 0..<60 { lists.correct("site\(i).com", to: .drift, at: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(lists.corrections.count, DriftLists.keepCorrections)
        XCTAssertEqual(lists.corrections.last?.key, "site59.com")
    }

    func testParseAIReadsOneWordOnly() {
        XCTAssertEqual(DriftRules.parseAI("딴짓이에요."), .drift)
        XCTAssertEqual(DriftRules.parseAI(" 집중 "), .focus)
        XCTAssertEqual(DriftRules.parseAI("Neutral"), .neutral)
        XCTAssertNil(DriftRules.parseAI("집중일 수도 딴짓일 수도"))
        XCTAssertNil(DriftRules.parseAI("모르겠어요"))
        XCTAssertTrue(DriftRules.aiPrompt(look("com.google.Chrome", url: "https://a.com/"), profile: "").contains("사이트: a.com"))
    }

    // MARK: Blocks

    func testBlockLabelByShare() {
        XCTAssertNil(DriftRules.label([]))
        XCTAssertEqual(DriftRules.label([.drift, .focus]), .drift)            // half is enough for drift
        XCTAssertEqual(DriftRules.label([.drift, .focus, .focus]), .focus)
        XCTAssertEqual(DriftRules.label([.neutral, .neutral, .drift, .focus, .focus]), .neutral)
        XCTAssertEqual(DriftRules.label(Array(repeating: .drift, count: 9) + Array(repeating: .focus, count: 9)), .drift)
    }

    func testBlockStartsLineUpWithTheClock() {
        XCTAssertEqual(DriftRules.blockStart(at(26, 10, 4, 59), calendar: cal), at(26, 10, 3))
        XCTAssertEqual(DriftRules.blockStart(at(26, 10, 6), calendar: cal), at(26, 10, 6))
        XCTAssertEqual(DriftRules.blockStart(at(26, 23, 59, 59), calendar: cal), at(26, 23, 57))
        XCTAssertEqual(DriftRules.blockStart(at(27, 0, 0, 1), calendar: cal), at(27, 0, 0))
    }

    func testBlockerClosesOnTheNextBlockWithTheTopLook() {
        var b = DriftBlocker()
        var closed: DriftBlocker.Closed?
        for i in 0..<18 {   // 10:00:00 ... 10:02:50, two thirds YouTube
            let url = i % 3 == 0 ? "https://github.com/" : "https://youtube.com/watch"
            let s = look("com.google.Chrome", url: url, at: at(26, 10, 0, i * 10))
            closed = b.add(s, i % 3 == 0 ? .focus : .drift, calendar: cal) ?? closed
        }
        XCTAssertNil(closed)
        closed = b.add(look("com.apple.dt.Xcode", at: at(26, 10, 3)), .focus, calendar: cal)
        XCTAssertEqual(closed?.start, at(26, 10, 0))
        XCTAssertEqual(closed?.label, .drift)
        XCTAssertEqual(closed?.top, "youtube.com")
        XCTAssertEqual(closed?.sample.url, "https://youtube.com/watch")
        // Across midnight: the 23:57 block ends at 00:00.
        var n = DriftBlocker()
        _ = n.add(look("x", at: at(26, 23, 58)), .drift, calendar: cal)
        XCTAssertEqual(n.add(look("x", at: at(27, 0, 0, 5)), .drift, calendar: cal)?.start, at(26, 23, 57))
    }

    // MARK: Confirming

    func testConfirmNeedsConsecutiveDriftBlocks() {
        var w = DriftWatch(needed: 2)
        let t = at(26, 10)
        XCTAssertFalse(w.feed(.drift, at: t, active: true))
        XCTAssertFalse(w.feed(.neutral, at: t + 180, active: true))   // anything else starts again
        XCTAssertFalse(w.feed(.drift, at: t + 360, active: true))
        XCTAssertTrue(w.feed(.drift, at: t + 540, active: true))      // 6 minutes in a row
        XCTAssertEqual(w.streak, 0)
        // Not while not watching.
        var off = DriftWatch(needed: 1)
        XCTAssertFalse(off.feed(.drift, at: t, active: false))
        XCTAssertTrue(off.feed(.drift, at: t, active: true))
    }

    func testCooldownSnoozeAndRecheck() {
        var w = DriftWatch(needed: 1, cooldown: 900)
        let t = at(26, 10)
        XCTAssertTrue(w.feed(.drift, at: t, active: true))
        XCTAssertFalse(w.feed(.drift, at: t + 600, active: true))     // within 15 minutes
        XCTAssertTrue(w.feed(.drift, at: t + 900, active: true))
        w.snooze(20, now: t + 900)
        XCTAssertFalse(w.feed(.drift, at: t + 900 + 1199, active: true))
        XCTAssertTrue(w.feed(.drift, at: t + 900 + 1200, active: true))
        // "아직 딴짓 중이에요?" 네: the very next drift block, cooldown or not.
        var r = DriftWatch(needed: 2, cooldown: 900)
        XCTAssertFalse(r.feed(.drift, at: t, active: true))
        XCTAssertTrue(r.feed(.drift, at: t + 180, active: true))
        r.recheckSoon()
        XCTAssertTrue(r.feed(.drift, at: t + 360, active: true))
    }

    func testActiveDuringTimerOrWorkHours() {
        let h = DriftHours(start: 9 * 60, end: 18 * 60, weekdaysOnly: true)
        let monday10 = at(26, 10), monday20 = at(26, 20), saturday10 = at(31, 10)
        XCTAssertTrue(DriftRules.active(on: true, withTimer: false, timerRunning: false, hoursOn: true, hours: h, now: monday10, calendar: cal))
        XCTAssertFalse(DriftRules.active(on: true, withTimer: false, timerRunning: false, hoursOn: true, hours: h, now: monday20, calendar: cal))
        XCTAssertFalse(DriftRules.active(on: true, withTimer: false, timerRunning: false, hoursOn: true, hours: h, now: saturday10, calendar: cal))
        XCTAssertFalse(DriftRules.active(on: true, withTimer: false, timerRunning: false, hoursOn: false, hours: h, now: monday10, calendar: cal))
        XCTAssertTrue(DriftRules.active(on: true, withTimer: false, timerRunning: true, hoursOn: true, hours: h, now: monday20, calendar: cal))
        // 타이머 중 자동: the timer alone, with the switch off.
        XCTAssertTrue(DriftRules.active(on: false, withTimer: true, timerRunning: true, hoursOn: false, hours: h, now: saturday10, calendar: cal))
        XCTAssertFalse(DriftRules.active(on: false, withTimer: true, timerRunning: false, hoursOn: true, hours: h, now: monday10, calendar: cal))
        XCTAssertFalse(DriftRules.active(on: false, withTimer: false, timerRunning: true, hoursOn: true, hours: h, now: monday10, calendar: cal))
    }

    func testWorkHoursAcrossMidnight() {
        let night = DriftHours(start: 22 * 60, end: 2 * 60, weekdaysOnly: true)
        XCTAssertTrue(night.contains(at(26, 23), calendar: cal))           // Monday night
        XCTAssertTrue(night.contains(at(27, 1, 30), calendar: cal))        // Tuesday 01:30 belongs to Monday night
        XCTAssertFalse(night.contains(at(27, 2), calendar: cal))           // end is not inside
        XCTAssertFalse(night.contains(at(27, 12), calendar: cal))
        XCTAssertTrue(night.contains(at(31, 1), calendar: cal))            // Saturday 01:00 is Friday night
        XCTAssertFalse(night.contains(at(31, 23), calendar: cal))          // Saturday night
        XCTAssertFalse(night.contains(at(26, 1), calendar: cal))           // Monday 01:00 is Sunday night
        let day = DriftHours(start: 9 * 60, end: 18 * 60, weekdaysOnly: false)
        XCTAssertTrue(day.contains(at(31, 9), calendar: cal))
        XCTAssertFalse(day.contains(at(31, 18), calendar: cal))
        XCTAssertEqual(DriftHours.clock(9 * 60 + 5), "09:05")
    }

    // MARK: Closing

    func testProtectionKeepsWhatMustStay() {
        let own = "com.jelly.dogmonitor", steam = "com.valvesoftware.steam"
        func ok(_ app: String, front: String? = nil, protected: Set<String> = [], inUse: Bool = false, inCall: Bool = false) -> Bool {
            DriftRules.appClosable(app, frontmost: front ?? app, own: own, protected: protected, inUse: inUse, inCall: inCall)
        }
        XCTAssertTrue(ok(steam))
        XCTAssertFalse(ok(steam, front: "com.apple.dt.Xcode"))                 // not in front
        XCTAssertFalse(ok(steam, protected: [steam]))
        XCTAssertFalse(ok(steam, inUse: true))                                 // playing or recording
        XCTAssertFalse(ok(steam, inCall: true))
        XCTAssertFalse(ok(own))
        XCTAssertFalse(ok("com.apple.finder"))
        XCTAssertFalse(ok("us.zoom.xos"))
        XCTAssertFalse(ok("com.google.Chrome"))                                // a browser loses a tab, never itself
        for id in ["com.apple.systempreferences", "com.apple.installer", "com.apple.DiskUtility", "com.apple.ActivityMonitor"] {
            XCTAssertFalse(ok(id), id)                                         // mid-job system apps, whatever the AI said
        }
        for id in ["com.spotify.client", "com.kakao.KakaoTalkMac", "com.apple.Terminal"] {
            XCTAssertFalse(ok(id, protected: CleanerRules.defaultProtected), id)
        }
        XCTAssertTrue(DriftRules.tabClosable("com.google.Chrome", frontmost: "com.google.Chrome", protected: [], inCall: false))
        XCTAssertFalse(DriftRules.tabClosable("com.google.Chrome", frontmost: "com.apple.Safari", protected: [], inCall: false))
        XCTAssertFalse(DriftRules.tabClosable("com.google.Chrome", frontmost: "com.google.Chrome", protected: [], inCall: true))
        XCTAssertFalse(DriftRules.tabClosable("com.example.app", frontmost: "com.example.app", protected: [], inCall: false))
    }

    func testScriptsNameTheBrowserAndRecheckTheURL() {
        let url = "https://youtube.com/watch?v=\"x\"\\y"
        let chrome = DriftScript.closeTab(.chrome, url: url)
        XCTAssertTrue(chrome.contains("tell application id \"com.google.Chrome\""))
        XCTAssertTrue(chrome.contains("set t to active tab of front window"))
        XCTAssertTrue(chrome.contains("if (URL of t) is not \"https://youtube.com/watch?v=\\\"x\\\"\\\\y\" then return \"changed\""))
        XCTAssertTrue(chrome.contains("close t"))
        XCTAssertTrue(chrome.contains("considering case"))                     // ?v=abcD is not ?v=ABCd
        let safari = DriftScript.closeTab(.safari, url: "https://a.com/")
        XCTAssertTrue(safari.contains("current tab of front window"))
        XCTAssertFalse(safari.contains("active tab"))
        XCTAssertTrue(DriftScript.frontTab(.safari).contains("(name of t)"))
        XCTAssertTrue(DriftScript.frontTab(.whale).contains("com.naver.Whale") && DriftScript.frontTab(.whale).contains("(title of t)"))
        XCTAssertTrue(DriftScript.showTab(.arc, url: "https://a.com/").contains("set active tab index of w to i"))
        XCTAssertTrue(DriftScript.showTab(.safari, url: "https://a.com/").contains("set current tab of w to t"))
        // A line break in a URL never breaks out of the literal.
        XCTAssertEqual(DriftScript.quote("a\nb\"c"), "\"a\\nb\\\"c\"")
        XCTAssertEqual(DriftScript.parseTab("https://a.com/x\u{1E}제목 있음\n")?.title, "제목 있음")
        XCTAssertNil(DriftScript.parseTab(""))
        XCTAssertNil(DriftScript.parseTab("favorites\u{1E}x"))
        XCTAssertEqual(DriftRules.Browser.allCases.count, 7)
    }

    // MARK: The cat

    func testPawCatchWindow() {
        var p = PawPlay(window: 3)
        let t = at(26, 10)
        XCTAssertFalse(p.grab(at: t))                 // nothing to catch while away
        p.run()
        XCTAssertTrue(p.grab(at: t))                  // caught while running in
        XCTAssertEqual(p.phase, .caught)
        p.leave(); p.run(); p.arrive(at: t)
        XCTAssertFalse(p.tick(at: t + 2.9))
        XCTAssertEqual(p.progress(at: t + 1.5), 0.5, accuracy: 0.001)
        XCTAssertTrue(p.grab(at: t + 2.9))            // just in time
        XCTAssertFalse(p.tick(at: t + 5))             // a caught cat never slams
        p.leave(); p.run(); p.arrive(at: t)
        XCTAssertTrue(p.tick(at: t + 3))
        XCTAssertFalse(p.tick(at: t + 4))             // once
        XCTAssertEqual(p.phase, .slammed)
        XCTAssertFalse(p.grab(at: t + 3.1))           // too late
        var late = PawPlay(window: 3)
        late.run(); late.arrive(at: t)
        XCTAssertFalse(late.grab(at: t + 3))          // the paw lands at the window's end
        late.arrive(at: t + 10)                        // arriving twice does not restart the window
        XCTAssertEqual(late.raisedAt, t)
    }

    // MARK: Log

    func testLogKeepsSevenDaysAndCountsToday() {
        var log = DriftLog()
        let now = at(30, 12)
        for d in 20...30 { log.add(DriftLog.Block(start: at(d, 10), label: .drift, top: "x"), now: now, calendar: cal) }
        XCTAssertEqual(log.blocks.count, 7)
        XCTAssertEqual(log.blocks.first?.start, at(24, 10))
        log.add(DriftLog.Block(start: at(30, 10, 3), label: .focus, top: "Xcode"), now: now, calendar: cal)
        log.add(DriftLog.Block(start: at(30, 10, 3), label: .neutral, top: "Finder"), now: now, calendar: cal)   // same block: replaced
        XCTAssertEqual(log.minutes(now, calendar: cal), [.drift: 3, .neutral: 3])
        let back = DriftLog.decode(log.encode())
        XCTAssertEqual(back, log)
        XCTAssertEqual(DriftLog.decode(Data("nope".utf8)), DriftLog())
    }

    #if !MAS
    func testCoatsAndSizes() {
        XCTAssertEqual(DriftCoat.allCases.count, 6)
        XCTAssertEqual(DriftCatSize.allCases.count, 4)
        for c in DriftCoat.allCases {
            XCTAssertNotNil(c.character, c.rawValue)
            XCTAssertNotNil(c.profile, c.rawValue)
        }
        XCTAssertEqual(Set(DriftCoat.allCases.compactMap { $0.profile?.coat }).count, 4)   // tabby, calico, tuxedo, solid
    }

    func testCardLinesNameWhereToGoBack() {
        XCTAssertEqual(DriftCardView.line(.nudge(back: "Xcode"), polite: true), "아까 Xcode 하던 중이었죠. 돌아갈까요?")
        XCTAssertTrue(DriftCardView.line(.closed(what: "youtube.com", back: "Xcode"), polite: true).contains("youtube.com"))
        XCTAssertTrue(DriftCardView.line(.still, polite: false).hasSuffix("?"))
    }
    #endif

    func testStaleBlockAfterAGap() {
        let cal = Calendar(identifier: .gregorian)
        let t0 = DriftRules.blockStart(Date(timeIntervalSince1970: 1_800_000_000), calendar: cal)
        var b = DriftBlocker()
        let s = DriftSample(at: t0 + 10, app: "com.valvesoftware.steam", appName: "Steam")
        XCTAssertFalse(b.stale(at: t0, calendar: cal))                          // nothing open
        _ = b.add(s, .drift, calendar: cal)
        XCTAssertFalse(b.stale(at: t0 + 170, calendar: cal))                    // same block
        XCTAssertFalse(b.stale(at: t0 + 200, calendar: cal))                    // the next one
        XCTAssertTrue(b.stale(at: t0 + 400, calendar: cal))                     // one skipped: away or asleep
    }

    func testCorrectionsKeepSevenDays() {
        var lists = DriftLists()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        lists.correct("old.com", to: .focus, at: now - 8 * 86_400)
        lists.correct("new.com", to: .focus, at: now - 86_400)
        lists.prune(now: now)
        XCTAssertEqual(lists.corrections.map(\.key), ["new.com"])
        XCTAssertEqual(lists.focus, ["old.com", "new.com"])                    // the lists themselves stay
    }
}
