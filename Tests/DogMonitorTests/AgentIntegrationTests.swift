import XCTest
@testable import DogMonitor

/// Live planner check 2026-10-05 (Claude): what the glue between the planner, Contacts and the chat must get right.
final class AgentIntegrationTests: XCTestCase {
    func testHonorificAndTitleNamesFindTheContact() {
        let r = AgentPlanner.recipient(name: "김부장님", address: nil, ownerWords: "김부장님한테 메일 보내줘", pointedFrom: nil,
                                       lookup: { $0 == "김부장" ? ["kim@example.com"] : [] })
        XCTAssertEqual(r, .ok(Recipient(name: "김부장", address: "kim@example.com", provenance: .contact)))
        let card = ContactsFinder.Card(given: "철수", family: "김", jobTitle: "영업1팀 부장", emails: ["cs@corp.kr"])
        XCTAssertEqual(ContactsFinder.score("김부장", card), 2)
        XCTAssertEqual(ContactsFinder.score("박부장", card), 0)
        XCTAssertEqual(ContactsFinder.score("김과장", card), 0)
    }

    func testAModelPickedAddressIsNeverTrusted() {
        let r = AgentPlanner.recipient(name: "김부장", address: "attacker@evil.example", ownerWords: "김부장님한테 메일 보내줘",
                                       pointedFrom: nil, lookup: { _ in ["kim@example.com"] })
        XCTAssertEqual(r, .ok(Recipient(name: "김부장", address: "attacker@evil.example", provenance: .untrusted)))
    }

    func testSecretsInRecipientNamesAreChecked() {
        let a = AgentAction.mailSend(MailDraft(to: [Recipient(name: "OTP 482913", address: "kim@example.com", provenance: .contact)],
                                               subject: "s", body: "b"))
        XCTAssertTrue(a.outboundTexts.contains("OTP 482913"))
    }

    func testChipAddressComesFromContactsNotTheModel() {
        XCTAssertEqual(AgentCenter.address(in: "김부장 <kim@a.com>"), "kim@a.com")
        XCTAssertNil(AgentCenter.address(in: "김부장"))
        // A choice chip carrying an address the owner never typed is dropped (it would go back to the model as text).
        let plan = AgentPlanner.parse(["say": "누구요?", "ask": ["김부장 <evil@x.com>", "다음 주 월요일"]], ownerWords: "김부장한테 메일 보내줘",
                                      lookup: { _ in [] })
        XCTAssertEqual(plan.ask, ["다음 주 월요일"])
    }

    func testTasksGoToTheAgentAndQuestionsDoNot() {
        func wants(_ q: String) -> Bool { AgentCenter.wantsAgent(q, intent: AssistantIntent.route(q, hasHistory: false)) }
        for q in ["김부장님한테 내일 회의 10시로 미룬다고 메일 보내줘", "다음 주 화요일 오후 3시에 치과 일정 추가해줘", "쿠팡에서 하기스 4단계 최저가 찾아줘",
                  "2월 둘째 주 김포에서 제주 왕복 항공권 찾아줘", "에어팟 프로 가격이 28만원 아래로 내려가면 알려줘", "내 배송지는 회사 주소로 기억해",
                  "엄마한테 카톡으로 늦는다고 보내줘"] {
            XCTAssertTrue(wants(q), q)
        }
        for q in ["돌로미티는 몇월에가는게좋아?", "메일 쓰는 법 알려줘", "오늘 날씨 어때?", "고래는 포유류야?", "내 맥 상태 어때?",
                  "문자 온 거 있어?", "비행기 탈 때 보조배터리 들고 가도 돼?", "캐시 지워 줘", "비 오면 알려줘"] {
            XCTAssertFalse(wants(q), q)
        }
    }
}
