import XCTest
@testable import DogMonitor

final class AssistantTests: XCTestCase {
    private let jelly = Persona(name: "젤리", style: .friendly)
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: 반말 어미 교정

    func testBanmalFixesPoliteEndings() {
        XCTAssertEqual(Banmal.fix("네, 괜찮아요. 메모리는 넉넉해요."), "응, 괜찮아. 메모리는 넉넉해.")
        XCTAssertEqual(Banmal.fix("CPU가 여유 있습니다. 재시동해 보세요!"), "CPU가 여유 있어. 재시동해 봐!")
        XCTAssertEqual(Banmal.fix("이건 캐시예요. 지워도 되는 파일이에요."), "이건 캐시야. 지워도 되는 파일이야.")
        XCTAssertEqual(Banmal.fix("제가 볼게요. 확인하겠습니다."), "내가 볼게. 확인할게.")
        XCTAssertEqual(Banmal.fix("다시 보겠습니다. 그렇죠?"), "다시 볼게. 그렇지?")
        XCTAssertEqual(Banmal.fix("찾겠습니다"), "찾을게")
        XCTAssertEqual(Banmal.fix("잠깐 쉬세요. 충전기를 꽂아 주세요."), "잠깐 쉬어. 충전기를 꽂아 줘.")
        XCTAssertEqual(Banmal.fix("뭐 하고 계세요? 할까요?"), "뭐 하고 있어? 할까?")
        // 아/어 follows the stem's vowel.
        XCTAssertEqual(Banmal.fix("메모리는 괜찮습니다. CPU 사용량이 높습니다."), "메모리는 괜찮아. CPU 사용량이 높아.")
        XCTAssertEqual(Banmal.fix("파일이 많습니다. 공간이 작습니까? 밥을 먹습니다."), "파일이 많아. 공간이 작아? 밥을 먹어.")
    }

    func testBanmalLeavesCasualTextAlone() {
        for s in ["응, 괜찮아. 배터리 54% 남았어!", "네 맥은 괜찮아.", "문제가 없어.", "저 앱이 바빠.", "Safari가 제일 바빠", "요가 하자"] {
            XCTAssertEqual(Banmal.fix(s), s)
        }
    }

    func testJosa() {
        XCTAssertEqual(Banmal.josa("젤리", "이", "가"), "젤리가")
        XCTAssertEqual(Banmal.josa("핑크곰", "이", "가"), "핑크곰이")
        XCTAssertEqual(Banmal.josa("Momo", "과", "와"), "Momo와")
    }

    // MARK: 프롬프트 조립

    func testWindowKeepsSixTurnsAndFoldsTheRest() {
        let turns = (1...9).map { ChatTurn(user: "질문\($0)", reply: "답\($0)") }
        let (summary, recent) = AssistantPrompt.window(turns)
        XCTAssertEqual(recent.map(\.user), (4...9).map { "질문\($0)" })
        XCTAssertEqual(summary, "질문1 / 질문2 / 질문3")
        // Short histories are untouched.
        XCTAssertEqual(AssistantPrompt.window(Array(turns.prefix(6))).recent.count, 6)
        // The summary keeps the last five questions only, carried over between calls.
        let more = AssistantPrompt.fold((10...14).map { ChatTurn(user: "질문\($0)", reply: "") }, into: summary)
        XCTAssertEqual(more, "질문10 / 질문11 / 질문12 / 질문13 / 질문14")
    }

    func testComposeHasFactsHintsAndQuestionInOrder() {
        var r = ChatRequest(persona: jelly, summary: "질문1", history: [ChatTurn(user: "안녕", reply: "안녕!")],
                            facts: ["CPU: 25.0%"], personal: ["15:00 회의"], question: "왜 느려?")
        r.hints = ["CPU 여유 있음"]
        let p = r.prompt
        let order = ["[앞에서 사용자가 물어본 것]", "사용자: 안녕\n젤리: 안녕!", "[상태 해석]\nCPU 여유 있어", "[지금 맥 상태]\nCPU: 25.0%",
                     "[답 예시]", "[사용자 질문]\n왜 느려?"]
        var at = p.startIndex
        for part in order {
            guard let r = p.range(of: part, range: at..<p.endIndex) else { return XCTFail("\(part) missing or out of order in\n\(p)") }
            at = r.upperBound
        }
        XCTAssertFalse(p.contains("15:00 회의"), "a Mac question gets no calendar")
        XCTAssertFalse(ChatRequest(persona: jelly, summary: "", history: [], facts: [], personal: [], question: "x").prompt.contains("[지금 맥 상태]"))
    }

