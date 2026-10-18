import XCTest
@testable import DogMonitor

/// Measured 2026-10-05 with Claude connected: "돌로미티는 몇월에가는게좋아?" was answered "오늘은 10월 5일 월요일이야."
/// because any 몇월 / 몇 시 / 날씨 / 주식 word routed to the fixed live-data answers.
final class AssistantRoutingPrecisionTests: XCTestCase {
    func testTopicQuestionsAreNotLiveData() {
        for q in ["돌로미티는 몇월에가는게좋아?", "몇 시에 출발해야 돼?", "주식 공부 어떻게 해?", "날씨 좋은 여행지 추천해줘",
                  "크리스마스 무슨 요일이야?", "뉴스 기사 요약하는 법", "환율이 뭐야?", "일본은 몇 월에 벚꽃 펴?"] {
            XCTAssertNil(AssistantIntent.realtimeKind(q), q)
            XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), .general, q)
        }
    }

    func testLiveValuesStillAnsweredFromTheClockOrSaidUnknown() {
        let cases: [(String, AssistantIntent.RealtimeKind)] = [
            ("지금 몇 시야?", .time), ("몇시야", .time), ("오늘 며칠이야?", .date), ("며칠이야?", .date), ("내일 무슨 요일이야?", .date),
            ("환율 얼마야?", .money), ("비트코인 시세 알려줘", .money), ("오늘 날씨 어때?", .weather), ("내일 비 와?", .weather),
            ("오늘 뉴스 뭐 있어?", .news),
        ]
        for (q, kind) in cases { XCTAssertEqual(AssistantIntent.realtimeKind(q), kind, q) }
    }

    func testTomorrowIsAnsweredForTomorrow() throws {
        var r = ChatRequest(persona: Persona(name: "젤리", style: .friendly), summary: "", history: [], facts: [], personal: [],
                            question: "내일 무슨 요일이야?")
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        r.now = try XCTUnwrap(f.date(from: "2026-10-05 21:57"))   // a Monday
        let answer = try XCTUnwrap(TemplateEngine.fixed(r))
        XCTAssertTrue(answer.hasPrefix("내일은"), answer)
        XCTAssertTrue(answer.contains("6일") && answer.contains("화요일"), answer)
    }

    func testBigModelAnswersSmallTalkButNotTheClockOrTheInbox() {
        func req(_ q: String) -> ChatRequest {
            ChatRequest(persona: Persona(name: "젤리", style: .friendly), summary: "", history: [], facts: [], personal: [], question: q)
        }
        XCTAssertTrue(TemplateEngine.modelTakes(req("재밌는 얘기 해줘")))
        XCTAssertTrue(TemplateEngine.modelTakes(req("고마워")))
        XCTAssertTrue(TemplateEngine.modelTakes(req("오늘 날씨 어때?")))
        XCTAssertFalse(TemplateEngine.modelTakes(req("지금 몇 시야?")))
        XCTAssertFalse(TemplateEngine.modelTakes(req("1234 곱하기 56은?")))
        XCTAssertFalse(TemplateEngine.modelTakes(req("문자 온 거 있어?")))
        XCTAssertFalse(TemplateEngine.modelTakes(req("회의 잡아줘")))
    }

    func testBigModelGetsTheDateAndRoomToAnswer() {
        let p = Persona(name: "젤리", style: .friendly)
        XCTAssertTrue(p.instructions(strong: true).contains("다섯 문장"))
        XCTAssertTrue(p.instructions.contains("100자"))
        var r = ChatRequest(persona: p, summary: "", history: [], facts: [], personal: [], question: "이번 달 제주 가기 좋아?")
        XCTAssertFalse(r.prompt.contains("[지금]"))
        r.strong = true
        XCTAssertTrue(r.prompt.contains("[지금]"))
    }

    /// Round 1 of the Claude check (2026-10-05): six ways a good answer was lost.
    func testClaudeRoundOneFixes() {
        // Writing help that mentions a meeting is writing help; a trip's "일정" is not the calendar.
        XCTAssertEqual(AssistantIntent.route("이 문장 다듬어 줘: 내일 회의 참석 어렵습니다 죄송합니다", hasHistory: false), .general)
        XCTAssertEqual(AssistantIntent.route("며칠 일정이면 돼?", hasHistory: true, previous: "돌로미티는 몇월에가는게좋아?"), .general)
        XCTAssertEqual(AssistantIntent.route("오늘 일정 뭐야?", hasHistory: false), .schedule)
        // Advice about the battery is not the battery reading.
        XCTAssertEqual(AssistantIntent.route("맥북 배터리 오래 쓰는법 알랴줘", hasHistory: false), .general)
        XCTAssertEqual(AssistantIntent.route("배터리 얼마나 남았어?", hasHistory: false), .mac)
        // A wish about a plan is not a feeling.
        XCTAssertNil(Feeling.kind("부모님 모시고 너무 힘들지 않은 곳으로 어디가 좋을까?"))
        XCTAssertNotNil(Feeling.kind("요즘 너무 피곤해"))
        // The recommendation itself is the answer, not an echo of "추천해줘".
        XCTAssertFalse(AssistantPrompt.echoes("「리틀 포레스트」를 추천해.", "비 오는 날 볼 영화 추천해줘", more: true))
        XCTAssertTrue(AssistantPrompt.echoes("오늘은 하루 종일 일하고 피곤하다.", "오늘 너무 피곤하다", more: true))
        XCTAssertTrue(Persona(name: "젤리", style: .friendly).instructions.contains("그 언어로 답해"))
    }

    func testQuotedLineKeepsItsOwnPeriod() {
        let out = AssistantPrompt.clean("\"Sorry I'm late, I'll be there soon.\"\n\n좀 더 급하면 이렇게 말해.", persona: Persona(name: "젤리", style: .friendly))
        XCTAssertFalse(out.contains(".\"."), out)
        XCTAssertTrue(out.hasPrefix("\"Sorry I'm late, I'll be there soon.\" "), out)
    }
}
