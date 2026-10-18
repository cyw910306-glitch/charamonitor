import XCTest
@testable import DogMonitor

/// AgentGuard: schema, recipient provenance, secret patterns with near misses, forwarding, caps and expiry.
final class AgentGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func mail(_ body: String, subject: String = "안내",
                      to: [Recipient] = [Recipient(name: "Bob", address: "bob@example.com", provenance: .contact)]) -> AgentAction {
        .mailSend(MailDraft(to: to, subject: subject, body: body))
    }

    private func check(_ a: AgentAction, origin: Origin = .chat, proposedAt: Date? = nil, words: String = "",
                       counts: AgentGuard.Counts = .init(), received: [String] = [],
                       airport: @escaping (String) -> Bool = { _ in true }) -> [Concern] {
        AgentGuard.check(a, origin: origin, proposedAt: proposedAt ?? now, now: now, ownerWords: words,
                         todayCounts: counts, receivedTexts: received, knownAirport: airport)
    }

    private func kinds(_ c: [Concern]) -> [Concern.Kind] { c.map(\.kind) }
    private func secretHits(_ text: String) -> [Concern] { AgentGuard.secrets(in: text) }

    // MARK: Clean pass

    func testCleanProposalsPass() {
        XCTAssertEqual(check(mail("내일 회의는 10시로 미룰게요. 2026년 10월 16일 오후 3시에 봬요.")), [])
        XCTAssertEqual(check(.eventAdd(EventDraft(title: "치과", start: now + day, end: now + day + 3600))), [])
        XCTAssertEqual(check(.shopSearch(query: "하기스", store: nil)), [])
        XCTAssertEqual(check(.flightSearch(FlightQuery(from: "GMP", to: "CJU", depart: now + 30 * day, returnDate: now + 33 * day))), [])
    }

    // MARK: Schema

    func testEmailShape() {
        let bad = Recipient(name: nil, address: "bob@", provenance: .contact)
        XCTAssertEqual(kinds(check(mail("안녕", to: [bad]))), [.schema])
        XCTAssertEqual(kinds(check(mail("안녕", to: []))), [.schema])
        XCTAssertTrue(AgentGuard.isEmail("kim.bujang+work@company.co.kr"))
        XCTAssertFalse(AgentGuard.isEmail("kim bujang@company.com"))
        XCTAssertFalse(AgentGuard.isEmail("kim@localhost"))
        // Messages may go to a phone number.
        let phone = Recipient(name: "엄마", address: "010-1234-5678", provenance: .contact)
        XCTAssertEqual(check(.messagePrepare(to: [phone], body: "곧 가요")), [])
    }

    func testDates() {
        func ev(_ s: Date, _ e: Date) -> [Concern.Kind] { kinds(check(.eventAdd(EventDraft(title: "x", start: s, end: e)))) }
        XCTAssertEqual(ev(now - 60, now + 3600), [.schema])                 // past
        XCTAssertEqual(ev(now + 401 * day, now + 401 * day + 60), [.schema]) // too far
        XCTAssertEqual(ev(now + 399 * day, now + 399 * day + 60), [])
        XCTAssertEqual(ev(now + 3600, now + 3600), [.schema])               // end not after start
        XCTAssertEqual(ev(now + 3600, now + 1800), [.schema])
        XCTAssertEqual(kinds(check(.reminderAdd(ReminderDraft(title: "x", due: now - 1)))), [.schema])
        XCTAssertEqual(check(.reminderAdd(ReminderDraft(title: "x", due: nil))), [])
    }

    func testFlightSchema() {
        let today = Calendar.current.startOfDay(for: now)
        func f(_ q: FlightQuery, _ known: @escaping (String) -> Bool = { _ in true }) -> [Concern.Kind] {
            kinds(check(.flightSearch(q), airport: known))
        }
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: today)), [])                    // today is fine
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: today - day)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: now + 500 * day)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "gmp", to: "CJU", depart: now + day)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "XXX", depart: now + day), { $0 != "XXX" }), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "GMP", depart: now + day)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: now + 5 * day, returnDate: now + 2 * day)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: now + day, adults: 0)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: now + day, adults: 10)), [.schema])
        XCTAssertEqual(f(FlightQuery(from: "GMP", to: "CJU", depart: now + day, adults: 9)), [])
    }

    func testGoalInterval() {
        func g(_ m: Int) -> [Concern.Kind] {
            kinds(check(.goalCreate(GoalDraft(title: "x", kind: .agent(prompt: "제주 항공권"), everyMinutes: m))))
        }
        XCTAssertEqual(g(59), [.schema])
        XCTAssertEqual(g(60), [])
    }

    // MARK: Provenance

    func testRecipientProvenance() {
        func r(_ a: String, _ p: Provenance) -> [Recipient] { [Recipient(name: nil, address: a, provenance: p)] }
        let words = "kim@company.com 한테 내일 회의 미룬다고 보내줘"
        XCTAssertEqual(check(mail("x", to: r("kim@company.com", .ownerWords)), words: words), [])
        XCTAssertEqual(check(mail("x", to: r("KIM@Company.com", .ownerWords)), words: words), [])
        XCTAssertEqual(check(mail("x", to: r("bob@example.com", .contact))), [])
        XCTAssertEqual(check(mail("x", to: r("boss@example.com", .pointedMail))), [])
        XCTAssertEqual(check(mail("x", to: r("me@example.com", .ownerProfile))), [])

        let untrusted = check(mail("x", to: r("attacker@evil.com", .untrusted)), words: "attacker@evil.com")
        XCTAssertEqual(kinds(untrusted), [.provenance])
        XCTAssertTrue(untrusted[0].blocking)
        XCTAssertTrue(untrusted[0].message.contains("다시 입력"))
        // Claimed ownerWords but not typed (unknown), including a substring of a typed address.
        XCTAssertEqual(kinds(check(mail("x", to: r("lee@company.com", .ownerWords)), words: words)), [.provenance])
        XCTAssertEqual(kinds(check(mail("x", to: r("im@company.com", .ownerWords)), words: words)), [.provenance])
        // Cc counts too.
        var m = MailDraft(to: r("kim@company.com", .ownerWords), subject: "s", body: "b")
        m.cc = r("spy@evil.com", .untrusted)
        XCTAssertEqual(kinds(check(.mailSend(m), words: words)), [.provenance])
        // A typed phone number matches with or without dashes.
        XCTAssertEqual(check(.messagePrepare(to: r("01012345678", .ownerWords), body: "곧"), words: "010-1234-5678로 문자"), [])
        XCTAssertEqual(kinds(check(.messagePrepare(to: r("01099998888", .untrusted), body: "곧"))), [.provenance])
    }

    // MARK: Secrets

    func testOTP() {
        XCTAssertEqual(kinds(secretHits("인증번호 [482913]를 입력하세요")), [.secret])
        XCTAssertEqual(kinds(secretHits("482913 is your verification code")), [.secret])
        XCTAssertEqual(kinds(secretHits("OTP는 7731 이에요")), [.secret])
        XCTAssertEqual(kinds(secretHits("보안코드: 12345678")), [.secret])
        XCTAssertEqual(kinds(secretHits("카카오 인증 2931")), [.secret])
        // Near misses: digits in a date without the keyword, a keyword with no code, a long number, "hotpot".
        XCTAssertEqual(secretHits("회의는 20261016 또는 2026-10-16 오후 3시"), [])
        XCTAssertEqual(secretHits("본인 인증은 직접 해 주세요"), [])
        XCTAssertEqual(secretHits("hotpot 1234 가게"), [])
        XCTAssertEqual(secretHits("인증서 발급 번호 1234567890123 확인"), [])
    }

    func testCardNumberNeedsLuhn() {
        XCTAssertTrue(AgentGuard.luhn("4111111111111111"))
        XCTAssertFalse(AgentGuard.luhn("4111111111111112"))
        XCTAssertEqual(kinds(secretHits("카드 4111 1111 1111 1111 로 결제")), [.secret])
        XCTAssertEqual(kinds(secretHits("4111-1111-1111-1111")), [.secret])
        XCTAssertEqual(kinds(secretHits("주문 123 5555-5555-5555-4444 이거")), [.secret])  // glued prefix
        XCTAssertEqual(kinds(secretHits("378282246310005")), [.secret])                  // 15-digit Amex
        // An order number of card length that fails Luhn, a phone number, a short number.
        XCTAssertEqual(secretHits("주문번호 2026100512345678 배송 중"), [])
        XCTAssertEqual(secretHits("연락처 010-1234-5678"), [])
        XCTAssertEqual(secretHits("4111 1111 1111"), [])
    }

    func testResidentNumber() {
        XCTAssertEqual(kinds(secretHits("주민번호 900101-1234567")), [.secret])
        XCTAssertEqual(kinds(secretHits("9001014234567")).contains(.secret), true)
        XCTAssertEqual(secretHits("900101-5234567"), [])   // 7th digit outside 1~4
        XCTAssertEqual(secretHits("90010-1234567"), [])    // too short
    }

    func testPasswordValue() {
        XCTAssertEqual(kinds(secretHits("와이파이 비밀번호는 hunter2!! 야")), [.secret])
        XCTAssertEqual(kinds(secretHits("비밀번호: abcd1234")), [.secret])
        XCTAssertEqual(kinds(secretHits("password = s3cret99")), [.secret])
        XCTAssertEqual(secretHits("비밀번호 바꿔 줘"), [])
        XCTAssertEqual(secretHits("비밀번호를 재설정해 주세요"), [])
    }

    func testAPIKeys() {
        for key in ["sk-proj-abcdefghijklmnop1234", "AKIAIOSFODNN7EXAMPLE", "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                    "AIzaSyA1234567890abcdefghijklmnopqrstu"] {
            XCTAssertEqual(kinds(secretHits("키는 \(key) 입니다")), [.secret], key)
        }
        XCTAssertEqual(secretHits("SK-II 에센스 사 줘"), [])
        XCTAssertEqual(secretHits("sk-short"), [])
        XCTAssertEqual(secretHits("AKIA 라는 단어"), [])
    }

    func testAccountWithTransferIsAWarning() {
        let w = secretHits("입금 계좌는 110-123-456789 입니다")
        XCTAssertEqual(kinds(w), [.secret])
        XCTAssertFalse(w[0].blocking)
        XCTAssertEqual(secretHits("계좌 110-123-456789"), [])
        XCTAssertEqual(secretHits("송금은 내가 할게"), [])
    }

    func testSecretsCheckSubjectAndOnlyOutbound() {
        XCTAssertEqual(kinds(check(mail("본문", subject: "인증번호 482913"))), [.secret])
        XCTAssertEqual(kinds(check(.kakaoPrepare(body: "카드 4111 1111 1111 1111"))), [.secret])
        // Memory stays on the Mac; it is not an outbound text.
        XCTAssertEqual(check(.memoryAdd(key: "카드", value: "4111 1111 1111 1111")), [])
    }

    // MARK: Forwarding

    func testForwardingReceivedTextsIsBlocked() {
        let sms = ["[Web발신]\n고객님의 택배가 내일 오전 도착 예정입니다. 운송장 5512", "엄마: 저녁 먹었어?"]
        let fwd = check(mail("엄마가 보낸 거: 고객님의 택배가 내일 오전 도착 예정입니다"), received: sms)
        XCTAssertEqual(kinds(fwd), [.secret])
        XCTAssertTrue(fwd[0].blocking)
        // Re-wrapped whitespace still counts.
        XCTAssertEqual(kinds(check(mail("고객님의  택배가\n내일 오전"), received: sms)), [.secret])
        // Under 12 characters in common is fine.
        XCTAssertEqual(check(mail("택배가 내일 와요. 저녁 먹었어?"), received: sms), [])
        XCTAssertEqual(check(.eventAdd(EventDraft(title: "고객님의 택배가 내일 오전 도착", start: now + day, end: now + day + 60)),
                             received: sms), [])
    }

    // MARK: Web step addresses

    func testReadableURLKeepsSeparatorsEncoded() {
        // 한글 and unreserved characters become readable; separators the server reads stay exactly as sent.
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/%ED%95%9C%EA%B8%80?q=%2F%26x%3D1%25%2B%3F%23"),
                       "https://a.com/한글?q=%2F%26x%3D1%25%2B%3F%23")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/%7e%41%2d%5F%2E"), "https://a.com/~A-_.")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/a%20b%3Ac"), "https://a.com/a%20b%3Ac")
        // Not one valid character: kept as written (bad byte, cut sequence, overlong "/", a lone %).
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/%FF%41%ED%95%C0%AF%zz%"), "https://a.com/%FFA%ED%95%C0%AF%zz%")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/x?y=1"), "https://a.com/x?y=1")
    }

    func testHiddenCharactersAreShownAndBlocked() {
        // Raw bidi and control characters are written out; encoded ones stay encoded. Both block the step.
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/\u{202E}gpj.exe"), "https://a.com/⟦U+202E⟧gpj.exe")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/\u{85}\u{2066}x\u{200F}"), "https://a.com/⟦U+0085⟧⟦U+2066⟧x⟦U+200F⟧")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/%E2%80%AEx%00"), "https://a.com/%E2%80%AEx%00")
        for bad in ["https://a.com/\u{202E}x", "https://a.com/%E2%80%AE", "https://a.com/%e2%81%a6", "https://a.com/%0A",
                    "https://a.com/%C2%85", "https://a.com/\u{200E}", "https://a.com/%E3%80%80"] {
            XCTAssertNotNil(ActionCopy.urlProblem(bad), bad)
        }
        XCTAssertNil(ActionCopy.urlProblem("https://a.com/%ED%95%9C%EA%B8%80?q=a%20b&x=%2F"))
        XCTAssertEqual(ActionCopy.visible("a\u{200F}b\nc"), "a⟦U+200F⟧b⟦U+000A⟧c")
        XCTAssertEqual(ActionCopy.host("https://good.com%2F@evil.com/x"), "evil.com")
    }

    func testEncodedHostIsNeverALookalike() {
        // Foundation decodes %D0%B0 in URL.host to a Cyrillic а; WebKit opens the punycode name. Same for a page href.
        let page = "https://%D0%B0pple.com/"
        let href = URL(string: "//%D0%B0pple.com/x", relativeTo: URL(string: "https://a.com/")!)!.absoluteString
        for s in [page, href] {
            XCTAssertEqual(ActionCopy.host(s), "xn--pple-43d.com", s)
            XCTAssertFalse(ActionCopy.readableURL(s).contains("а"), s)
            XCTAssertNotNil(ActionCopy.urlProblem(s), s)
        }
        XCTAssertEqual(ActionCopy.readableURL(page), page)
        XCTAssertEqual(ActionCopy.readableURL("https://%ED%95%9C@a.com/%ED%95%9C"), "https://%ED%95%9C@a.com/한")
        XCTAssertNotNil(ActionCopy.urlProblem("https://%E2%80%AE@a.com/"))
        // One slash or a backslash: Foundation finds no host, WebKit still opens one. Still not decoded, still blocked.
        for s in ["https:/%D0%B0pple.com/", "https:\\\\%D0%B0pple.com/", "https://x@%D0%B0pple.com:443/"] {
            XCTAssertFalse(ActionCopy.readableURL(s).contains("а"), s)
            XCTAssertFalse(ActionCopy.host(s).contains("а"), s)
            XCTAssertNotNil(ActionCopy.urlProblem(s), s)
        }
        // %XX in the name part only: the host is plain, so it is the "name@" that refuses it, not the encoded host.
        XCTAssertEqual(ActionCopy.urlProblem("https://a%40b@a.com/"), ActionCopy.urlProblem("https://ab@a.com/"))
        XCTAssertNil(ActionCopy.urlProblem("https://аpple.com/"))  // raw Unicode: Foundation already made it punycode
        XCTAssertEqual(ActionCopy.host("https://аpple.com/"), "xn--pple-43d.com")
    }

    func testBlankLookingCharactersAreHidden() {
        // Default ignorables, Hangul fillers and the braille blank show as ⟦U+XXXX⟧ raw, stay encoded, and refuse.
        XCTAssertEqual(ActionCopy.readableURL("https://shop.com/ca\u{3164}rt"), "https://shop.com/ca⟦U+3164⟧rt")
        XCTAssertEqual(ActionCopy.readableURL("https://shop.com/ca%E3%85%A4rt"), "https://shop.com/ca%E3%85%A4rt")
        XCTAssertEqual(ActionCopy.visible("a\u{2800}\u{115F}\u{1160}\u{FFA0}\u{180E}\u{FE0F}b"),
                       "a⟦U+2800⟧⟦U+115F⟧⟦U+1160⟧⟦U+FFA0⟧⟦U+180E⟧⟦U+FE0F⟧b")
        for bad in ["https://shop.com/ca%E3%85%A4rt", "https://shop.com/ca\u{3164}rt", "https://a.com/%E2%A0%80",
                    "https://a.com/%E1%85%9F", "https://a.com/%E1%85%A0", "https://a.com/%EF%BE%A0", "https://a.com/%CD%8F",
                    "https://a.com/%EF%B8%8F", "https://a.com/\u{2800}"] {
            XCTAssertEqual(ActionCopy.urlProblem(bad), ActionCopy.urlProblem("https://a.com/\u{200B}"), bad)
        }
        // A combining mark is not decoded: it would fold onto the letter before it.
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/x%CC%B8y"), "https://a.com/x%CC%B8y")
        XCTAssertEqual(ActionCopy.readableURL("https://a.com/%E0%A4%95%E0%A4%BE"), "https://a.com/का")  // spacing mark: read
        XCTAssertNil(ActionCopy.urlProblem("https://a.com/x%CC%B8y"))
    }

    func testAddressesParsedTwoWaysAreRefused() {
        // Foundation and WebKit (WHATWG) disagree on these hosts: a backslash, "name@", or not exactly "//".
        for bad in ["https://evil.com\\@good.com/", "https://good.com\\evil.com/", "https://user@evil.com/",
                    "https://good.com@evil.com/x", "https:evil.com/", "https:/evil.com/", "https:///evil.com/",
                    "https:\\\\evil.com/", "https:/\\evil.com/"] {
            XCTAssertNotNil(ActionCopy.urlProblem(bad), bad)
        }
        for good in ["https://shop.example.com/p/1?q=a@b#c", "https://a.com:8443/x/y@z", "https://аpple.com/",
                     "https://한글.com/경로", "http://a.com"] {
            XCTAssertNil(ActionCopy.urlProblem(good), good)
        }
    }

    func testLongURLsAreMarkedAndBlocked() {
        let base = "https://a.com/"
        let limit = base + String(repeating: "a", count: ActionCopy.urlLimit - base.count)
        XCTAssertNil(ActionCopy.urlProblem(limit))
        XCTAssertNotNil(ActionCopy.urlProblem(limit + "a"))
        // The card never cuts silently: the full length is shown, and readableURL itself keeps everything.
        let long = String(repeating: "b", count: ActionCopy.urlShown + 1)
        XCTAssertEqual(ActionCopy.shortened(long), String(repeating: "b", count: ActionCopy.urlShown) + "…(총 301자)")
        XCTAssertEqual(ActionCopy.shortened(String(long.dropLast())), String(long.dropLast()))
        XCTAssertEqual(ActionCopy.readableURL(limit + "a").count, ActionCopy.urlLimit + 1)
    }

    func testWebStepAddressesAreGuarded() {
        func step(_ kind: WebStep.Kind, page: String = "https://shop.example.com/p/1", value: String? = nil) -> AgentAction {
            .webStep(WebStep(kind: kind, pageURL: page, label: "담기", ref: kind == .open ? nil : "e1", signature: nil, value: value, why: "w"))
        }
        let long = "https://a.com/" + String(repeating: "a", count: ActionCopy.urlLimit)
        XCTAssertEqual(check(step(.open)), [])
        XCTAssertEqual(kinds(check(step(.open, page: long))), [.schema])
        XCTAssertTrue(check(step(.open, page: long)).allSatisfy(\.blocking))
        XCTAssertEqual(kinds(check(step(.click, value: "https://a.com/\u{202E}x"))), [.schema])
        XCTAssertEqual(check(step(.click, value: "https://shop.example.com/cart")), [])
        // Only the addresses the card shows: the page a click happens on is shown as its host.
        XCTAssertEqual(check(step(.click, page: long)), [])
        XCTAssertEqual(check(step(.type, value: "https://a.com/%E2%80%AE")), [])
    }

    // MARK: Caps and expiry

    func testDailyCaps() {
        XCTAssertEqual(kinds(check(mail("x"), counts: .init(mails: 20))), [.cap])
        XCTAssertEqual(check(mail("x"), counts: .init(mails: 19)), [])
        let ev = AgentAction.eventAdd(EventDraft(title: "x", start: now + day, end: now + day + 60))
        XCTAssertEqual(kinds(check(ev, counts: .init(eventsAndReminders: 30))), [.cap])
        XCTAssertEqual(kinds(check(.reminderDone(id: "r", title: "x"), counts: .init(eventsAndReminders: 30))), [.cap])
        XCTAssertEqual(check(ev, counts: .init(eventsAndReminders: 29)), [])
        let goal = AgentAction.goalCreate(GoalDraft(title: "x", kind: .agent(prompt: "p")))
        XCTAssertEqual(kinds(check(goal, counts: .init(activeGoals: 10))), [.cap])
        XCTAssertEqual(check(goal, counts: .init(activeGoals: 9)), [])
        // Caps are per kind: a full mail count does not stop an event.
        XCTAssertEqual(check(ev, counts: .init(mails: 99)), [])
        XCTAssertTrue(check(mail("x"), counts: .init(mails: 20))[0].blocking)
    }

    func testExpiry() {
        let ev = AgentAction.eventAdd(EventDraft(title: "x", start: now + day, end: now + day + 60))
        XCTAssertEqual(check(ev, proposedAt: now - 29 * 60), [])
        let old = check(ev, proposedAt: now - 31 * 60)
        XCTAssertEqual(kinds(old), [.expired])
        XCTAssertTrue(old[0].blocking)
        XCTAssertEqual(check(ev, origin: .background, proposedAt: now - 11 * 3600), [])
        XCTAssertEqual(kinds(check(ev, origin: .background, proposedAt: now - 13 * 3600)), [.expired])
    }

    /// Re-running on approval sees time move on: a proposal that passed can fail later.
    func testReguardOnApproval() {
        let start = now + 20 * 60
        let ev = AgentAction.eventAdd(EventDraft(title: "x", start: start, end: start + 3600))
        XCTAssertEqual(check(ev), [])
        let later = AgentGuard.check(ev, origin: .chat, proposedAt: now, now: now + 25 * 60, ownerWords: "",
                                     todayCounts: .init(), receivedTexts: [])
        XCTAssertEqual(kinds(later), [.schema])
    }
}
