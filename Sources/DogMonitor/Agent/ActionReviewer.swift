import Foundation

// dots' "a separate model reviews account-affecting and outbound actions against the user's intent". Ours runs on the
// owner's own engine (its cheapest tier, a fresh call, no tools), sees the owner's words and the frozen proposal, and never
// the raw mail or web text the planner read (so an injection there cannot carry over). It can only make things stricter.

struct ReviewVerdict: Equatable {
    enum Kind: String, Equatable { case ok, ask, block }
    var kind: Kind
    var reason: String
}

enum ActionReviewer {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["verdict": ["type": "string", "enum": ["ok", "ask", "block"]], "reason": ["type": "string"]],
        "required": ["verdict", "reason"],
    ]

    static let system = """
        너는 비서 앱의 2차 검토자야. 사용자가 한 말과, 비서가 사용자 대신 하려는 행동이 주어져.
        행동이 사용자의 말과 의도에 맞는지만 판단해.
        - ok: 받는 사람, 내용, 날짜가 사용자가 원한 그대로야.
        - ask: 사용자가 말하지 않은 사람에게 보내거나, 사용자가 말하지 않은 내용·약속·금액이 들어 있거나, 날짜가 어긋나거나, 애매해.
        - block: 사용자를 해치거나 속이는 행동, 개인정보나 인증번호·비밀번호를 밖으로 보내는 행동, 사용자가 원하지 않은 게 분명한 행동.
        reason은 한국어 한 문장으로, 사용자에게 그대로 보여 줄 말이야.
        """

    /// What the reviewer reads. Recipients as name, where the address came from and its domain only (the Contacts promise:
    /// addresses go only to the mail server).
    static func prompt(ownerWords: String, action: AgentAction, origin: Origin, goal: String? = nil, now: Date = Date()) -> String {
        var lines = ["[지금] \(AssistantPrompt.nowLine(now))", "[사용자가 한 말]\n\(ownerWords)"]
        if let goal { lines.append("[맡긴 일]\n\(goal)") }
        if origin == .background { lines.append("[상황] 사용자가 자리에 없을 때 맡긴 일이 스스로 만든 제안이야.") }
        lines.append("[하려는 행동]\n" + describe(action))
        lines.append("JSON {verdict, reason} 하나로만 답해.")
        return lines.joined(separator: "\n\n")
    }

    static func describe(_ action: AgentAction) -> String {
        func who(_ rs: [Recipient]) -> String {
            rs.map { r in
                let domain = r.address.split(separator: "@").last.map(String.init) ?? "?"
                let from: String
                switch r.provenance {
                case .ownerWords: from = "사용자가 직접 쓴 주소"
                case .contact: from = "사용자가 말한 이름의 연락처"
                case .pointedMail: from = "사용자가 가리킨 메일의 보낸 사람"
                case .ownerProfile: from = "사용자가 기억시킨 정보"
                case .untrusted: from = "받은 메일이나 웹에서 나온 주소"
                }
                return "\(r.name ?? "(이름 없음)") (@\(domain), \(from))"
            }.joined(separator: ", ")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) a h:mm"
        switch action {
        case .mailSend(let m), .mailReply(let m, _):
            return "메일 보내기\n받는 사람: \(who(m.to))" + (m.cc.isEmpty ? "" : "\n참조: \(who(m.cc))") + "\n제목: \(m.subject)\n본문:\n\(m.body)"
        case .messagePrepare(let to, let body): return "문자 준비\n받는 사람: \(who(to))\n내용: \(body)"
        case .kakaoPrepare(let body): return "카카오톡 메시지 준비\n내용: \(body)"
        case .messageSend(let to, let body): return "문자 보내기\n받는 사람: \(who(to))\n내용: \(body)"
        case .webStep(let w):
            let host = URL(string: w.pageURL)?.host ?? w.pageURL
            let target = w.kind == .open ? "주소: \(w.pageURL)" : "'\(w.label)' (\(host))"
            let value = w.value.map { w.kind == .click ? "\n이동할 곳: \($0)" : "\n입력할 값: \($0)" } ?? ""
            return "웹 브라우저에서 \(w.kind.rawValue): \(target)" + value + (w.submit == true ? "\n입력 후 Enter로 제출" : "") + "\n이유: \(w.why)"
        case .eventAdd(let e): return "일정 추가: \(e.title), \(f.string(from: e.start))~\(f.string(from: e.end))" + (e.location.map { ", \($0)" } ?? "")
        case .reminderAdd(let r): return "미리알림 추가: \(r.title)" + (r.due.map { ", \(f.string(from: $0))" } ?? "")
        case .reminderDone(_, let title): return "미리알림 완료 처리: \(title)"
        case .shopSearch(let q, _): return "상품 찾기: \(q)"
        case .flightSearch(let q): return "항공권 찾기: \(q.from)→\(q.to)"
        case .goalCreate(let g):
            switch g.kind {
            case .priceWatch(let q, let target, _): return "맡긴 일 만들기: '\(q)' 가격 지켜보기" + (target.map { ", \($0)원 이하면 알림" } ?? "")
            case .agent(let p): return "맡긴 일 만들기: \(p), \(g.everyMinutes)분마다"
            }
        case .memoryAdd(let k, let v): return "기억하기: \(k) = \(v)"
        case .undo: return "되돌리기"
        }
    }

    static func parse(_ json: [String: Any]) -> ReviewVerdict? {
        guard let v = (json["verdict"] as? String).flatMap(ReviewVerdict.Kind.init) else { return nil }
        return ReviewVerdict(kind: v, reason: (json["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// nil = the review could not run (timeout, limit, no engine): the card says so and nothing runs without a tap.
    static func review(engine: BYOEngine, ownerWords: String, action: AgentAction, origin: Origin, goal: String? = nil) async -> ReviewVerdict? {
        guard let json = try? await engine.structured(system: system, prompt: prompt(ownerWords: ownerWords, action: action, origin: origin, goal: goal),
                                                      schema: schema, reviewer: true) else { return nil }
        return parse(json)
    }

    /// The reviewer only escalates: ask turns any automatic tier into a card, block marks it for a double confirm, and a
    /// missing review keeps it off automatic. It never lowers a tier and never touches a code block.
    static func apply(_ verdict: ReviewVerdict?, to decision: Decision) -> (decision: Decision, line: String?, doubleConfirm: Bool) {
        var d = decision
        guard d.tier != .blocked else { return (d, nil, false) }
        guard let verdict else {
            if d.tier < .confirm { d.tier = .confirm }
            return (d, L("2차 검토를 못 했어요. 내용을 직접 확인해 주세요."), false)
        }
        switch verdict.kind {
        case .ok: return (d, nil, false)
        case .ask:
            if d.tier < .confirm { d.tier = .confirm }
            return (d, verdict.reason, false)
        case .block:
            if d.tier < .confirm { d.tier = .confirm }
            return (d, verdict.reason, true)
        }
    }
}
