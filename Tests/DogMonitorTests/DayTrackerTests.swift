import XCTest
@testable import DogMonitor

/// 하루 기록: content rules, 내 기준, the day's blocks, totals, the week, retention, midnight, CSV and the 내 AI batch.
final class DayTrackerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    private func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
    }

    private func tab(_ url: String, _ title: String? = nil, at d: Date = Date()) -> DriftSample {
        DriftSample(at: d, app: "com.google.Chrome", appName: "Chrome", url: url, title: title)
    }

    private func block(_ start: Date, _ label: DriftLabel?, _ top: String = "Xcode", seen: [String: Int]? = nil) -> DayBlock {
        DayBlock(start: start, label: label, top: top, key: top, app: top, title: nil, seen: seen ?? [top: 18])
    }

    // MARK: Content rules: the same site, told apart by path and title

    func testContentTable() {
        let none = DriftLists()
        let table: [(String, String?, String, Bool, DriftLabel?)] = [
            // url, title, profile, videoDrift, expected
            ("https://www.youtube.com/shorts/abc", "웃긴 고양이 #shorts - YouTube", "", true, .drift),
            ("https://m.youtube.com/shorts/abc", nil, "", false, .drift),
            ("https://www.youtube.com/watch?v=1", "SwiftUI 튜토리얼 1강 - YouTube", "", true, .focus),
            ("https://www.youtube.com/watch?v=2", "자료구조 강의 3편", "", true, .focus),
            ("https://www.youtube.com/watch?v=3", "React course for beginners", "", true, .focus),
            ("https://www.youtube.com/watch?v=4", "How to use Figma auto layout", "", true, .focus),
            ("https://www.youtube.com/watch?v=5", "Lecture 4: Dynamic Programming", "", true, .focus),
            ("https://www.youtube.com/watch?v=6", "파이썬 코딩 입문", "", true, .focus),
            ("https://www.youtube.com/watch?v=7", "UX 디자인 세미나 다시보기", "", true, .focus),
            ("https://www.youtube.com/watch?v=8", "아이돌 직캠 모음", "", true, .drift),
            ("https://www.youtube.com/watch?v=8", "아이돌 직캠 모음", "", false, .neutral),
            ("https://www.youtube.com/watch?v=9", "회계 실무 엑셀 꿀팁", "회계 실무", true, .focus),
            ("https://youtu.be/xyz", "WWDC 세션 정리", "", true, .focus),
            ("https://youtu.be/xyz", "먹방 브이로그", "", false, .neutral),
            ("https://www.youtube.com/live/abc", "롤 결승 생중계", "", true, .drift),
            ("https://www.youtube.com/results?search_query=swift", "swift 튜토리얼 - YouTube", "", true, .focus),
            ("https://www.youtube.com/results?search_query=cat", "cat - YouTube", "", true, .neutral),
            ("https://www.youtube.com/", "YouTube", "", false, .drift),
            ("https://www.instagram.com/reel/abc/", "Instagram", "", true, .drift),
            ("https://www.instagram.com/reels/", "Instagram", "", true, .drift),
            ("https://www.instagram.com/", "Instagram", "", true, .drift),
            ("https://www.instagram.com/reel/abc/", "Instagram", "SNS 마케터", true, .neutral),
            ("https://www.tiktok.com/@a/video/1", "TikTok", "", true, .drift),
            ("https://www.facebook.com/reel/1", nil, "", true, .drift),
            ("https://n.news.naver.com/article/001/0001", "환율 마감 : 네이버 뉴스", "", true, .neutral),
            ("https://news.daum.net/economy", "경제 뉴스", "", true, .neutral),
            ("https://n.news.naver.com/article/2", "AI 개발 경쟁 심화", "", true, .focus),
            ("https://entertain.naver.com/now/read?oid=1", "연예 소식", "", true, .drift),
            ("https://sports.naver.com/kbaseball/index", "야구", "", true, .drift),
            ("https://cafe.naver.com/joonggonara", "중고나라 : 네이버 카페", "", true, .drift),
            ("https://cafe.naver.com/codingstudy", "iOS 개발 스터디 : 네이버 카페", "", true, .focus),
            ("https://m.cafe.daum.net/abc", "여행 카페", "", true, .drift),
            ("https://blog.naver.com/a/1", "Swift 동시성 공부 정리 : 네이버 블로그", "", true, .focus),
            ("https://blog.naver.com/a/2", "주말 맛집 후기", "", true, nil),
            ("https://jelly.tistory.com/12", "CSS 그리드 튜토리얼", "", true, .focus),
            ("https://search.naver.com/search.naver?query=x", "x : 네이버 검색", "", true, .neutral),
            ("https://search.naver.com/search.naver?query=swift", "swift 강의 : 네이버 검색", "", true, .focus),
            ("https://www.google.com/search?q=swift", "swiftui tutorial - Google 검색", "", true, .focus),
            ("https://comic.naver.com/webtoon", "네이버 웹툰", "", true, .drift),
            ("https://github.com/x/y", "Pull request", "", true, .focus),
        ]
        XCTAssertGreaterThanOrEqual(table.count, 30)
        for (url, title, profile, videoDrift, want) in table {
            XCTAssertEqual(DriftRules.rule(tab(url, title), lists: none, profile: profile, videoDrift: videoDrift), want, "\(url) \(title ?? "-")")
        }
    }

    func testVideoEditorKeepsShortsNeutral() {
        // 업무 프로필 names video: short clips fall back to the site's rule (neutral for that kind), lectures stay focus.
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/shorts/1"), lists: DriftLists(), profile: "영상 편집자"), .neutral)
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=1", "프리미어 강좌"), lists: DriftLists(), profile: "영상 편집자"), .focus)
    }

    func testOwnerListsStillWinOverContent() {
        var lists = DriftLists()
        lists.add("youtube.com", to: .focus)
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/shorts/1"), lists: lists, profile: ""), .focus)
    }

    func testCleanTitle() {
        XCTAssertEqual(DayContent.clean("(3) SwiftUI 강의 - YouTube"), "SwiftUI 강의")
        XCTAssertEqual(DayContent.clean("Swift 공부 : 네이버 블로그"), "Swift 공부")
        XCTAssertEqual(DayContent.clean(String(repeating: "가", count: 200)).count, 80)
    }

    // MARK: 내 기준

    func testMemoParsesReadableLines() {
        let text = """
        # 내 기준
        youtube.com · 제목에 "피그마" → 집중
        youtube.com/shorts -> 중립
        com.apple.Music → 딴짓
        Slack → 집중
        그냥 메모 한 줄
        """
        let rules = DayMemo.parse(text)
        XCTAssertEqual(rules, [
            DayMemo.Rule(target: "youtube.com", path: nil, title: "피그마", label: .focus),
            DayMemo.Rule(target: "youtube.com", path: "/shorts", title: nil, label: .neutral),
            DayMemo.Rule(target: "com.apple.Music", path: nil, title: nil, label: .drift),
            DayMemo.Rule(target: "Slack", path: nil, title: nil, label: .focus),
        ])
        let lists = DriftLists()
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=1", "피그마 오토레이아웃 - YouTube"), lists: lists, profile: "", memo: rules), .focus)
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/shorts/2"), lists: lists, profile: "", memo: rules), .neutral)
        XCTAssertEqual(DriftRules.rule(DriftSample(at: Date(), app: "com.apple.Music", appName: "음악"), lists: lists, profile: "", memo: rules), .drift)
        XCTAssertEqual(DriftRules.rule(DriftSample(at: Date(), app: "com.tinyspeck.slackmacgap", appName: "Slack"), lists: lists, profile: "", memo: rules), .focus)
        // No memo line about it: the usual rules.
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=3", "먹방"), lists: lists, profile: "", memo: rules), .drift)
    }

    func testMemoEnglishTitleWordAndAppIDCase() {
        let rules = DayMemo.parse("youtube.com · title has \"Figma\" → 집중\nru.keepcoder.Telegram → 집중")
        XCTAssertEqual(rules.first, DayMemo.Rule(target: "youtube.com", path: nil, title: "figma", label: .focus))
        let lists = DriftLists()
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=1", "Figma auto layout"), lists: lists, profile: "", memo: rules), .focus)
        let tg = DriftSample(at: Date(), app: "ru.keepcoder.Telegram", appName: "Telegram")
        XCTAssertEqual(DriftRules.rule(tg, lists: lists, profile: "", memo: rules), .focus)
    }

    func testSameBlockAgainKeepsTheCorrection() {
        var log = DayLog()
        log.add(block(at(26, 10), .drift, "youtube.com"), now: at(26, 10, 1), keepDays: 7, calendar: cal)
        log.relabel(at(26, 10), to: .focus)
        log.add(block(at(26, 10), .drift, "youtube.com"), now: at(26, 10, 3), keepDays: 7, calendar: cal)
        XCTAssertEqual(log.blocks.count, 1)
        XCTAssertEqual(log.blocks[0].label, .focus)
        XCTAssertEqual(log.blocks[0].fixed, true)
    }

    func testMemoBeatsListsAndSpecificBeatsPlain() {
        var lists = DriftLists()
        lists.add("youtube.com", to: .drift)
        let rules = DayMemo.parse("youtube.com → 중립\nyoutube.com · 제목에 \"강의\" → 집중\nyoutube.com → 딴짓")
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=1", "선형대수 강의"), lists: lists, profile: "", memo: rules), .focus)
        // Two plain lines: the later one.
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=1", "먹방"), lists: lists, profile: "", memo: rules), .drift)
    }

    func testCorrectionLineAndAdding() {
        let line = DayMemo.line(key: "youtube.com", title: "(2) 고양이 \"점프\" - YouTube", label: .drift)
        XCTAssertEqual(line, "youtube.com · 제목에 \"고양이 '점프'\" → 딴짓")
        // A site where titles do not tell pages apart: the site alone.
        XCTAssertEqual(DayMemo.line(key: "namu.wiki", title: "문서", label: .drift), "namu.wiki → 딴짓")
        XCTAssertEqual(DayMemo.line(key: "com.apple.Music", title: nil, label: .focus), "com.apple.Music → 집중")
        // The same thing again replaces its line; the round trip parses.
        var memo = DayMemo.adding("namu.wiki → 딴짓", to: "# 메모")
        memo = DayMemo.adding("namu.wiki → 집중", to: memo)
        XCTAssertEqual(memo, "# 메모\nnamu.wiki → 집중")
        XCTAssertEqual(DayMemo.parse(line).first?.title, "고양이 '점프'")
        // The saved line matches the page it came from, " in its title and all.
        let lists = DriftLists(), rules = DayMemo.parse(line)
        XCTAssertEqual(DriftRules.rule(tab("https://youtube.com/watch?v=9", "(2) 고양이 \"점프\" - YouTube"), lists: lists, profile: "", memo: rules), .drift)
        // Long memos keep the newest lines.
        var big = ""
        for i in 0..<400 { big = DayMemo.adding("site\(i).com → 딴짓", to: big) }
        XCTAssertLessThanOrEqual(big.count, DayMemo.maxLength)
        XCTAssertTrue(big.hasSuffix("site399.com → 딴짓"))
    }

    func testCenterAppliesMemoToClassify() {
        let suite = "qa.daytracker.tests"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let c = DriftCenter(defaults: d)
        let s = tab("https://youtube.com/watch?v=1", "고양이 영상")
        XCTAssertEqual(c.classify(s), .drift)
        c.memo = DayMemo.adding(DayMemo.line(key: "youtube.com", title: "고양이 영상", label: .neutral), to: c.memo)
        XCTAssertEqual(c.classify(s), .neutral)
        c.videoDrift = false
        XCTAssertEqual(c.classify(tab("https://youtube.com/watch?v=2", "먹방")), .neutral)
        // Saved and read back.
        XCTAssertEqual(DriftCenter(defaults: d).classify(s), .neutral)
    }

    // MARK: Blocks

    func testRecorderBlocksAwayAndSeen() {
        var r = DayRecorder()
        var t = at(26, 10)
        // 18 looks: 12 lecture, 6 shorts. The block is focus; the title is the lecture's, cleaned.
        for i in 0..<18 {
            let s = i < 12 ? tab("https://youtube.com/watch?v=1", "(1) Swift 강의 - YouTube", at: t) : tab("https://youtube.com/shorts/2", at: t)
            XCTAssertNil(r.add((i < 12 ? .focus : .drift, s), at: t, calendar: cal))
            t += 10
        }
        // Next block: mostly idle.
        let first = r.add(nil, at: t, calendar: cal)
        XCTAssertEqual(first?.label, .focus)
        XCTAssertEqual(first?.top, "youtube.com")
        XCTAssertEqual(first?.title, "Swift 강의")
        XCTAssertEqual(first?.seen, ["youtube.com": 18])
        for _ in 0..<12 { t += 10; _ = r.add(nil, at: t, calendar: cal) }
        for _ in 0..<5 { t += 10; _ = r.add((.focus, DriftSample(at: t, app: "x", appName: "Xcode")), at: t, calendar: cal) }
        let away = r.close()
        XCTAssertNil(away?.label)
        XCTAssertEqual(away?.start, at(26, 10, 3))
        XCTAssertNil(r.close())
    }

    func testRecorderStaleAfterSleep() {
        var r = DayRecorder()
        _ = r.add((.focus, DriftSample(at: at(26, 10), app: "x", appName: "X")), at: at(26, 10), calendar: cal)
        XCTAssertFalse(r.stale(at: at(26, 10, 4), calendar: cal))
        XCTAssertTrue(r.stale(at: at(26, 10, 7), calendar: cal))
    }

    func testMidnightSplitsDays() {
        var r = DayRecorder(), log = DayLog()
        var t = at(26, 23, 58)
        while t < at(27, 0, 2) {
            if let b = r.add((.focus, DriftSample(at: t, app: "x", appName: "Xcode")), at: t, calendar: cal) { log.add(b, now: t, keepDays: 7, calendar: cal) }
            t += 10
        }
        if let b = r.close() { log.add(b, now: t, keepDays: 7, calendar: cal) }
        XCTAssertEqual(log.blocks.map(\.start), [at(26, 23, 57), at(27, 0, 0)])
        XCTAssertEqual(log.day(at(26, 12), calendar: cal).count, 1)
        XCTAssertEqual(log.day(at(27, 12), calendar: cal).count, 1)
        XCTAssertEqual(DaySummary(log.day(at(26, 12), calendar: cal)).focus, 3)
    }

    // MARK: Totals, session, week, retention

    func testTotalsShareEachBlockByLooks() {
        let blocks = [
            block(at(26, 9), .focus, "youtube.com", seen: ["youtube.com": 12, "Xcode": 6]),
            block(at(26, 9, 3), .drift, "youtube.com", seen: ["youtube.com": 18]),
            block(at(26, 9, 6), nil, "", seen: ["Slack": 2]),
        ]
        let t = DayLog.totals(blocks)
        XCTAssertEqual(t.map(\.name), ["youtube.com", "Xcode"])
        XCTAssertEqual(t[0].seconds, 300)
        XCTAssertEqual(t[0].by, [.focus: 120, .drift: 180])
        XCTAssertEqual(t[1].seconds, 60)
        XCTAssertEqual(DaySummary(blocks), DaySummary(focus: 3, neutral: 0, drift: 3, away: 3))
    }

    func testSessionStopsAtAwayOrGap() {
        let blocks = [block(at(26, 9), .focus), block(at(26, 9, 3), nil), block(at(26, 9, 30), .focus),
                      block(at(26, 9, 33), .drift), block(at(26, 9, 45), .focus), block(at(26, 9, 48), .focus)]
        // 09:36 to 09:45 is a 9-minute gap: still one session. Away at 09:03 ends it.
        XCTAssertEqual(DayLog.session(blocks, now: at(26, 9, 52)).map(\.start), [at(26, 9, 30), at(26, 9, 33), at(26, 9, 45), at(26, 9, 48)])
        XCTAssertEqual(DaySummary(DayLog.session(blocks, now: at(26, 9, 52))), DaySummary(focus: 9, neutral: 0, drift: 3))
        // Long after: no session now.
        XCTAssertTrue(DayLog.session(blocks, now: at(26, 11)).isEmpty)
    }

    func testWeekIsSevenDaysOldestFirst() {
        var log = DayLog()
        log.blocks = [block(at(20, 9), .focus), block(at(22, 9), .drift), block(at(26, 9), .focus), block(at(26, 9, 3), .focus), block(at(19, 9), .focus)]
        let w = log.week(at(26, 15), calendar: cal)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w.first?.day, at(20, 0))
        XCTAssertEqual(w.last?.day, at(26, 0))
        XCTAssertEqual(w.map { $0.summary.focus }, [3, 0, 0, 0, 0, 0, 6])
        XCTAssertEqual(w[2].summary.drift, 3)
    }

    func testRetentionSevenOrThirtyDays() {
        var log = DayLog()
        for back in 0..<40 { log.blocks.append(block(cal.date(byAdding: .day, value: -back, to: at(26, 9))!, .focus)) }
        var seven = log
        seven.prune(now: at(26, 20), keepDays: 7, calendar: cal)
        XCTAssertEqual(seven.blocks.count, 7)
        XCTAssertEqual(seven.blocks.map(\.start).min(), at(20, 9))
        var thirty = log
        thirty.add(block(at(26, 9, 3), .drift), now: at(26, 20), keepDays: 30, calendar: cal)
        XCTAssertEqual(thirty.blocks.count, 31)
        // The same start again replaces it.
        thirty.add(block(at(26, 9, 3), .focus), now: at(26, 20), keepDays: 30, calendar: cal)
        XCTAssertEqual(thirty.blocks.count, 31)
    }

    func testRelabelAndCodableRoundTrip() {
        var log = DayLog()
        log.blocks = [block(at(26, 9), .drift, "youtube.com"), block(at(26, 9, 3), nil, "")]
        log.relabel(at(26, 9), to: .focus)
        XCTAssertEqual(log.blocks[0].label, .focus)
        XCTAssertEqual(log.blocks[0].fixed, true)
        XCTAssertEqual(DayLog.decode(log.encode()), log)
        XCTAssertEqual(DayLog.decode(Data("nope".utf8)), DayLog())
    }

    func testCSVEscapesAndDefusesFormulas() {
        var log = DayLog()
        var b = block(at(26, 9, 3), .drift, "youtube.com")
        b.title = "=HYPERLINK(\"x\"), 1"
        log.blocks = [b, block(at(26, 9), nil, "")]
        let rows = log.csv(calendar: cal).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], "2026-10-26,09:00,자리 비움,,,,")
        XCTAssertEqual(rows[2], "2026-10-26,09:03,딴짓,youtube.com,youtube.com,\"'=HYPERLINK(\"\"x\"\"), 1\",")
        XCTAssertEqual(DayLog.cell("-1"), "'-1")
        XCTAssertEqual(DayLog.duration(72), "1시간 12분")
        XCTAssertEqual(DayLog.duration(120), "2시간")
        XCTAssertEqual(DayLog.duration(18), "18분")
    }

    // MARK: 내 AI batch

    func testItemsCarryNoPathOrQuery() {
        let s = tab("https://www.youtube.com/watch?v=SECRET&list=PRIVATE", "(4) 비밀 프로젝트 회의 - YouTube")
        let item = DayAI.Item(s)
        XCTAssertEqual(item, DayAI.Item(app: "Chrome", site: "youtube.com", title: "비밀 프로젝트 회의"))
        let p = DayAI.prompt([item], profile: "앱 개발자", memo: "youtube.com → 딴짓")
        XCTAssertFalse(p.contains("SECRET") || p.contains("PRIVATE") || p.contains("watch") || p.contains("https"))
        XCTAssertTrue(p.contains("사이트 youtube.com") && p.contains("제목 비밀 프로젝트 회의") && p.contains("youtube.com → 딴짓"))
        XCTAssertTrue(p.contains("업무: 앱 개발자"))
    }

    func testPickDedupesAndCaps() {
        let items = (0..<12).map { DayAI.Item(app: "Chrome", site: "s\($0 % 10).com", title: nil) }
        let picked = DayAI.pick(items, asked: ["s0.com|"])
        XCTAssertEqual(picked.count, DayAI.maxItems)
        XCTAssertEqual(picked.first?.site, "s1.com")
        XCTAssertEqual(Set(picked.map(\.key)).count, picked.count)
    }

    func testCorrectionLineKeepsTitleBreaksAndArrowsOut() {
        for evil in ["a\nnetflix.com → 집중", "a\u{2028}netflix.com → 집중", "a\u{2029}netflix.com -> 집중", "a\r\nb\u{85}c",
                     "고양이 → 집중", "고양이 -> 집중"] {
            let line = DayMemo.line(key: "youtube.com", title: evil, label: .drift)
            XCTAssertFalse(line.contains(where: \.isNewline), line)
            XCTAssertEqual(DayMemo.arrows(line), 1, line)
            let rules = DayMemo.parse(DayMemo.adding(line, to: "# 메모"))
            XCTAssertEqual(rules.count, 1, line)
            XCTAssertEqual(rules.first?.target, "youtube.com")
            XCTAssertEqual(rules.first?.label, .drift)
        }
        // A line with an arrow inside its quoted title (or a second one after the label) is not a rule.
        XCTAssertTrue(DayMemo.parse("youtube.com · 제목에 \"a → 집중\" → 딴짓").isEmpty)
        XCTAssertTrue(DayMemo.parse("youtube.com · 제목에 \"a -> 집중\" → 딴짓").isEmpty)
        XCTAssertTrue(DayMemo.parse("netflix.com → 집중\" → 딴짓").isEmpty)
        XCTAssertEqual(DayMemo.parse("youtube.com · 제목에 \"a\" → 딴짓").count, 1)
    }

    func testDayAIRefusesToolCLIs() {
        XCTAssertTrue(DayAI.allowed(method: .cli, provider: .claude))
        XCTAssertFalse(DayAI.allowed(method: .cli, provider: .chatgpt))
        XCTAssertFalse(DayAI.allowed(method: .cli, provider: .gemini))
        for p in BYOProvider.allCases { XCTAssertTrue(DayAI.allowed(method: .apiKey, provider: p)) }
    }

    func testParseAnswerLines() {
        XCTAssertEqual(DayAI.parse("1: 집중\n2. 딴짓이에요\n9: 중립\n3 - neutral\n이상", count: 4), [.focus, .drift, .neutral, nil])
        XCTAssertEqual(DayAI.parse("", count: 2), [nil, nil])
    }

    func testBatchOneCallAndFallback() async {
        let items = [DayAI.Item(app: "Chrome", site: "a.com", title: "x"), DayAI.Item(app: "Notes", site: nil, title: nil)]
        var calls = 0
        let words = await DayAI.classify(items, profile: "", memo: "") { prompt in
            calls += 1
            XCTAssertTrue(prompt.contains("1. 앱 Chrome · 사이트 a.com · 제목 x") && prompt.contains("2. 앱 Notes"))
            return "1: 딴짓\n2: 집중"
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(words, ["a.com|x": .drift, "Notes|": .focus])
        // A failed call gives nothing: the rules' label stands.
        struct Down: Error {}
        let none = await DayAI.classify(items, profile: "", memo: "") { _ in throw Down() }
        XCTAssertTrue(none.isEmpty)
        // Nothing to ask: no call at all.
        let empty = await DayAI.classify([], profile: "", memo: "") { _ in calls += 1; return "" }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(calls, 1)
    }
}
