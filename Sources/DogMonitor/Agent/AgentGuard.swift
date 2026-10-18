import Foundation

/// The deterministic check that runs before any model looks and again on approval (design section 4). Pure: everything
/// it needs comes in as arguments, so the card, the approval tap and the tests all see the same answer. It cannot be
/// turned off; AgentPolicy turns a blocking concern into `.blocked` and any other one into at least `.confirm`.
enum AgentGuard {
    /// How many writes already happened today, from actions.jsonl (the guard does not read files).
    struct Counts: Equatable {
        var mails = 0
        /// Event adds plus reminder adds and dones: every EventKit write counts toward one cap.
        var eventsAndReminders = 0
        /// Goals that are active now, not created today: the cap is on what keeps running.
        var activeGoals = 0
    }

    static let mailCap = 20
    static let eventReminderCap = 30
    static let goalCap = 10
    static let chatExpiry: TimeInterval = 30 * 60
    static let backgroundExpiry: TimeInterval = 12 * 3600
    /// Dates further out than this are almost always a misread year ("2027" for "27일").
    static let maxDaysAhead = 400
    /// A copied run this long from a received text counts as forwarding it (short ones are greetings and names).
    static let forwardRun = 12

    static func check(_ action: AgentAction, origin: Origin, proposedAt: Date, now: Date, ownerWords: String,
                      todayCounts: Counts, receivedTexts: [String],
                      knownAirport: (String) -> Bool = { _ in true }) -> [Concern] {
        var out = expiry(origin: origin, proposedAt: proposedAt, now: now)
        out += schema(action, now: now, knownAirport: knownAirport)
        out += provenance(action.recipients, ownerWords: ownerWords)
        for text in action.outboundTexts { out += secrets(in: text) }
        out += forwarding(action.outboundTexts, receivedTexts: receivedTexts)
        out += caps(action.type, todayCounts)
        return out
    }

    // MARK: Expiry and caps

    static func expiry(origin: Origin, proposedAt: Date, now: Date) -> [Concern] {
        let limit = origin == .chat ? chatExpiry : backgroundExpiry
        guard now.timeIntervalSince(proposedAt) > limit else { return [] }
        return [Concern(kind: .expired, message: L("제안한 지 오래돼서 만료됐어요. 다시 부탁해 주세요"), blocking: true)]
    }

    static func caps(_ type: AgentActionType, _ c: Counts) -> [Concern] {
        let over: Bool
        switch type {
        case .mailSend, .mailReply, .messageSend: over = c.mails >= mailCap   // ponytail: one outbound cap for mail and texts
        case .eventAdd, .reminderAdd, .reminderDone: over = c.eventsAndReminders >= eventReminderCap
        case .goalCreate: over = c.activeGoals >= goalCap
        default: over = false
        }
        return over ? [Concern(kind: .cap, message: L("오늘 할 수 있는 만큼 다 했어요. 내일 다시 할게요"), blocking: true)] : []
    }

    // MARK: Schema