    func testInstructionsCarryStyleAndNoInventedNumbers() {
        let calm = Persona(name: "닌자", style: .calm).instructions
        XCTAssertTrue(calm.contains("'닌자'"))
        XCTAssertTrue(calm.contains(PersonaStyle.calm.rule))
        XCTAssertTrue(calm.contains("지어내지 마"))
        XCTAssertTrue(calm.contains(PersonaStyle.calm.example))
    }

    func testCleanStripsNameQuotesAndLimitsLength() {
        XCTAssertEqual(AssistantPrompt.clean("젤리: \"네, 좋아요.\"", persona: jelly), "응, 좋아.")
        XCTAssertEqual(AssistantPrompt.clean("하나. 둘. 셋. 넷.", persona: jelly), "하나. 둘. 셋.")
        let polite = Persona(name: "젤리", style: .polite)
        XCTAssertEqual(AssistantPrompt.clean("괜찮아요.", persona: polite), "괜찮아요.")
        let long = String((0..<300).map { Character(UnicodeScalar(0xAC00 + $0 * 7)!) })
        XCTAssertEqual(AssistantPrompt.clean(long, persona: jelly).count, AssistantPrompt.maxAnswer)
        XCTAssertTrue(AssistantPrompt.clean(long, persona: jelly).hasSuffix("…"))
    }

    // MARK: 페르소나·엔진

    func testPersonaPresets() {
        XCTAssertEqual(Persona.preset(character: .dog, id: nil), .friendly)
        XCTAssertEqual(Persona.preset(character: .cat, id: "cat-x"), .proud)
        XCTAssertEqual(Persona.preset(character: .original, id: "original-tan-cat"), .proud)
        XCTAssertEqual(Persona.preset(character: .original, id: "original-ninja"), .friendly)   // removed character
        XCTAssertEqual(Persona.preset(character: .original, id: "unknown"), .friendly)
        XCTAssertEqual(Persona.resolve(name: "젤리", character: .dog, id: nil, chosen: .polite).style, .polite)
    }

    func testEnginePick() {
        XCTAssertEqual(AssistantEngines.pick(onDevice: true), .onDevice)
        XCTAssertEqual(AssistantEngines.pick(onDevice: false), .template)
    }

    func testTemplateAnswerUsesOnlyGivenNumbers() {
        let facts = ["CPU: 25.0%", "메모리: 61.0% (16 GB / 24 GB, 압력 보통)", "저장 공간: 289.7 GB 남음 (전체 500.0 GB)", "배터리: 15% (충전 중)", "바쁜 앱: Xcode, Safari"]
        func ask(_ q: String, _ style: PersonaStyle = .friendly) -> String {
            TemplateEngine.answer(ChatRequest(persona: Persona(name: "젤리", style: style), summary: "", history: [], facts: facts, personal: [], question: q))
        }
        XCTAssertEqual(ask("배터리 괜찮아?"), "배터리는 15%고 충전 중이야.")
        XCTAssertEqual(ask("저장 공간 얼마나 남았어?", .polite), "저장 공간은 전체 500.0 GB 중 289.7 GB 남아서 넉넉해요.")
        XCTAssertEqual(ask("왜 느려?"), "지금 숫자로는 느릴 뚜렷한 이유가 없어. CPU는 25.0%, 메모리는 61.0%를 쓰는 중이라 둘 다 여유 있어.")
        XCTAssertEqual(ask("오늘 일정?"), "캘린더 연동이 꺼져 있어서 일정을 볼 수 없어. 비서 설정에서 켜 줘.")
    }

