import XCTest
@testable import DogMonitor

/// The chat's inbox answers from made-up findings (InboxReport.made): each state said in its own words, never made up.
final class InboxReportTests: XCTestCase {
    private let now = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 812_000_000))!

    private func say(_ q: String, _ lines: [String], polite: Bool = false, previous: String? = nil) -> String {
        InboxReport.made(lines, query: InboxQuery.parse(q, previous: previous, now: now), now: now).answer(polite: polite, now: now)
    }

    func testQueryParse() {
        XCTAssertEqual(InboxQuery.parse("가장 최근에 온 문자", now: now).limit, 1)
        XCTAssertEqual(InboxQuery.parse("문자 읽어줘", now: now).limit, 3)
        XCTAssertEqual(InboxQuery.parse("문자 두 개만", now: now).limit, 2)
        XCTAssertEqual(InboxQuery.parse("문자 10개 보여줘", now: now).limit, InboxQuery.maxLimit)
        XCTAssertEqual(InboxQuery.parse("문자 몇 통 왔어?", now: now).limit, 3)
        XCTAssertEqual(InboxQuery.parse("문자 읽어줘", now: now).kinds, [.message])
        XCTAssertEqual(InboxQuery.parse("뭐 왔어?", now: now).kinds, [.message, .mail, .notification])
        let kakao = InboxQuery.parse("카톡 알림 뭐 왔어?", now: now)
        XCTAssertEqual(kakao.kinds, [.notification])
        XCTAssertTrue(kakao.strictWho && kakao.who.contains("카카오톡"))
        XCTAssertEqual(InboxQuery.parse("엄마한테서 온 문자", now: now).who, ["엄마"])
        XCTAssertTrue(InboxQuery.parse("철수가 보낸 메일", now: now).strictWho)
        XCTAssertEqual(InboxQuery.parse("엄마 문자 읽어줘", now: now).strictWho, false)
        for q in ["나 가장 최근에 온 문자 내역 알랴줘.", "누가 문자 했어", "나한테 온 문자", "그럼 메일은?", "안읽은 메일"] {
            XCTAssertEqual(InboxQuery.parse(q, now: now).who, [], q)
        }
        XCTAssertEqual(InboxQuery.parse("오늘 온 문자", now: now).periodName, "오늘")
        XCTAssertEqual(InboxQuery.parse("어제 문자", now: now).period?.end, Calendar.current.startOfDay(for: now))
        let more = InboxQuery.parse("더 보여줘", previous: "문자 읽어줘", now: now)
        XCTAssertEqual([more.skip, more.limit], [3, InboxQuery.maxLimit])
        XCTAssertEqual(more.kinds, [.message])
    }

    func testStatesAreToldApart() {
        let place = "시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근"
        XCTAssertEqual(say("문자 읽어줘", ["문자: 권한 풀림"]), "업데이트하면서 전체 디스크 접근 권한이 풀려서 지금은 문자를 읽을 수 없어. \(place)에서 캐릭모니터를 다시 켜 줘.")
        XCTAssertEqual(say("문자 읽어줘", ["문자: 권한 없음"], polite: true), "전체 디스크 접근 권한이 없어서 지금은 문자를 읽을 수 없어요. \(place)에서 캐릭모니터를 켜 주세요.")
        XCTAssertEqual(say("문자 읽어줘", ["문자: 없음"]), "최근에 받은 문자는 없어.")
        XCTAssertEqual(say("오늘 온 문자", ["문자: 없음"]), "오늘 받은 문자는 없어.")
        XCTAssertEqual(say("문자 읽어줘", ["문자: 꺼짐"], polite: true), "문자 연동이 꺼져 있어서 지금은 볼 수 없어요. 비서 설정에서 '문자 메시지 알려주기'를 켜 주세요.")
        XCTAssertEqual(say("문자 읽어줘", ["문자: 기록 없음"]), "이 맥에서 메시지 기록을 찾지 못했어. 메시지 앱에 로그인했는지 확인해 줘.")
        XCTAssertEqual(say("메일 온 거 있어?", ["메일: 없음"]), "앱이 켜진 뒤로 새로 온 메일은 아직 없어.")
        // Nothing named: a kind that is off stays out, one that is on but unreadable does not.
        XCTAssertEqual(say("뭐 왔어?", ["문자: 없음", "알림: 권한 없음"]),
                       "전체 디스크 접근 권한이 없어서 지금은 알림을 읽을 수 없어. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근에서 캐릭모니터를 켜 줘. 최근에 받은 문자는 없어.")
        XCTAssertTrue(say("뭐 왔어?", []).hasPrefix("문자·메일·알림 연동이 꺼져 있어서"))
        for s in [say("문자 읽어줘", ["문자: 권한 풀림"]), say("문자 읽어줘", ["문자: 꺼짐"])] {
            XCTAssertFalse(s.contains("없어.") && !s.contains("읽을 수 없어") && !s.contains("볼 수 없어"), "never 'nothing came' for a state")
        }
    }

    func testItemsSaidNaturally() {
        let lines = ["14:05 문자 엄마: 저녁 먹었어?", "13:20 문자 김철수: 회의 자료요", "10/2 21:00 문자 친구: ㅋㅋ", "14:30 알림 카카오톡: 아빠: 주말에 와?"]
        XCTAssertEqual(say("가장 최근 문자 알려줘", lines), "가장 최근 문자는 엄마한테서 14:05에 온 거야: 저녁 먹었어?")
        XCTAssertEqual(say("가장 최근 문자 알려줘", lines, polite: true), "가장 최근 문자는 엄마한테서 14:05에 온 거예요: 저녁 먹었어?")
        XCTAssertEqual(say("문자 읽어줘", lines), "최근 받은 문자 3개야.\n14:05 엄마: 저녁 먹었어?\n13:20 김철수: 회의 자료요\n10/2 21:00 친구: ㅋㅋ")
        XCTAssertEqual(say("카톡 뭐 왔어?", lines), "카카오톡에서 14:30에 온 알림이야: 아빠: 주말에 와?")
        // Five came, three shown: never "3개야" as if that were all (measured 2026-10-04).
        XCTAssertEqual(say("뭐 왔어?", lines + ["10/1 09:00 문자 동생: 잘 자"]), "받은 문자·알림 중 최근 3개야.\n14:30 알림 카카오톡: 아빠: 주말에 와?\n14:05 문자 엄마: 저녁 먹었어?\n13:20 문자 김철수: 회의 자료요\n더 있어. '더 보여줘'라고 하면 이어서 알려 줄게.")
        // Four came: all four, not three and "더 있어" for the one left (quality round 2).
        XCTAssertEqual(say("뭐 왔어?", lines), "최근 받은 문자·알림 4개야.\n14:30 알림 카카오톡: 아빠: 주말에 와?\n14:05 문자 엄마: 저녁 먹었어?\n13:20 문자 김철수: 회의 자료요\n10/2 21:00 문자 친구: ㅋㅋ")
        XCTAssertEqual(say("오늘 온 문자 다 보여줘", lines), "오늘 받은 문자 2개야.\n14:05 엄마: 저녁 먹었어?\n13:20 김철수: 회의 자료요")
        XCTAssertTrue(say("그럼 메일은?", lines + ["메일: 꺼짐"], previous: "마지막 문자").hasPrefix("메일 연동이 꺼져 있어서 지금은 볼 수 없어. 비서 설정에서 "))
        XCTAssertTrue(say("그럼 메일은?", lines + ["메일: 꺼짐"], previous: "마지막 문자").hasSuffix("'메일 계정'을 켜 줘."))
        // Found some, another named kind unreadable: both said.
        XCTAssertEqual(say("문자랑 알림 읽어줘", ["14:05 문자 엄마: 저녁 먹었어?", "알림: 권한 풀림"]),
                       "최근 받은 문자는 이거 하나야. 엄마한테서 14:05에 왔어: 저녁 먹었어?\n업데이트하면서 전체 디스크 접근 권한이 풀려서 지금은 알림을 읽을 수 없어. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근에서 캐릭모니터를 다시 켜 줘.")
    }

    /// The whole answer comes out as the app made it: lines kept, not cut to three sentences.
    func testInboxAnswerIsNotCleanedIntoOneParagraph() async {
        var r = ChatRequest(persona: Persona(name: "젤리", style: .friendly), summary: "", history: [], facts: [], personal: [], question: "문자 읽어줘")
        r.now = now
        r.inbox = InboxReport.made(["14:05 문자 엄마: 저녁 먹었어?", "13:20 문자 김철수: 회의 자료요"], query: r.inboxQuery, now: now)
        let out = await AssistantAnswer.make(r, engine: TemplateEngine())
        XCTAssertEqual(out.text, "최근 받은 문자 2개야.\n14:05 엄마: 저녁 먹었어?\n13:20 김철수: 회의 자료요")
    }

    /// Quality round 2 (assistant-eval, 2026-10-04): a sender not among the recent ones is said with that scope, and
    /// "안 읽은 거" is one sentence and every item when only one more would be left.
    func testQualityRound2() {
        let two = ["10/3 21:05 문자 김철수: 내일 회의 10시로 바뀌었어요", "10/3 23:41 문자 쿠팡: 주문하신 상품이 배송 완료되었습니다"]
        XCTAssertEqual(say("엄마한테 문자 온 거 있어?", two), "최근 받은 문자 중엔 엄마한테서 온 게 없어.")
        XCTAssertEqual(say("엄마한테 문자 온 거 있어?", two, polite: true), "최근 받은 문자 중엔 엄마한테서 온 게 없어요.")
        XCTAssertEqual(say("카톡 온 거 있어?", ["알림: 없음"]), "최근 받은 알림 중엔 카카오톡에서 온 게 없어.")
        let mixed = ["08:50 문자 엄마: 저녁 먹으러 올 거야?", "09:12 네이버 메일 이지은: 견적서 회신드립니다",
                     "09:40 알림 카카오톡: 박민수: 점심 같이 먹을래?", "10:05 문자 김철수: 회의 자료 보냈어요"]
        let unread = say("안 읽은 거 있어?", mixed).components(separatedBy: "\n")
        XCTAssertEqual(unread.count, 5)
        XCTAssertEqual(unread.first, "읽었는지는 내가 알 수 없어서 최근 받은 문자·메일·알림 4개를 알려 줄게.")
        XCTAssertTrue(unread.contains("08:50 문자 엄마: 저녁 먹으러 올 거야?"))
        XCTAssertFalse(unread.contains { $0.hasPrefix("더 있어") })
        // "가장 최근" stays one, with more behind it.
        XCTAssertEqual(InboxQuery.parse("가장 최근 문자", now: now).pick((0..<2).map { InboxItem(kind: .message, who: "a", preview: nil, date: now.addingTimeInterval(Double(-$0))) }).items.count, 1)
    }

    /// Quality round 1 (2026-10-04): the shapes the eval passes, each read as what it says.
    func testMadeLinesAndStatesRound1() {
        let mixed = ["08:50 문자 엄마: 저녁 먹으러 올 거야?", "09:12 네이버 메일 이지은: 견적서 회신드립니다",
                     "09:40 알림 카카오톡: 박민수: 점심 같이 먹을래?", "10:05 문자 김철수: 회의 자료 보냈어요"]
        // A mail account's name before 메일 is still mail (it was dropped, so "하나야" and "연동 꺼짐").
        XCTAssertEqual(say("메일 온 거 있어?", ["09:12 네이버 메일 이지은: 견적서 회신드립니다", "09:30 메일 GitHub: 새 이슈"]),
                       "최근 받은 메일 2개야.\n09:30 GitHub: 새 이슈\n09:12 이지은: 견적서 회신드립니다")
        XCTAssertTrue(say("메일 온 거 있어요?", mixed, polite: true).contains("이지은한테서 09:12에 왔어요: 견적서 회신드립니다"))
        // A time with no date is today's, never pushed to yesterday with a made-up date.
        let early = Calendar.current.date(bySettingHour: 10, minute: 4, second: 0, of: now)!
        let last = InboxReport.made(mixed, query: InboxQuery.parse("마지막으로 온 문자 누구한테 왔어?", now: early), now: early).answer(polite: false, now: early)
        XCTAssertEqual(last, "가장 최근 문자는 김철수한테서 10:05에 온 거야: 회의 자료 보냈어요")
        // Every sender for "누구", and no count that sounds like all of them.
        let who = say("누구한테 연락 왔어?", mixed)
        for name in ["엄마", "이지은", "박민수", "김철수"] { XCTAssertTrue(who.contains(name), name) }
        XCTAssertTrue(who.hasPrefix("최근 받은 문자·메일·알림 4개야."))
        // A permission line with its reason is a permission problem, never "nothing came" (the user's screenshot).
        let place = "시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근"
        XCTAssertEqual(say("최근 문자 알려줘", ["문자: 읽을 수 없음 (전체 디스크 접근 권한 없음)"]),
                       "전체 디스크 접근 권한이 없어서 지금은 문자를 읽을 수 없어. \(place)에서 캐릭모니터를 켜 줘.")
        XCTAssertTrue(say("카톡 알림 온 거 있어?", ["알림: 읽을 수 없음 (전체 디스크 접근 권한 없음)"]).hasPrefix("전체 디스크 접근 권한이 없어서 지금은 알림을"))
        // What the app knows as a summary is said as is.
        XCTAssertEqual(say("새 메일 몇 통이야?", ["메일: 안 읽은 메일 3통 (이지은, 네이버페이, GitHub)", "문자: 읽을 수 없음"]),
                       "안 읽은 메일 3통이야: 이지은, 네이버페이, GitHub.")
        XCTAssertEqual(say("문자 온 거 있어?", ["최근 6시간 동안 새로 온 문자·메일·알림은 없음"]), "최근 6시간 동안 새로 온 문자·메일·알림은 없어.")
        // "who texted me" is texts only (" dm" inside "textedme" is no notification).
        XCTAssertEqual(InboxQuery.parse("who texted me", now: now).kinds, [.message])
        XCTAssertTrue(say("안 읽은 거 있어?", mixed).hasPrefix("읽었는지는 내가 알 수 없어서 최근 받은 문자·메일·알림 4개를 알려 줄게.\n"))
    }
}