    static func schema(_ action: AgentAction, now: Date, knownAirport: (String) -> Bool) -> [Concern] {
        var bad: [String] = []
        let latest = now.addingTimeInterval(TimeInterval(maxDaysAhead) * 86_400)
        func when(_ d: Date, notBefore: Date) {
            if d < notBefore { bad.append(L("이미 지난 날짜예요")) }
            else if d > latest { bad.append(L("400일보다 먼 날짜예요")) }
        }
        switch action {
        case .eventAdd(let e):
            when(e.start, notBefore: now)
            if e.end <= e.start { bad.append(L("끝나는 시간이 시작보다 앞이에요")) }
        case .reminderAdd(let r):
            if let due = r.due { when(due, notBefore: now) }
        case .mailSend(let m), .mailReply(let m, _):
            if m.to.isEmpty { bad.append(L("받는 사람이 없어요")) }
            for r in m.to + m.cc where !isEmail(r.address) { bad.append(L("메일 주소 모양이 아니에요: \(r.address)")) }
        case .messagePrepare(let to, _), .messageSend(let to, _):
            if to.isEmpty { bad.append(L("받는 사람이 없어요")) }
            for r in to where !isEmail(r.address) && !isPhone(r.address) {
                bad.append(L("메일 주소나 전화번호가 아니에요: \(r.address)"))
            }
        case .flightSearch(let f):
            for code in [f.from, f.to] where !isIATA(code) || !knownAirport(code) {
                bad.append(L("모르는 공항 코드예요: \(code)"))
            }
            if f.from == f.to { bad.append(L("출발지와 도착지가 같아요")) }
            // The depart day is local midnight, so a flight today is still fine.
            when(f.depart, notBefore: Calendar.current.startOfDay(for: now))
            if let back = f.returnDate {
                when(back, notBefore: Calendar.current.startOfDay(for: now))
                if back < f.depart { bad.append(L("돌아오는 날이 가는 날보다 앞이에요")) }
            }
            if !(1...9).contains(f.adults) { bad.append(L("인원은 1명에서 9명까지예요")) }
        case .goalCreate(let g):
            if g.everyMinutes < 60 { bad.append(L("맡긴 일은 60분보다 자주 확인할 수 없어요")) }
        default: break
        }
        return bad.map { Concern(kind: .schema, message: $0, blocking: true) }
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    static func isPhone(_ s: String) -> Bool {
        s.range(of: #"^\+?[0-9][0-9 \-]{6,18}[0-9]$"#, options: .regularExpression) != nil
    }

    static func isIATA(_ s: String) -> Bool { s.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }

    // MARK: Recipient provenance

    /// Strict: only an address the owner typed, a contact found from a typed name, the pointed mail's From or the
    /// owner's own profile goes through. `.ownerWords` is a claim, so it is checked against the addresses actually in
    /// the words (whole addresses, so "im@a.com" does not pass on "kim@a.com"); one that is not there is "unknown" and
    /// must be retyped like one read from a mail body. `.contact` and `.pointedMail` are set by the app's own lookups
    /// (never by the model), so the guard trusts them.
    static func provenance(_ recipients: [Recipient], ownerWords: String) -> [Concern] {
        let typed = typedAddresses(ownerWords)
        return recipients.compactMap { r in
            switch r.provenance {
            case .contact, .pointedMail, .ownerProfile: return nil
            case .ownerWords:
                if typed.contains(normalized(r.address)) { return nil }
                return Concern(kind: .provenance,
                               message: L("어디서 온 주소인지 확인할 수 없어요. 직접 다시 입력해 주세요: \(r.address)"),
                               blocking: true)
            case .untrusted:
                return Concern(kind: .provenance,
                               message: L("이 주소는 받은 메일에서 나왔어요. 직접 다시 입력해 주세요: \(r.address)"),
                               blocking: true)
            }
        }
    }

    private static let typedEmail = regex(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#)
    private static let typedPhone = regex(#"\+?[0-9][0-9 \-]{6,18}[0-9]"#)

    /// Emails lowercased, phone numbers as digits only, so "010-1234-5678" typed matches "01012345678" proposed.
    static func typedAddresses(_ words: String) -> Set<String> {
        let ns = words as NSString
        let all = NSRange(location: 0, length: ns.length)
        return Set((typedEmail.matches(in: words, range: all) + typedPhone.matches(in: words, range: all))
            .map { normalized(ns.substring(with: $0.range)) })
    }

    static func normalized(_ address: String) -> String {
        let a = address.trimmingCharacters(in: .whitespaces)
        return a.contains("@") ? a.lowercased() : a.filter(\.isNumber)
    }

    // MARK: Secret patterns

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// "OTP" alone, not inside a Latin word ("hotpot"); Korean particles right after it ("OTP는") are fine.
    private static let otpKeyword = #"(?:인증|verification\s*code|보안코드|(?<![a-z])otp(?![a-z]))"#
    /// 4~8 digits within 20 non-digit characters of the keyword, before or after it. A longer digit run is not a code.
    private static let otp = regex(#"\#(otpKeyword)[^0-9]{0,20}(?<![0-9])[0-9]{4,8}(?![0-9])|(?<![0-9])[0-9]{4,8}(?![0-9])[^0-9]{0,20}\#(otpKeyword)"#)
    private static let rrn = regex(#"(?<![0-9])[0-9]{6}-?[1-4][0-9]{6}(?![0-9])"#)
    /// A value right after the word: an ASCII token of 4 or more, so "비밀번호 바꿔 줘" is not a hit.
    private static let password = regex(#"(?:비밀번호|패스워드|password)\s*(?:는|은|:|=)?\s*["']?[A-Za-z0-9!@#$%^&*_+.\-]{4,}"#)
    private static let apiKey = try! NSRegularExpression(pattern:
        #"sk-[A-Za-z0-9_\-]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_\-]{30,}"#)
    /// Digit runs where single spaces or dashes may sit between digits ("4111 1111-1111 1111").
    private static let digitRun = regex(#"[0-9]+(?:[ \-][0-9]+)*"#)
    private static let account = regex(#"(?<![0-9])[0-9]{2,6}-[0-9]{2,6}-[0-9]{2,8}(?![0-9])|(?<![0-9])[0-9]{10,14}(?![0-9])"#)
    private static let transferWord = regex("송금|입금|이체")

    private static func hit(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Outbound text only. Every hit but the account warning blocks: a secret must never leave in the owner's name.
    static func secrets(in text: String) -> [Concern] {
        var out: [Concern] = []
        func block(_ m: String) { out.append(Concern(kind: .secret, message: m, blocking: true)) }
        if hit(otp, text) { block(L("인증번호처럼 보이는 숫자가 있어서 보낼 수 없어요")) }
        if hasCardNumber(text) { block(L("카드번호처럼 보이는 숫자가 있어서 보낼 수 없어요")) }
        if hit(rrn, text) { block(L("주민등록번호처럼 보이는 숫자가 있어서 보낼 수 없어요")) }
        if hit(password, text) { block(L("비밀번호가 들어 있어서 보낼 수 없어요")) }
        if hit(apiKey, text) { block(L("API 키처럼 보이는 값이 있어서 보낼 수 없어요")) }
        if hit(account, text) && hit(transferWord, text) {
            out.append(Concern(kind: .secret, message: L("계좌번호와 송금 이야기가 있어요. 계좌가 맞는지 꼭 확인해 주세요"), blocking: false))
        }
        return out
    }

    /// Any 13~19 digit span inside a run of space/dash separated groups that passes Luhn. Sub-spans are tried so an
    /// order number glued in front ("주문 123 4111-1111-1111-1111") does not hide the card.
    static func hasCardNumber(_ text: String) -> Bool {
        let ns = text as NSString
        for m in digitRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = ns.substring(with: m.range).split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            for i in groups.indices {
                var digits = ""
                for g in groups[i...] {
                    digits += g
                    if digits.count > 19 { break }
                    if digits.count >= 13 && luhn(digits) { return true }
                }
            }
        }
        return false
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    // MARK: Forwarding received texts

    /// Blocks an outbound text that carries a 12+ character run copied from any received text line (SMS, notifications):
    /// those are never forwarded, even to an approved recipient. Whitespace is collapsed on both sides so re-wrapping
    /// does not hide a copy.
    /// ponytail: every 12-character window of every line is a substring search (lines x length x outbound); fine for a
    /// few KB of texts, switch to a rolling hash set if received texts grow large.
    static func forwarding(_ outbound: [String], receivedTexts: [String]) -> [Concern] {
        let sent = outbound.map(collapse).joined(separator: "\n")
        guard !sent.isEmpty else { return [] }
        for text in receivedTexts {
            for line in text.split(whereSeparator: \.isNewline) {
                let chars = Array(collapse(String(line)))
                guard chars.count >= forwardRun else { continue }
                for start in 0...(chars.count - forwardRun)
                where sent.contains(String(chars[start..<start + forwardRun])) {
                    return [Concern(kind: .secret, message: L("받은 문자 내용을 그대로 보낼 수는 없어요"), blocking: true)]
                }
            }
        }
        return []
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