    func testActionSuggestions() {
        XCTAssertEqual(AssistantAction.suggest(question: "왜 이렇게 느려", cpu: 0.2, diskFreeFraction: 0.5), [.activityMonitor])
        XCTAssertEqual(AssistantAction.suggest(question: "안녕", cpu: 0.2, diskFreeFraction: 0.05), [.cleaner])
        XCTAssertEqual(AssistantAction.suggest(question: "바이러스 있어?", cpu: 0.9, diskFreeFraction: 0.5), [.activityMonitor, .security])
        XCTAssertEqual(AssistantAction.suggest(question: "안녕", cpu: 0.1, diskFreeFraction: nil), [])
    }

    func testFactChips() {
        XCTAssertEqual(FactChips.chips(["CPU: 25.0%", "메모리: 61.0% (16 GB / 24 GB, 압력 보통)"]), ["CPU 25.0%", "메모리 61.0%"])
    }

    // MARK: 숫자

    func testBusyAppsGroupHelpersUnderTheirApp() {
        let names = SystemSnapshotText.topNames([
            ("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", 0.2),
            ("WebContent", "/Applications/Safari.app/Contents/XPCServices/W.xpc/W", 0.3),
            ("node", "/opt/homebrew/bin/node", 0.4),
            ("idle", "/usr/bin/idle", 0.05),
            ("swift-frontend", nil, 0.15),
            ("python3", nil, 0.12),
        ])
        XCTAssertEqual(names, ["Safari", "node", "swift-frontend"])
    }

    private func snapshot(cpu: Double, pressure: MemoryPressureLevel = .normal, free: UInt64 = 300, battery: Int? = nil,
                          thermal: ProcessInfo.ThermalState = .nominal, uptime: TimeInterval = 3600) -> SystemSnapshot {
        SystemSnapshot(timestamp: t0, cpu: CPUStats(user: cpu, system: 0, idle: 1 - cpu, perCore: []),
                       memory: MemoryStats(total: 16 << 30, app: 8 << 30, wired: 1 << 30, compressed: 0, cachedFiles: 0, free: 0, swapUsed: 0,
                                           pressure: 0.3, pressureLevel: pressure),
                       disk: DiskStats(volumeName: "Macintosh HD", total: 1000, available: free),
                       battery: battery.map { BatteryStats(percent: $0, isCharging: false, isPluggedIn: false, isCharged: false,
                                                           minutesRemaining: nil, cycleCount: nil, healthPercent: nil) },
                       network: NetworkStats(interfaces: [], uploadBytesPerSec: 0, downloadBytesPerSec: 0),
                       uptime: uptime, thermalState: thermal)
    }

    func testVerdictsPutSlowReasonsFirst() {
        XCTAssertEqual(SystemSnapshotText.verdicts(snapshot(cpu: 0.1)).first, "지금 숫자로는 느릴 뚜렷한 이유 없음")
        let busy = SystemSnapshotText.verdicts(snapshot(cpu: 0.9, pressure: .critical, free: 50, battery: 12, thermal: .serious, uptime: 9 * 86_400))
        XCTAssertEqual(Array(busy.prefix(5)), ["CPU가 많이 바쁨, 느린 이유일 수 있음", "메모리가 아주 부족함, 느린 가장 큰 이유",
                                               "저장 공간이 거의 참, 정리 필요", "맥이 뜨거워서 스스로 속도를 낮추는 중", "배터리 부족, 충전 필요"])
        XCTAssertTrue(busy.contains("오래 켜 둠, 재시동하면 나아질 수 있음"))
        XCTAssertFalse(busy.contains("지금 숫자로는 느릴 뚜렷한 이유 없음"))
    }

    // MARK: 먼저 말 걸기

    func testNudgeGateCooldown() {
        var g = NudgeGate()
        XCTAssertTrue(g.allow(.often, now: t0))
        XCTAssertFalse(g.allow(.often, now: t0.addingTimeInterval(19 * 60)))
        XCTAssertTrue(g.allow(.often, now: t0.addingTimeInterval(20 * 60)))
        XCTAssertFalse(g.allow(.rarely, now: t0.addingTimeInterval(60 * 60)))
        XCTAssertFalse(g.allow(.off, now: t0.addingTimeInterval(10 * 3600)))
    }

