import XCTest
@testable import DogMonitor

/// The smart-chat layer: routing, the app's own answers, and the clean-up that keeps model mistakes off screen.
/// The cases are the failures measured on this Mac's on-device model (assistant-eval baseline, 2026-10-03).
final class AssistantIntentTests: XCTestCase {
    private let jelly = Persona(name: "젤리", style: .friendly)
    private let polite = Persona(name: "젤리", style: .polite)
    private let facts = ["CPU: 3.0%", "메모리: 67.3% (16.2 GB / 24.0 GB, 압력 보통)", "저장 공간: 1.72 TB 남음 (전체 2.00 TB)", "배터리: 91%",
                         "발열: 보통", "네트워크: 다운로드 20.8 kB/s, 업로드 27.3 kB/s", "켜진 지: 10일 10시간"]
    private let hints = ["지금 숫자로는 느릴 뚜렷한 이유 없음", "CPU 여유 있음", "메모리 넉넉함", "저장 공간 넉넉함", "오래 켜 둠, 재시동하면 나아질 수 있음"]

    private func request(_ q: String, _ persona: Persona? = nil, history: [ChatTurn] = []) -> ChatRequest {
        var r = ChatRequest(persona: persona ?? jelly, summary: "", history: history, facts: facts, personal: [], question: q)
        r.hints = hints
        r.now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        return r
    }

