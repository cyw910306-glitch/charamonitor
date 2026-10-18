import SwiftUI

/// QA_ONLY=agent renders: the proposal cards in each state, from made-up data (nothing is saved or sent).
enum AgentQA {
    @MainActor
    static func render(to dir: URL) throws {
        let now = Date()
        let cal = Calendar.current
        let tomorrow3 = cal.date(bySettingHour: 15, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        let mail = MailDraft(accountID: nil, to: [Recipient(name: "김부장", address: "kim@example.com", provenance: .contact)],
                             subject: "내일 회의 시간 변경 안내", body: "김부장님, 안녕하세요.\n내일 회의를 오전 10시로 미루게 되어 안내드립니다.\n감사합니다.")
        var risky = mail
        risky.to = [Recipient(name: nil, address: "pay-help@evil.example", provenance: .untrusted)]
        func card(_ a: AgentAction, _ tier: Tier, reviewer: String? = nil, concerns: [Concern] = [], state: FrozenAction.State = .proposed,
                  reasons: [String] = []) -> FrozenAction {
            var f = FrozenAction(action: a, origin: .chat, decision: Decision(tier: tier, needsReview: reviewer != nil, reasons: reasons),
                                 concerns: concerns.map(\.message), reviewer: reviewer, createdAt: now)
            f.state = state
            return f
        }
        let cards: [(String, FrozenAction)] = [
            ("mail", card(.mailSend(mail), .confirm, reviewer: "내용이 부탁과 맞아요")),
            ("sending", card(.mailSend(mail), .confirm, reviewer: "내용이 부탁과 맞아요", state: .approved)),
            ("untrusted", card(.mailSend(risky), .confirm, reviewer: "사용자가 말하지 않은 주소로 보내려 해요", reasons: [ActionCopy.reviewerBlockMark])),
            ("event", card(.eventAdd(EventDraft(title: "치과", start: tomorrow3, end: tomorrow3.addingTimeInterval(3600), location: "강남역")), .confirm)),
            ("flight", card(.flightSearch(FlightQuery(from: "GMP", to: "CJU", depart: cal.date(byAdding: .day, value: 30, to: now)!,
                                                       returnDate: cal.date(byAdding: .day, value: 33, to: now)!, adults: 2, airline: "진에어")), .prepareOnly)),
            ("shop", card(.shopSearch(query: "하기스 네이처메이드 4단계", store: nil), .auto,
                          state: .done(summary: "1. 하기스 네이처메이드 4단계 팬티 62매 29,900원 (쿠팡)\n2. 하기스 4단계 밴드 64매 31,200원 (11번가)", undoID: nil))),
            ("goal", card(.goalCreate(GoalDraft(title: "에어팟 프로 가격 지켜보기", kind: .priceWatch(query: "에어팟 프로 2", target: 280000, dropPercent: nil))), .confirm)),
            ("watch", card(.goalCreate(GoalDraft(title: "제주 항공권 지켜보기", kind: .agent(prompt: "12월 김포-제주 왕복 10만 원 아래 항공권 찾기"),
                                                  everyMinutes: 360)), .confirm)),
            ("web", card(.webStep(WebStep(kind: .click, pageURL: "https://www.11st.co.kr/products/812391137", label: "장바구니 담기", ref: "e41",
                                          signature: "s", value: nil, why: "상태를 바꾸는 버튼이라 확인받을게요")), .confirm, reviewer: "내용이 부탁과 맞아요")),
            ("text", card(.messageSend(to: [Recipient(name: "엄마", address: "010-1234-5678", provenance: .contact)], body: "오늘 저녁 7시쯤 도착해요"),
                          .confirm, reviewer: "내용이 부탁과 맞아요")),
            ("blocked", card(.mailSend(MailDraft(accountID: nil, to: [Recipient(name: "엄마", address: "mom@example.com", provenance: .contact)],
                                                 subject: "인증번호", body: "인증번호는 482913이에요")), .blocked,
                             concerns: [Concern(kind: .secret, message: "인증번호처럼 보이는 숫자는 보낼 수 없어요", blocking: true)])),
            ("done", card(.eventAdd(EventDraft(title: "치과", start: tomorrow3, end: tomorrow3.addingTimeInterval(3600))), .confirm,
                          state: .done(summary: "10월 6일 (화) 오후 3:00~4:00 '치과'를 AI 비서 캘린더에 넣었어요", undoID: "e:1"))),
        ]
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let page = VStack(alignment: .leading, spacing: 10) {
                ForEach(cards, id: \.0) { name, f in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                        AgentCardView(card: f, countingDown: name == "sending", undoable: name == "done")
                    }
                }
            }
            .padding(14).frame(width: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            try DashboardSnapshot.snapshot(page, appearance: appearance, to: dir.appendingPathComponent("agent-cards-\(suffix).png"))
        }
    }
}