    func testHeldBackLinesDoNotUseTheCooldown() {
        var g = NudgeGate()
        XCTAssertEqual(g.check(.rarely, muted: true, now: t0), .wait, "muted: wait, nothing spent")
        XCTAssertNil(g.last)
        XCTAssertEqual(g.check(.rarely, muted: false, now: t0), .say)
        XCTAssertEqual(g.check(.rarely, muted: false, now: t0.addingTimeInterval(60)), .wait)
        XCTAssertEqual(g.check(.rarely, muted: false, urgent: true, now: t0.addingTimeInterval(60)), .say, "battery and heat skip the spacing")
        XCTAssertEqual(g.check(.off, muted: false, urgent: true, now: t0), .never)
        XCTAssertTrue(Nudge.batteryLow(9).isUrgent)
        XCTAssertFalse(Nudge.taskDone(minutes: 9).isUrgent)
        // A held calendar line counts down, and is dropped once the meeting starts.
        XCTAssertEqual(Nudge.calendar(title: "회의", minutes: 10).aged(by: 4 * 60), .calendar(title: "회의", minutes: 6))
        XCTAssertNil(Nudge.calendar(title: "회의", minutes: 10).aged(by: 10 * 60))
        XCTAssertEqual(Nudge.hot.aged(by: 600), .hot)
    }

    func testNudgesStartOffForAnUpdateAndRarelyForANewInstall() {
        let suite = "assistant-first-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AssistantSettings(defaults: d).nudges, .rarely, "new install")
        d.set(true, forKey: "claudeTokenCleared")   // a later launch: the choice stays
        XCTAssertEqual(AssistantSettings(defaults: d).nudges, .rarely)
        let upd = "assistant-first-\(UUID().uuidString)"
        let u = UserDefaults(suiteName: upd)!
        defer { u.removePersistentDomain(forName: upd) }
        u.set(true, forKey: "claudeTokenCleared")   // 2.0 ran here
        XCTAssertEqual(AssistantSettings(defaults: u).nudges, .off, "update from 2.0")
        XCTAssertFalse(AssistantSettings(defaults: u).urlSay, "say links start off")
    }

    func testSayLinksAreSpacedOut() {
        var l = URLSayLimiter()
        XCTAssertTrue(l.allow(now: t0))
        XCTAssertFalse(l.allow(now: t0.addingTimeInterval(29)))
        var n = 1
        for i in 1..<40 where l.allow(now: t0.addingTimeInterval(Double(i) * 31)) { n += 1 }
        XCTAssertEqual(n, URLSayLimiter.perHour, "at most 10 an hour")
        XCTAssertTrue(l.allow(now: t0.addingTimeInterval(3600 + 31 * 40)))
        XCTAssertTrue(AssistantURL.prefix.hasPrefix("단축어"))
        XCTAssertTrue(CalendarLink.shared.todayLines(enabled: false).isEmpty, "the 캘린더 switch off: nothing read")
        #if !MAS
        XCTAssertTrue(MailLink.isDenial("execution error: Not authorized to send Apple events to Mail. (-1743)"))
        XCTAssertFalse(MailLink.isDenial(""))
        #endif
    }

    private func battery(_ p: Int, plugged: Bool = false) -> BatteryStats {
        BatteryStats(percent: p, isCharging: plugged, isPluggedIn: plugged, isCharged: false, minutesRemaining: nil, cycleCount: nil, healthPercent: nil)
    }

    func testDetectorBatteryOncePerDrop() {
        var d = NudgeDetector()
        XCTAssertEqual(d.feed(battery: battery(11), load: 0, thermal: .nominal, now: t0), [])
        XCTAssertEqual(d.feed(battery: battery(10), load: 0, thermal: .nominal, now: t0), [.batteryLow(10)])
        XCTAssertEqual(d.feed(battery: battery(9), load: 0, thermal: .nominal, now: t0), [])
        _ = d.feed(battery: battery(9, plugged: true), load: 0, thermal: .nominal, now: t0)
        XCTAssertEqual(d.feed(battery: battery(8), load: 0, thermal: .nominal, now: t0), [.batteryLow(8)])
        XCTAssertEqual(d.feed(battery: nil, load: 0, thermal: .nominal, now: t0), [])   // desktop
    }