    func testRoute() {
        let cases: [(String, AssistantIntent)] = [
            ("내 맥 왜 이렇게 느려?", .mac), ("저장 공간 얼마나 남았어?", .mac), ("메모리 부족해?", .mac), ("맥이 좀 뜨거운 것 같은데 괜찮아?", .mac),
            ("배터리 얼마나 남았어? 충전해야 돼?", .mac),
            ("오늘 달러 환율 얼마야?", .realtime), ("지금 몇 시야?", .realtime), ("내일 날씨 어때?", .realtime),
            ("고래는 포유류야?", .general), ("'감사합니다'를 영어로 뭐라고 해?", .general), ("오늘 너무 피곤하다", .general),
            ("프로그램 추천해 줘", .general), ("나 오늘 너무 바빠", .general), ("이 내용 정리해 줘", .general),
            ("1234 곱하기 56은 얼마야?", .calc), ("12*3+4", .calc),
            ("오늘 일정 뭐 있어?", .schedule), ("미리알림 뭐 남았어?", .schedule),
            ("내일 오후 3시에 회의 잡아줘", .action), ("메일 보내 줘", .action), ("저장 공간 정리해 줘", .action), ("불 꺼 줘", .action),
            ("새 메일 온 거 있어?", .inbox), ("문자 온 거 있어?", .inbox), ("카톡 왔어?", .inbox),
            ("메일 쓰는 법 알려 줘", .general),
            ("심심해. 재밌는 얘기 해줘", .joke), ("이거 괜찮아?", .vague), ("그거 어떻게 해?", .vague),
            // Substrings and broad words are not the Mac (렉 in 디렉터리, lag in flag, 속도 of light).
            ("디렉터리가 뭐야?", .general), ("컬렉션이 뭐야?", .general), ("What does this flag mean?", .general),
            ("빛의 속도는 얼마야?", .general), ("우주 공간은 얼마나 넓어?", .general), ("전기차 충전 얼마나 걸려?", .general),
            ("게임이 렉 걸려", .mac), ("my mac is lagging", .mac), ("맥이 충전이 안 돼", .mac),
            // Writing help and how-to about mail or notifications are the model's.
            ("거래처에 보낼 메일인데 다듬어 줘: 자료 확인 부탁드립니다", .general), ("Can you check this text for typos?", .general),
            ("알림 끄는 방법 있어?", .general), ("any new mail?", .inbox), ("안 읽은 메일 몇 통이야?", .inbox),
        ]
        for (q, want) in cases { XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), want, q) }
        // After a turn, "이거" points at something said before: the model gets the history.
        XCTAssertEqual(AssistantIntent.route("이거 괜찮아?", hasHistory: true), .general)
    }

    func testCalc() {
        XCTAssertEqual(Calc.solve("1234 곱하기 56은 얼마야?"), "1234 × 56 = 69,104")
        XCTAssertEqual(Calc.solve("2+3*4"), "2 + 3 × 4 = 14")
        XCTAssertEqual(Calc.solve("1,000 나누기 8은?"), "1000 ÷ 8 = 125")
        XCTAssertEqual(Calc.solve("10 나누기 3"), "10 ÷ 3 = 3.3333")
        XCTAssertEqual(Calc.result("7 x 6"), "42")
        for q in ["3-4시에 볼까?", "10/3 일정", "2026-10-03", "1 나누기 0은?", "고래는 포유류야?"] { XCTAssertNil(Calc.solve(q), q) }
    }

    func testMacQuestionsGetOnlyTheirNumbers() {
        let battery = request("배터리 얼마나 남았어?")
        XCTAssertEqual(battery.shownFacts, ["배터리: 91%"])
        let heat = request("맥이 좀 뜨거운 것 같은데 괜찮아?")
        XCTAssertEqual(heat.shownFacts, ["발열: 보통"])
        XCTAssertTrue(heat.shownHints.contains { $0.contains("걱정 없음") })
        // Slow: everything but the network rates; the hints come first.
        let slow = request("내 맥 왜 이렇게 느려?")
        XCTAssertFalse(slow.shownFacts.contains { $0.hasPrefix("네트워크") })
        XCTAssertTrue(slow.prompt.contains("[상태 해석]\n지금 숫자로는 느릴 뚜렷한 이유는 없어"))
        // Not about the Mac: no numbers, no chips.
        for q in ["고래는 포유류야?", "오늘 너무 피곤하다", "1234 곱하기 56은 얼마야?"] {
            XCTAssertEqual(request(q).shownFacts, [], q)
            XCTAssertFalse(request(q).prompt.contains("CPU"), q)
        }
        XCTAssertTrue(request("1234 곱하기 56은 얼마야?").prompt.contains("[계산 결과] (앱이 계산한 정확한 값)\n1234 × 56 = 69,104"))
    }

    func testFixedAnswersNeverReachTheModel() {
        XCTAssertEqual(TemplateEngine.fixed(request("내일 오후 3시에 회의 잡아줘")), "일정은 내가 직접 못 만들어. 캘린더 앱에서 추가해 줘.")
        XCTAssertEqual(TemplateEngine.fixed(request("오늘 달러 환율 얼마야?", polite)),
                       "환율이나 시세는 실시간 정보라 지금 알 수 없어요. 은행이나 증권 앱에서 확인해 주세요.")
        XCTAssertEqual(TemplateEngine.fixed(request("이거 괜찮아?")), "어떤 걸 말하는 건지 조금만 더 알려 줘.")
        // Slow: the app's own reading with its numbers (the model blamed the low CPU for it, or gave no number).
        XCTAssertEqual(TemplateEngine.fixed(request("내 맥 왜 이렇게 느려?")),
                       "지금 숫자로는 느릴 뚜렷한 이유가 없어. CPU는 3.0%, 메모리는 67.3%를 쓰는 중이라 둘 다 여유 있어. 다만 켜진 지 10일 10시간이라 재시동하면 나아질 수 있어.")
        var busy = request("맥이 버벅여", polite)
        busy.facts = ["CPU: 85.0%", "메모리: 92.0% (22.1 GB / 24.0 GB, 압력 높음)", "켜진 지: 2시간 5분", "바쁜 앱: Xcode, Safari"]
        XCTAssertEqual(TemplateEngine.fixed(busy), "CPU가 85.0%로 많이 바빠요. CPU를 많이 쓰는 앱은 Xcode, Safari 순이에요. 메모리는 24.0 GB 중 22.1 GB를 쓰고 있어서 1.9 GB(8.0%)가 남았어요. 압력이 높아서 부족해지는 중이에요. 안 쓰는 앱을 닫아 보세요.")
        XCTAssertTrue(TemplateEngine.fixed(request("지금 몇 시야?"))?.range(of: #"^지금은 (오전|오후) \d{1,2}시 \d{1,2}분이야\.$"#, options: .regularExpression) != nil)
        XCTAssertTrue(TemplateEngine.fixed(request("심심해. 재밌는 얘기 해줘"))?.hasPrefix("문제 하나 낼게. ") == true)
        // Mail and texts: honest when nothing is connected, the app's own findings when something is (InboxReportTests).
        XCTAssertEqual(TemplateEngine.fixed(request("문자 온 거 있어?")),
                       "문자 연동이 꺼져 있어서 지금은 볼 수 없어. 비서 설정에서 '문자 메시지 알려주기'를 켜 줘.")
        var mail = request("새 메일 온 거 있어?")
        mail.inbox = InboxReport.made(["10:05 메일 동료: 회의록", "문자: 권한 없음"], query: mail.inboxQuery, now: mail.now)
        XCTAssertEqual(TemplateEngine.fixed(mail), "최근 받은 메일은 이거 하나야. 동료한테서 10:05에 왔어: 회의록")
        // Calendar: off vs nothing left vs the lines with their times (measured: the model dropped every time).
        var day = request("오늘 일정 뭐 있어?")
        XCTAssertEqual(TemplateEngine.fixed(day), "캘린더 연동이 꺼져 있어서 일정을 볼 수 없어. 비서 설정에서 켜 줘.")
        day.calendarLinked = true
        XCTAssertEqual(TemplateEngine.fixed(day), "오늘 남은 일정은 없어.")
        day.personal = ["15:00 디자인 리뷰"]
        XCTAssertEqual(TemplateEngine.fixed(day), "오늘 남은 일정은 15:00 디자인 리뷰야.")
        // General questions are the model's; without one the template says so instead of reciting CPU numbers.
        XCTAssertNil(TemplateEngine.fixed(request("고래는 포유류야?")))
        XCTAssertFalse(TemplateEngine.answer(request("고래는 포유류야?")).contains("CPU"))
        XCTAssertEqual(TemplateEngine.answer(request("1234 곱하기 56은 얼마야?")), "1234 × 56 = 69,104야.")
    }

    func testCleanStripsMarkdownListsAndStageDirections() {
        let raw = "**지금은 CPU도 여유 있어.**\n\n* 메모리도 넉넉해\n*[고개를 끄덕이며]* 괜찮아 😅"
        XCTAssertEqual(AssistantPrompt.clean(raw, persona: jelly), "지금은 CPU도 여유 있어. 메모리도 넉넉해. 괜찮아.")
        // "**...**" no longer hides a sentence end: three sentences at most.
        XCTAssertEqual(AssistantPrompt.clean("**하나.** **둘.** **셋.** **넷.**", persona: jelly), "하나. 둘. 셋.")
        XCTAssertEqual(AssistantPrompt.clean("상태 해석에 따르면, 느릴 이유는 없어.", persona: jelly), "느릴 이유는 없어.")
        XCTAssertEqual(AssistantPrompt.clean("메모리 부족은 아니야. 상태 해석: 메모리 넉넉해.", persona: jelly), "메모리 부족은 아니야. 메모리 넉넉해.")
        XCTAssertEqual(AssistantPrompt.clean("사용자의 맥은 괜찮아요.", persona: polite), "맥은 괜찮아요.")
    }

    func testCleanDropsLoopsEchoesAndMadeUpNumbers() {
        XCTAssertEqual(AssistantPrompt.clean(String(repeating: "네일라? ", count: 36), persona: jelly), "")
        // Long numbers are not a loop.
        XCTAssertEqual(AssistantPrompt.clean("1조는 1,000,000,000,000이야.", persona: jelly), "1조는 1,000,000,000,000이야.")
        XCTAssertFalse(AssistantPrompt.degenerate("1024는 2진수로 10000000000이야."))
        let mem = request("메모리 부족해?")
        XCTAssertEqual(AssistantPrompt.clean("메모리 부족해? 메모리 넉넉해.", persona: jelly, for: mem), "메모리 넉넉해.")
        XCTAssertEqual(AssistantPrompt.clean("메모리 부족해?\n\n메모리 부족해?\n\n메모리 부족해?", persona: jelly, for: mem), "")
        XCTAssertEqual(AssistantPrompt.clean("메모리 넉넉해. 메모리 넉넉해.", persona: jelly, for: mem), "메모리 넉넉해.")
        XCTAssertEqual(AssistantPrompt.clean("고래는 포유류야.", persona: jelly, for: request("고래는 포유류야?")), "고래는 포유류야.")
        XCTAssertEqual(AssistantPrompt.clean("심심해? 짧은 얘기 해 줄게.", persona: jelly, for: request("심심해 뭐 하지")), "심심하구나. 짧은 얘기 해 줄게.")
        let disk = request("저장 공간 얼마나 남았어?")
        XCTAssertEqual(AssistantPrompt.clean("1.72 TB 남았어. 28.1 TB가 부족해.", persona: jelly, for: disk), "1.72 TB 남았어.")
        // A made-up number in the answer itself (an example's 512 GB): the template answers instead.
        XCTAssertEqual(AssistantPrompt.clean("512 GB 남았어. 아직 넉넉해.", persona: jelly, for: disk), "")
        XCTAssertEqual(AssistantPrompt.clean("메모리는 67%야.", persona: jelly, for: mem), "메모리는 67%야.")
        let calc = request("1234 곱하기 56은 얼마야?")
        XCTAssertEqual(AssistantPrompt.clean("69,104야.", persona: jelly, for: calc), "69,104야.")
        XCTAssertEqual(AssistantPrompt.clean("68,904야.", persona: jelly, for: calc), "")
    }

    func testBanmalLeavesQuotesAlone() {
        XCTAssertEqual(Banmal.fix("'감사합니다'는 영어로 'Thank you'예요."), "'감사합니다'는 영어로 'Thank you'야.")
        XCTAssertEqual(Banmal.fix("「고맙습니다」라고 해요. don't 같은 말도 있어요."), "「고맙습니다」라고 해. don't 같은 말도 있어.")
        XCTAssertEqual(Banmal.fix("이지은이 보내셨어."), "이지은이 보냈어.")
    }

    func testJondaetFixesBanmalForThePolitePersona() {
        XCTAssertEqual(Jondaet.fix("그런 것 같아. 69,904이야. 재시동해 봐."), "그런 것 같아요. 69,904이에요. 재시동해 보세요.")
        XCTAssertEqual(Jondaet.fix("응, 괜찮아. 내가 볼게."), "네, 괜찮아요. 제가 볼게요.")
        XCTAssertEqual(Jondaet.fix("이건 캐시야. 아니야, 할까?"), "이건 캐시예요. 아니에요, 할까요?")
        for s in ["괜찮아요.", "있습니다.", "'고마워'라고 해요.", "CPU 3%"] { XCTAssertEqual(Jondaet.fix(s), s) }
        // Nouns and particles are not endings (메시지 is not 메시죠, a list of fruit gets no 요).
        XCTAssertEqual(Jondaet.fix("사진, 메시지, 메일이 많아."), "사진, 메시지, 메일이 많아요.")
        XCTAssertEqual(Jondaet.fix("회의는 2시부터 3시까지."), "회의는 2시부터 3시까지.")
        XCTAssertEqual(Jondaet.fix("여러 가지, 예를 들면 이미지."), "여러 가지, 예를 들면 이미지.")
        XCTAssertEqual(Jondaet.fix("사과, 바나나, 포도가 있어."), "사과, 바나나, 포도가 있어요.")
        XCTAssertEqual(Jondaet.fix("그렇지."), "그렇죠.")
        XCTAssertEqual(AssistantPrompt.clean("메모리는 넉넉해. 재시동해 봐.", persona: polite), "메모리는 넉넉해요. 재시동해 보세요.")
    }

    func testHintsReadAsSpeech() {
        XCTAssertEqual(AssistantPrompt.natural("오래 켜 둠, 재시동하면 나아질 수 있음", polite: false), "오래 켜 둬서, 재시동하면 나아질 수 있어")
        XCTAssertEqual(AssistantPrompt.natural("오래 켜 둠, 재시동하면 나아질 수 있음", polite: true), "오래 켜 둬서, 재시동하면 나아질 수 있어요")
        XCTAssertEqual(AssistantPrompt.natural("맥이 뜨거워서 스스로 속도를 낮추는 중", polite: false), "맥이 뜨거워서 스스로 속도를 낮추는 중이야")
    }

    func testPromptsCarryExamplesOnlyWhereTheModelAnswers() {
        XCTAssertTrue(request("고래는 포유류야?").prompt.contains("[답 예시]"))
        XCTAssertTrue(request("메모리 부족해?", polite).prompt.contains("넉넉해요"))
        for intent in [AssistantIntent.action, .inbox, .realtime, .joke, .vague] { XCTAssertNil(AssistantPrompt.examples(intent, polite: false)) }
        XCTAssertFalse(jelly.instructions.contains("맥 왜 느려"), "the tone sample is not a Mac question")
        XCTAssertTrue(jelly.nudgeInstructions("새 메일이 2통 왔다.").contains("관계나 내용은 지어내지 마"))
    }

    /// The user's own failures (2026-10-04 screenshot 2): "알랴줘" echoed back by the model, follow-ups lost.
    func testInboxRoutingTyposAndFollowUps() {
        for q in ["나 가장 최근에 온 문자 내역 알랴줘.", "문자내용 알려줘.", "그러니깐 가장 마지막에 온 문자내용 읽어줘.", "문자 알려죠", "최근 문자 보여죠",
                  "머 왔어?", "뭐왔냐", "누가 문자 했어", "안읽은 메일 있어?", "마지막 문자", "문자 내역", "엄마한테 온 문자"] {
            XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), .inbox, q)
        }
        for q in ["메일 쓰는 법 알려줘", "알림 끄는 방법 알려줘", "문자 보내 줘", "메일 다듬어 줘: 내일 회의 자료 확인 부탁드립니다"] {
            XCTAssertNotEqual(AssistantIntent.route(q, hasHistory: false), .inbox, q)
        }
        let before = "문자 온 거 있어?"
        for q in ["그럼 메일은?", "더 보여줘", "엄마는?", "또 있어?"] {
            XCTAssertEqual(AssistantIntent.route(q, hasHistory: true, previous: before), .inbox, q)
        }
        XCTAssertEqual(AssistantIntent.route("더 보여줘", hasHistory: true, previous: "고래는 포유류야?"), .general)
        XCTAssertEqual(AssistantIntent.route("그럼 오늘 일정은?", hasHistory: true, previous: before), .schedule)
        // ChatRequest carries it on from its history.
        let follow = request("그럼 메일은?", history: [ChatTurn(user: "가장 최근 문자 알려줘", reply: "")])
        XCTAssertEqual(follow.resolvedIntent, .inbox)
        XCTAssertEqual(follow.inboxQuery.kinds, [.mail])
        XCTAssertEqual(follow.inboxQuery.limit, 1)
    }

    /// The model saying the question back as a request is no answer (measured: "응, 가장 최근에 온 문자 내역을 보여줘.").
    func testParrotedRequestIsDropped() {
        let q = "나 가장 최근에 온 문자 내역 알랴줘."
        XCTAssertTrue(AssistantPrompt.parrots("응, 가장 최근에 온 문자 내역을 보여줘.", q))
        XCTAssertEqual(AssistantPrompt.clean("응, 가장 최근에 온 문자 내역을 보여줘.", persona: jelly, for: request(q, history: [])), "")
        XCTAssertFalse(AssistantPrompt.parrots("비서 설정에서 문자 연동을 켜 줘.", "문자 온 거 있어?"))
        XCTAssertFalse(AssistantPrompt.parrots("물 한 잔 마시고 잠깐 쉬어 줘.", "오늘 너무 피곤하다"))
        XCTAssertEqual(AssistantPrompt.clean("영어로 번역해 줘. Thank you라고 해.", persona: jelly, for: request("'감사합니다'를 영어로 번역해 줘")), "Thank you라고 해.")
    }

    /// The user's own failures (2026-10-04 screenshot): texts made up, "내컴퓨터 상태" answered with small talk.
    func testUserReportedQuestions() {
        XCTAssertEqual(AssistantIntent.route("문자 내용 읽어줘.", hasHistory: false), .inbox)
        XCTAssertEqual(AssistantIntent.route("지금 내컴퓨터 상태 어때/", hasHistory: false), .mac)
        XCTAssertEqual(AssistantIntent.route("노트북 느린데 왜 그래", hasHistory: false), .mac)
        XCTAssertEqual(AssistantIntent.route("카톡 알림 뭐 왔어?", hasHistory: false), .inbox)
        XCTAssertEqual(AssistantIntent.route("알림 끄는 방법 알려줘", hasHistory: false), .general)
        XCTAssertEqual(AssistantIntent.route("메일 쓰는 법 알려줘", hasHistory: false), .general)
        let off = TemplateEngine.fixed(request("문자 내용 읽어줘."))
        XCTAssertTrue(off?.contains("볼 수 없어") == true, off ?? "nil")
        XCTAssertFalse(off?.contains(where: \.isNumber) == true, "never a made-up count")
        let status = TemplateEngine.fixed(request("지금 내컴퓨터 상태 어때"))
        XCTAssertEqual(status, "지금 전체적으로 괜찮아. CPU 3.0%, 메모리 67.3%, 남은 저장 공간 1.72 TB, 배터리 91%야. 다만 켜진 지 10일 10시간이라 재시동하면 나아질 수 있어.")
        XCTAssertTrue(TemplateEngine.fixed(request("내 맥 상태 어때?", polite))?.hasPrefix("지금 전체적으로 괜찮아요.") == true)
        // A general answer has no Mac numbers to quote, so a CPU reading in it was made up.
        XCTAssertEqual(AssistantPrompt.clean("현재 컴퓨터 상태는 CPU가 60%로 여유가 있어.", persona: jelly, for: request("고래는 포유류야?")), "")
        XCTAssertEqual(AssistantPrompt.clean("응, 고래는 포유류야. CPU는 20%야.", persona: jelly, for: request("고래는 포유류야?")), "응, 고래는 포유류야.")
    }

    /// Quality round 3 (assistant-eval round-3, 2026-10-04): the user's Mac questions and the knowledge answers.
    func testQualityRound3() {
        // "켜진 지 11일 0시간": a whole day is said as days.
        XCTAssertEqual(Fmt.uptime(11 * 86_400 + 600), "11일")
        XCTAssertEqual(Fmt.uptime(11 * 86_400 + 3_700), "11일 1시간")
        func mac(_ q: String, _ uptime: String = "11일", battery: String = "91%", persona: Persona? = nil, history: [ChatTurn] = []) -> String? {
            var r = request(q, persona, history: history)
            r.facts = r.facts.map { $0.hasPrefix("켜진 지:") ? "켜진 지: \(uptime)" : $0.hasPrefix("배터리:") ? "배터리: \(battery)" : $0 }
            return TemplateEngine.fixed(r)
        }
        // "괜찮아" and then the restart said as an aside, not a second verdict.
        for q in ["지금 내컴퓨터 상태 어때/", "내 맥 괜찮아?", "is my mac ok"] {
            XCTAssertEqual(mac(q), "지금 전체적으로 괜찮아. CPU 3.0%, 메모리 67.3%, 남은 저장 공간 1.72 TB, 배터리 91%야. 다만 켜진 지 11일이라 재시동하면 나아질 수 있어.", q)
        }
        XCTAssertEqual(mac("내 맥 상태 좀 봐줘", persona: polite),
                       "지금 전체적으로 괜찮아요. CPU 3.0%, 메모리 67.3%, 남은 저장 공간 1.72 TB, 배터리 91%예요. 다만 켜진 지 11일이라 재시동하면 나아질 수 있어요.")
        // A low battery is the verdict, said once; it is no reason for a slow Mac.
        XCTAssertEqual(mac("지금 내컴퓨터 상태 어때", battery: "19%"),
                       "배터리가 19%밖에 안 남아서 충전이 필요해. CPU 3.0%, 메모리 67.3%, 남은 저장 공간 1.72 TB야. 켜진 지 11일이라 재시동하면 나아질 수 있어.")
        XCTAssertEqual(mac("노트북 느린데 왜 그래", battery: "19%"),
                       "지금 숫자로는 느릴 뚜렷한 이유가 없어. CPU는 3.0%, 메모리는 67.3%를 쓰는 중이라 둘 다 여유 있어. 다만 켜진 지 11일이라 재시동하면 나아질 수 있어.")
        // Yes or no first.
        XCTAssertEqual(mac("컴퓨터 재부팅 해야 돼?"), "응, 한 번 재시동하는 게 좋아. 켜진 지 11일 됐어.")
        XCTAssertEqual(mac("컴퓨터 재부팅 해야 돼?", "2시간 5분"), "아직 재시동은 안 해도 돼. 켜진 지 2시간 5분 됐어.")
        XCTAssertEqual(mac("켜진 지 얼마나 됐어?"), "켜진 지 11일 됐어. 오래 켜 뒀으니 한 번 재시동하면 좋아.")
        let battery = [ChatTurn(user: "배터리 몇 프로야?", reply: "")]
        XCTAssertEqual(mac("충전해야 돼?", battery: "28%", history: battery), "응, 지금 충전해 두는 게 좋아. 배터리가 28% 남았어.")
        XCTAssertEqual(mac("충전해야 돼?", battery: "12%", history: battery), "응, 지금 충전해 줘. 배터리가 12%밖에 안 남아서 곧 꺼질 수 있어.")
        XCTAssertEqual(mac("충전해야 돼?", battery: "28% (전원 연결)", history: battery), "배터리는 28%고 전원에 연결돼 있어.")

        // Knowledge: what the retelling drops or makes up is put right from the English.
        XCTAssertEqual(Pivot.english("Q: What is the difference between a CPU and a GPU?\nDepends on: nothing\nA: A CPU is a central processing unit, and a GPU is a graphics processing unit. A CPU does general tasks one after another. A GPU does many small tasks in parallel."),
                       "A CPU does general tasks one after another. A GPU does many small tasks in parallel.")
        XCTAssertFalse(Pivot.spellsOut("A CPU is a central processing unit that performs general-purpose calculations."))
        XCTAssertEqual(Pivot.english("A: If you mean \"invented,\" he invented the Hangul alphabet. If you mean \"built,\" he built a palace."), "He invented the Hangul alphabet.")
        XCTAssertEqual(Pivot.bare("Water boils at 100 degrees Celsius at sea level."), "Water boils at 100 degrees Celsius.")
        XCTAssertEqual(Pivot.english("Q: What is the boiling point of water?\nDepends on: the pressure of the surrounding air.\nA: 100 degrees Celsius."),
                       "100 degrees Celsius at sea level.")
        XCTAssertEqual(Pivot.english("Q: Is a whale a mammal?\nKey: breathes air, nurses young\nA: Yes, a whale is a mammal."), "Yes, a whale is a mammal.")
        // Which questions get a thinking line first: a number its conditions, a definition what it does.
        XCTAssertTrue(Pivot.asksNumber("물은 몇 도에서 끓어?"))
        XCTAssertFalse(Pivot.asksNumber("고래는 포유류야?"))
        for q in ["RAM이 뭐야?", "광합성이 뭐야?", "CPU랑 GPU 차이가 뭐야?"] { XCTAssertTrue(Pivot.defines(q), q) }
        for q in ["세종대왕이 만든 거 뭐야?", "고래는 포유류야?"] { XCTAssertFalse(Pivot.defines(q), q) }
        for q in ["토마토는 과일이야?", "토마토는 과일이야 채소야?"] { XCTAssertTrue(Pivot.isA(q), q) }
        XCTAssertFalse(Pivot.isA("세종대왕이 만든 거 뭐야?"))
        XCTAssertEqual(Pivot.settle("지구에서 달까지의 거리는 384,400km야.", english: "The Moon is 384,400 kilometers from Earth on average."),
                       "지구에서 달까지의 거리는 384,400km야. 어림하면 약 38만 킬로미터야.")
        XCTAssertEqual(Pivot.settle("에베레스트는 8,849미터야.", english: "Mount Everest is 8,849 meters high."), "에베레스트는 8,849미터야.")
        XCTAssertEqual(Pivot.settle("빛의 속도는 299,792,458미터/초.", english: "Light travels at 299,792,458 meters per second."),
                       "빛의 속도는 299,792,458미터/초야. 어림하면 약 30만 킬로미터야.")
        XCTAssertTrue(Pivot.prompt(request("RAM이 뭐야?")).contains("Key:"))
        XCTAssertFalse(Pivot.prompt(request("세종대왕이 만든 거 뭐야?")).contains("Key:"))
        let boil = "Water boils at 100 degrees Celsius at sea level."
        XCTAssertTrue(Pivot.invents("물 한 모금이 끓는 데 1초가 걸려. 물은 섭씨 100도에서 끓어.", english: boil))
        XCTAssertFalse(Pivot.invents("섭씨 20도 공기 중에서 소리는 1초에 약 343미터를 이동해.", english: "In air at 20 degrees Celsius, sound travels about 343 meters per second."))
        XCTAssertEqual(Pivot.settle("물 끓는 온도는 100도.", english: boil), "1기압에서 물 끓는 온도는 섭씨 100도야.")
        XCTAssertEqual(Pivot.settle("물 한 모금이 끓는 데 1초가 걸려. 물은 섭씨 100도에서 끓어.", english: boil), "1기압에서 물은 섭씨 100도에서 끓어.")
        XCTAssertEqual(Pivot.settle("빛은 초당 약 299,792,458미터야.", english: "The speed of light is 299,792,458 meters per second in a vacuum."),
                       "진공에서 빛은 초당 299,792,458미터야. 어림하면 약 30만 킬로미터야.")
        XCTAssertEqual(AssistantPrompt.clean("빛은 초속 299,792,458미터야. 어림하면 약 30만 킬로미터야.", persona: polite, for: request("빛의 속도는 얼마야?", polite)),
                       "빛은 초속 299,792,458미터예요. 어림하면 약 30만 킬로미터예요.")
        // 해라체 in the 반말 voice.
        XCTAssertEqual(Banmal.fix("GPU는 병렬 처리에 맞게 설계되었다. 전원을 끄면 데이터가 사라진다. 기억 장치이다."),
                       "GPU는 병렬 처리에 맞게 설계되었어. 전원을 끄면 데이터가 사라져. 기억 장치야.")
        XCTAssertEqual(Banmal.fix("상어는 어류이다."), "상어는 어류야.")
        XCTAssertEqual(Jondaet.fix("상어는 어류이다. 상어는 물고기 종류이다. 그건 물질이다."), "상어는 어류예요. 상어는 물고기 종류예요. 그건 물질이에요.")
    }

    /// Quality round 1 (assistant-eval round-1, 2026-10-04): every failure kind, by its cause.
    func testQualityRound1() {
        // Routing: inbox without an arrival word, follow-ups, concept questions, an app hog, typos.
        let cases: [(String, AssistantIntent)] = [
            ("안 읽은 거 있어?", .inbox), ("메일 확인해줘", .inbox), ("who texted me", .inbox), ("나 가장 최근에 온 문자 내역 알랴줘.", .inbox),
            ("RAM이 뭐야?", .general), ("CPU랑 GPU 차이가 뭐야?", .general), ("램 얼마나 써", .mac), ("메모리얼마나남았어", .mac),
            ("지금 무슨 앱이 제일 많이 먹어?", .mac), ("맥 상테 어떄", .mac), ("8만원의 15%는?", .calc), ("고마워", .general),
        ]
        for (q, want) in cases { XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), want, q) }
        XCTAssertEqual(AssistantIntent.route("충전해야 돼?", hasHistory: true, previous: "배터리 몇 프로야?"), .mac)
        XCTAssertEqual(AssistantIntent.route("왜?", hasHistory: true, previous: "컴퓨터 왜 이렇게 느려?"), .mac)
        XCTAssertEqual(AssistantIntent.route("그거 몇 시야?", hasHistory: true, previous: "오늘 회의 있어?"), .schedule)
        XCTAssertEqual(AssistantIntent.route("그거 누가 보낸 거야?", hasHistory: true, previous: "가장 마지막에 온 문자내용 읽어줘."), .inbox)
        XCTAssertEqual(AssistantIntent.route("고래는 포유류야?", hasHistory: true, previous: "배터리 몇 프로야?"), .general)
        XCTAssertEqual(AssistantIntent.route("지금 몇 시야?", hasHistory: true, previous: "오늘 회의 있어?"), .realtime)

        // Mac: always the numbers, one verdict, no echo or contradiction.
        XCTAssertEqual(TemplateEngine.fixed(request("cpu 많이 써?")), "CPU는 3.0%라 여유 있어.")
        XCTAssertEqual(TemplateEngine.fixed(request("메모리얼마나남았어")), "메모리는 24.0 GB 중 16.2 GB를 쓰고 있어서 7.8 GB(32.7%)가 남았어. 압력이 보통이라 아직 넉넉해.")
        XCTAssertEqual(TemplateEngine.fixed(request("맥북 뜨거운데 괜찮아?")), "발열은 보통이라 괜찮아. CPU는 3.0%라 여유 있어.")
        XCTAssertEqual(TemplateEngine.fixed(request("디스크 꽉 찼어?")), "저장 공간은 전체 2.00 TB 중 1.72 TB 남아서 넉넉해.")
        XCTAssertEqual(TemplateEngine.fixed(request("컴퓨터 재부팅 해야 돼?")), "응, 한 번 재시동하는 게 좋아. 켜진 지 10일 10시간 됐어.")
        XCTAssertEqual(TemplateEngine.fixed(request("충전해야 돼?", history: [ChatTurn(user: "배터리 몇 프로야?", reply: "")])), "아직 충전 안 해도 돼. 배터리가 91% 남았어.")
        XCTAssertTrue(TemplateEngine.fixed(request("왜?", history: [ChatTurn(user: "컴퓨터 왜 이렇게 느려?", reply: "")]))?.contains("CPU는 3.0%") == true)
        for q in ["노트북 느린데 왜 그래", "컴터 왜케 느려", "렉 걸려 왜그래", "지금 무슨 앱이 제일 많이 먹어?", "맥 상테 어떄"] {
            XCTAssertTrue(TemplateEngine.fixed(request(q))?.contains(where: \.isNumber) == true, q)
        }

        // Calendar with times, and the part of the day asked.
        var day = request("저녁에 약속 있나")
        day.personal = ["10:00 주간 회의", "15:00 디자인 리뷰", "18:30 저녁 약속 (강남역)"]
        day.calendarLinked = true
        XCTAssertEqual(TemplateEngine.fixed(day), "저녁에는 18:30 저녁 약속 (강남역)이 있어.")
        day.question = "오늘 일정 알려줘"
        XCTAssertEqual(TemplateEngine.fixed(day), "오늘 남은 일정은 15:00 디자인 리뷰, 18:30 저녁 약속 (강남역)이야. 10:00 주간 회의는 이미 시작했어.")

        // Sums said with the particle the number is read with.
        XCTAssertEqual(TemplateEngine.fixed(request("250 나누기 4는 얼마야?")), "250 ÷ 4 = 62.5야.")
        XCTAssertEqual(TemplateEngine.fixed(request("1234+5678")), "1234 + 5678 = 6,912야.")
        XCTAssertEqual(TemplateEngine.fixed(request("8만원의 15%는?")), "80,000의 15% = 12,000원이야.")
        XCTAssertEqual(TemplateEngine.fixed(request("10 곱하기 3은?", polite)), "10 × 3 = 30이에요.")

        // Small talk the model fumbled: thanks said back, a meal pick of two.
        XCTAssertEqual(TemplateEngine.fixed(request("고마워")), "천만에, 또 필요하면 불러 줘.")
        XCTAssertTrue(TemplateEngine.fixed(request("오늘 점심 뭐 먹지"))?.hasPrefix("오늘 점심은 ") == true)
        XCTAssertNil(TemplateEngine.fixed(request("광합성이 뭐야?")))

        // Clean-up: a number sequence is no loop, a question's own subject is no made-up reading, a remark said back goes.
        XCTAssertEqual(AssistantPrompt.clean("피보나치 수열은 앞의 두 수를 더해 다음 수를 만들어. 예를 들어 1, 1, 2, 3, 5, 8처럼 이어져.", persona: jelly,
                                             for: request("피보나치 수열 설명해줘")), "피보나치 수열은 앞의 두 수를 더해 다음 수를 만들어. 예를 들어 1, 1, 2, 3, 5, 8처럼 이어져.")
        XCTAssertEqual(AssistantPrompt.clean("CPU는 범용 작업을 차례로 처리해. GPU는 많은 계산을 한꺼번에 병렬로 처리해.", persona: jelly,
                                             for: request("CPU랑 GPU 차이가 뭐야?")), "CPU는 범용 작업을 차례로 처리해. GPU는 많은 계산을 한꺼번에 병렬로 처리해.")
        XCTAssertEqual(AssistantPrompt.clean("오늘은 하루 종일 일하고 피곤하다. 오늘은 일찍 쉬어.", persona: jelly, for: request("오늘 너무 피곤하다")), "많이 피곤했구나. 오늘은 일찍 쉬어.")
        XCTAssertEqual(AssistantPrompt.clean("많이 피곤했구나. 오늘은 일찍 쉬어.", persona: jelly, for: request("오늘 너무 피곤하다")), "많이 피곤했구나. 오늘은 일찍 쉬어.")
        XCTAssertEqual(AssistantPrompt.clean("음식 종류: 피자, 떡볶이, 라면, 김밥, 불고기, 찜닭, 찜갈비. 아무거나 좋아.", persona: jelly, for: request("심심해")), "심심하구나. 아무거나 좋아.")
        XCTAssertEqual(Jondaet.fix("많이 힘들었겠구나. 산책은 어때?"), "많이 힘들었겠군요. 산책은 어때요?")
        XCTAssertEqual(Banmal.particle("62.5", "이", "가"), "가")
        XCTAssertEqual(Banmal.particle("10", "이", "가"), "이")
        XCTAssertEqual(Banmal.particle("저녁 약속 (강남역)", "이", "가"), "이")
    }

    /// Quality round 2 (assistant-eval round-2, 2026-10-04): every failure kind, by its cause.
    func testQualityRound2() {
        // Mac: "무슨 앱이 제일 많이 먹어?" names the app when measured, never "none" from no measurement.
        XCTAssertEqual(MacTopic.asked("지금 무슨 앱이 제일 많이 먹어?"), [.cpu, .memory])
        let hog = request("지금 무슨 앱이 제일 많이 먹어?")
        let notMeasured = TemplateEngine.fixed(hog) ?? ""
        XCTAssertTrue(notMeasured.hasPrefix("앱별 사용량은 지금 내가 못 읽어서"), notMeasured)
        XCTAssertFalse(notMeasured.contains("없어"), "no app line is not 'no busy app'")
        XCTAssertTrue(notMeasured.contains("CPU 3.0%, 메모리 67.3%"))
        var measured = hog
        measured.facts.append("바쁜 앱: Xcode")
        XCTAssertEqual(TemplateEngine.fixed(measured), "CPU를 제일 많이 쓰는 앱은 Xcode야. 전체로는 CPU 3.0%, 메모리 67.3%를 쓰는 중이라 여유 있어.")
        measured.facts[measured.facts.count - 1] = "바쁜 앱: 없음"
        XCTAssertTrue(TemplateEngine.fixed(measured)?.hasPrefix("지금은 눈에 띄게 CPU를 많이 쓰는 앱이 없어.") == true)

        // Calendar at 12:33: the next one, the time alone for "그거", nothing started called 남은, no to-dos unasked.
        let now = Calendar.current.date(bySettingHour: 12, minute: 33, second: 0, of: Date(timeIntervalSinceReferenceDate: 812_000_000))!
        func day(_ q: String, _ personal: [String], history: [ChatTurn] = []) -> String? {
            var r = request(q, history: history)
            r.personal = personal
            r.calendarLinked = true
            r.now = now
            return TemplateEngine.fixed(r)
        }
        let three = ["10:00 주간 회의", "15:00 디자인 리뷰", "18:30 저녁 약속 (강남역)"]
        XCTAssertEqual(day("다음 약속 몇 시야?", three), "다음 약속은 18:30 저녁 약속 (강남역)이야. 그 전에 15:00 디자인 리뷰도 있어.")
        XCTAssertEqual(day("다음 일정 뭐야?", three), "다음 일정은 15:00 디자인 리뷰야.")
        XCTAssertEqual(day("그거 몇 시야?", ["15:00 디자인 리뷰", "할 일: 보고서 제출", "할 일: 택배 반품 신청"],
                           history: [ChatTurn(user: "오늘 회의 있어?", reply: "")]), "디자인 리뷰는 15:00이야.")
        XCTAssertEqual(day("회의 언제야?", three), "10:00 주간 회의는 이미 시작했어. 다음 일정은 15:00 디자인 리뷰야.")
        XCTAssertEqual(day("오늘 약속 있어?", three), "오늘 약속은 18:30 저녁 약속 (강남역)이 있어.")
        XCTAssertEqual(day("다음 일정 뭐야?", ["09:00 조회"]), "오늘 남은 일정은 없어. 09:00 조회는 이미 시작했어.")
        XCTAssertEqual(day("오늘 일정 알려줘", ["15:00 디자인 리뷰", "할 일: 보고서 제출"]), "오늘 남은 일정은 15:00 디자인 리뷰야. 할 일은 보고서 제출이 남았어.")

        // Greetings and short feelings: answered from the table (the model skipped 안녕, mixed up 우울 and 피곤).
        XCTAssertEqual(TemplateEngine.fixed(request("안녕")), "안녕! 궁금한 거 있으면 언제든 물어봐.")
        XCTAssertEqual(TemplateEngine.fixed(request("안녕하세요", polite)), "안녕하세요! 궁금한 거 있으면 언제든 물어봐 주세요.")
        XCTAssertEqual(TemplateEngine.fixed(request("오늘 너무 피곤하다")), "많이 피곤했구나. 오늘은 일찍 씻고 푹 쉬어.")
        XCTAssertEqual(TemplateEngine.fixed(request("요즘 너무 우울해", polite)),
                       "요즘 많이 우울하셨군요. 오늘은 좋아하는 걸 하나만 해 보시고, 오래가면 가까운 사람이나 전문가와 이야기해 보세요.")
        XCTAssertEqual(TemplateEngine.fixed(request("나 오늘 회사에서 혼났어")), "혼나서 많이 속상했겠다. 오늘은 맛있는 거 먹으면서 마음부터 달래.")
        XCTAssertTrue(TemplateEngine.fixed(request("잠이 안 와"))?.hasPrefix("잠이 안 와서 답답하겠다.") == true)
        XCTAssertNil(TemplateEngine.fixed(request("우울증이 뭐야?")), "the idea, not a feeling")
        XCTAssertNil(TemplateEngine.fixed(request("피곤한데 어떻게 하면 좋을까?")), "asks something: the model's")
        XCTAssertEqual(TemplateEngine.answer(request("피곤한데 어떻게 하면 좋을까?")).prefix(9), "많이 피곤했구나.", "no model: still the feeling")
        // The model's answer to a feeling: the user's own feeling first, no other one, no question back.
        let sad = request("요즘 너무 우울한데 뭐 하면 좋을까", polite)
        XCTAssertEqual(AssistantPrompt.clean("많이 피곤했군요. 오늘은 푹 쉬세요.", persona: polite, for: sad), "요즘 많이 우울하셨군요. 오늘은 푹 쉬세요.")
        XCTAssertEqual(AssistantPrompt.clean("혼났구나. 오늘 하루를 어떻게 보냈어?", persona: jelly, for: request("회사에서 혼났는데 어떡하지")),
                       "혼났구나. 오늘은 맛있는 거 먹으면서 마음부터 달래.")
        XCTAssertEqual(AssistantPrompt.clean("많이 피곤했구나. 오늘 하루 종일 일하고 지쳤겠지. 그래도 오늘 하루 종일 일하고 지쳤겠지.", persona: jelly,
                                             for: request("오늘 너무 피곤한데 뭐 하지")), "많이 피곤했구나. 오늘 하루 종일 일하고 지쳤겠지.")

        // Knowledge goes through English; feelings, picks, translation and writing do not.
        XCTAssertTrue(Pivot.applies(request("세종대왕이 만든 거 뭐야?")))
        XCTAssertTrue(Pivot.applies(request("피보나치 수열 설명해줘")))
        for q in ["오늘 너무 피곤하다", "사과를 영어로 뭐라고 해?", "주말에 뭐 하지?", "메일 다듬어 줘: 내일 회의 자료 확인 부탁드립니다", "배고파", "메모리 부족해?"] {
            XCTAssertFalse(Pivot.applies(request(q)), q)
        }
        XCTAssertEqual(Pivot.english("Q: Is a whale a mammal?\nA: Yes, whales are mammals. They breathe air. They nurse their young."),
                       "Yes, whales are mammals. They breathe air.")
        XCTAssertTrue(Pivot.retell(request("광합성이 뭐야?"), english: "It uses carbon dioxide in chloroplasts.").contains("carbon dioxide(이산화탄소) in chloroplasts(엽록체)"))
        XCTAssertTrue(Pivot.retellInstructions(polite).contains("해요체"))

        // Clean-up: 해라체 in the polite voice, a hanging number list, near repeats, a percent that is no Mac reading.
        XCTAssertEqual(AssistantPrompt.clean("고래는 포유류예요. 새끼는 젖을 먹고 자란다.", persona: polite, for: request("고래는 포유류야?", polite)),
                       "고래는 포유류예요. 새끼는 젖을 먹고 자라요.")
        XCTAssertEqual(Jondaet.fix("물은 끓는다. 일을 한다. 볼 수 있다. 빛을 본다. 물을 마신다."), "물은 끓어요. 일을 해요. 볼 수 있어요. 빛을 봐요. 물을 마셔요.")
        XCTAssertEqual(AssistantPrompt.clean("앞의 두 수를 더해 다음 수를 만들어. 예를 들어 0, 1, 1, 2, 3, 5, 8, ...", persona: jelly, for: request("피보나치 수열 설명해줘")),
                       "앞의 두 수를 더해 다음 수를 만들어. 예를 들어 0, 1, 1, 2, 3, 5, 8처럼 이어져.")
        XCTAssertEqual(AssistantPrompt.clean("예를 들어 1, 1, 2, 3, ... 이렇게 계속 이어져.", persona: jelly, for: request("피보나치 수열 설명해줘")),
                       "예를 들어 1, 1, 2, 3 이렇게 계속 이어져.")
        XCTAssertEqual(AssistantPrompt.clean("공기의 약 78%는 질소야. RAM은 메모리의 한 종류야.", persona: jelly, for: request("공기는 뭘로 돼 있어?")),
                       "공기의 약 78%는 질소야. RAM은 메모리의 한 종류야.")
        XCTAssertTrue(polite.instructions.hasPrefix("너는 '젤리'야."))
    }
}