    func testDetectorHeatAndFinishedTask() {
        var d = NudgeDetector()
        XCTAssertEqual(d.feed(battery: nil, load: 0, thermal: .serious, now: t0), [.hot])
        XCTAssertEqual(d.feed(battery: nil, load: 0, thermal: .critical, now: t0), [])
        var found: [Nudge] = []
        for s in stride(from: 0, through: 400, by: 10) { found += d.feed(battery: nil, load: 0.9, thermal: .nominal, now: t0.addingTimeInterval(Double(s))) }
        for s in stride(from: 410, through: 450, by: 10) { found += d.feed(battery: nil, load: 0.1, thermal: .nominal, now: t0.addingTimeInterval(Double(s))) }
        XCTAssertEqual(found, [.taskDone(minutes: 6)])
        // A short burst says nothing.
        var short = NudgeDetector()
        var none: [Nudge] = []
        for s in stride(from: 0, through: 60, by: 10) { none += short.feed(battery: nil, load: 0.9, thermal: .nominal, now: t0.addingTimeInterval(Double(s))) }
        for s in stride(from: 70, through: 200, by: 10) { none += short.feed(battery: nil, load: 0.1, thermal: .nominal, now: t0.addingTimeInterval(Double(s))) }
        XCTAssertEqual(none, [])
    }

    func testNudgeTemplatesAreShortAndPoliteVariant() {
        let all: [Nudge] = [.batteryLow(9), .hot, .taskDone(minutes: 12), .runaway("node"), .calendar(title: "회의", minutes: 10),
                            .reminder("약 먹기"), .mail(count: 2, senders: ["김철수"])]
        for n in all {
            XCTAssertLessThanOrEqual(n.template(polite: false).count, SpeechBubbleCenter.maxLength)
            XCTAssertTrue(n.template(polite: true).contains("요"), n.template(polite: true))
            XCTAssertFalse(n.template(polite: false).contains("\u{2014}"))
        }
        XCTAssertEqual(Nudge.batteryLow(9).phoneEvent, .batteryLow)
        XCTAssertNil(Nudge.mail(count: 1, senders: []).phoneEvent)
    }

    func testBubbleGateMuteAndRepeats() {
        var g = BubbleGate()
        XCTAssertFalse(g.allow("배고파", source: .pet, muted: true, now: t0))
        XCTAssertTrue(g.allow("배고파", source: .pet, muted: false, now: t0))
        XCTAssertFalse(g.allow("배고파", source: .pet, muted: false, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(g.allow("배고파", source: .assistant, muted: false, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(g.allow("배고파", source: .pet, muted: false, now: t0.addingTimeInterval(BubbleGate.repeatWindow)))
        // News (a second text from the same sender) repeats, but never while muted.
        XCTAssertTrue(g.allow("배고파", source: .pet, muted: false, now: t0.addingTimeInterval(BubbleGate.repeatWindow + 1), repeats: true))
        XCTAssertFalse(g.allow("배고파", source: .pet, muted: true, now: t0.addingTimeInterval(BubbleGate.repeatWindow + 2), repeats: true))
    }

    func testBubbleDeadlineHoverAndLateTimer() {
        let line = SpeechLine(text: "회의 10분 전이에요", source: .system, date: t0, seconds: 10)
        var d = BubbleDeadline(line)
        XCTAssertEqual(d.at, t0 + 10)
        XCTAssertFalse(d.due(now: t0 + 9))
        XCTAssertTrue(d.due(now: t0 + 60))   // a timer App Nap fired late: still due, it hides at once
        d.hover(true, now: t0 + 8)
        XCTAssertFalse(d.due(now: t0 + 10))   // pointer on it: pushed on 3 s
        XCTAssertEqual(d.at, t0 + 10 + BubbleDeadline.hoverGrace)
        d.hover(false, now: t0 + 12)
        XCTAssertFalse(d.due(now: t0 + 14))
        XCTAssertTrue(d.due(now: t0 + 15))
        XCTAssertFalse(SpeechLine(text: "배고파요", source: .pet, date: t0).closable)
    }

    // MARK: 긴 줄표 정리

    func testUndashLineHeadAndMidSentence() {
        let d = "\u{2014}"
        XCTAssertEqual(AssistantPrompt.undash("\(d) 물 마시기\n\(d)\(d) 스트레칭"), "- 물 마시기\n- 스트레칭")
        XCTAssertEqual(AssistantPrompt.undash("괜찮아요 \(d) 메모리는 넉넉해요"), "괜찮아요, 메모리는 넉넉해요")
        XCTAssertEqual(AssistantPrompt.undash("좋아요.\(d)그런데 쉬세요"), "좋아요. 그런데 쉬세요")
        XCTAssertEqual(AssistantPrompt.undash("끝이에요 \(d)"), "끝이에요")
    }

    func testUndashKeepsCodeURLsAndRanges() {
        let d = "\u{2014}"
        for kept in ["`a\(d)b` 를 쓰세요", "https://example.com/a\(d)b 참고"] {
            XCTAssertEqual(AssistantPrompt.undash(kept), kept)
        }
        XCTAssertEqual(AssistantPrompt.undash("3\(d)5분 걸려요"), "3~5분 걸려요")
        XCTAssertEqual(AssistantPrompt.undash("3 \(d) 5분 걸려요"), "3~5분 걸려요")
        XCTAssertFalse(AssistantPrompt.clean("메모리 넉넉해 \(d) 걱정 마.", persona: jelly).contains(d))
    }

    func testSettingsDefaultsAreOff() {
        let d = UserDefaults(suiteName: "test.assistant.settings")!
        d.removePersistentDomain(forName: "test.assistant.settings")
        defer { d.removePersistentDomain(forName: "test.assistant.settings") }
        let s = AssistantSettings(defaults: d)
        XCTAssertFalse(s.voice || s.calendar || s.reminders || s.mail || s.phone)
        XCTAssertEqual(s.nudges, .rarely)
        XCTAssertTrue(s.ntfyTopic.hasPrefix("charamonitor-"))
        XCTAssertEqual(AssistantSettings(defaults: d).ntfyTopic, s.ntfyTopic)   // made once, then kept
        s.mutedUntil = t0.addingTimeInterval(60)
        XCTAssertTrue(s.isMuted(now: t0))
        XCTAssertFalse(s.isMuted(now: t0.addingTimeInterval(61)))
    }

    // MARK: 연동

    func testSayURL() {
        XCTAssertEqual(AssistantURL.sayText(URL(string: "charamonitor://say?text=%EC%95%88%EB%85%95")!), "안녕")
        XCTAssertEqual(AssistantURL.sayText(URL(string: "CHARAMONITOR://SAY?text=hi")!), "hi")
        XCTAssertNil(AssistantURL.sayText(URL(string: "charamonitor://open?text=hi")!))
        XCTAssertNil(AssistantURL.sayText(URL(string: "charamonitor://say?text=%20")!))
        XCTAssertNil(AssistantURL.sayText(URL(string: "https://say?text=hi")!))
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(AssistantURL.sayText(URL(string: "charamonitor://say?text=\(long)")!)?.count, SpeechBubbleCenter.maxLength)
    }

    func testMailParseKeepsNamesOnly() {
        XCTAssertEqual(MailLink.parse("2\n김철수 <kim@example.com>\nnews@shop.com")?.count, 2)
        XCTAssertEqual(MailLink.parse("2\n\"김철수\" <kim@example.com>\nnews@shop.com")?.senders, ["김철수", "news"])
        XCTAssertEqual(MailLink.parse("0")?.senders, [])
        XCTAssertNil(MailLink.parse("execution error"))
    }

    func testPhoneRequests() throws {
        let n = try XCTUnwrap(Phone.ntfyRequest(topic: "charamonitor-abc", title: "캐릭모니터", body: "배터리 9%"))
        XCTAssertEqual(n.url?.absoluteString, "https://ntfy.sh")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: n.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["topic"] as? String, "charamonitor-abc")
        XCTAssertEqual(json["message"] as? String, "배터리 9%")
        let p = try XCTUnwrap(Phone.pushoverRequest(user: "u1", token: "t+1", title: "a b", body: "c&d"))
        let body = String(decoding: p.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("token=t%2B1"), body)
        XCTAssertTrue(body.contains("message=c%26d"), body)
        XCTAssertNil(Phone.pushoverRequest(user: "", token: "t", title: "", body: ""))
        let topic = Phone.newTopic()
        XCTAssertEqual(topic.count, "charamonitor-".count + 16)
        XCTAssertNotEqual(topic, Phone.newTopic())
    }
}
