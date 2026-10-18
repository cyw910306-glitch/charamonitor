import XCTest
@testable import DogMonitor

/// A scripted server that answers in order: each send gets the next reply, nil drops the connection (receive then
/// returns empty, as a closed socket does). Replies arrive in small chunks so multi-line replies come split.
final class FakeWire: IMAPTransport {
    private var replies: [String?]
    private(set) var sent: [String] = []
    private(set) var sentData: [Data] = []
    private var out: [Data] = []
    var closed = false

    init(_ greeting: String, _ replies: [String?]) {
        self.replies = replies
        queue(greeting)
    }

    private func queue(_ s: String) {
        let b = Array(s.utf8)
        stride(from: 0, to: b.count, by: 5).forEach { out.append(Data(b[$0..<min($0 + 5, b.count)])) }
    }

    func send(_ data: Data) async throws {
        sent.append(String(decoding: data, as: UTF8.self))
        sentData.append(data)
        guard !replies.isEmpty, let r = replies.removeFirst() else { replies = []; out = []; return }
        queue(r)
    }

    func receive() async throws -> Data { out.isEmpty ? Data() : out.removeFirst() }
    func close() { closed = true }
}

final class MailSenderTests: XCTestCase {
    static let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let now = Date(timeIntervalSince1970: 1_791_162_000)   // 2026-10-05 01:00:00 UTC
    static let gmail = MailAccount(preset: .gmail, host: "imap.gmail.com", port: 993, user: "me@gmail.com", on: true)
    static let naver = MailAccount(preset: .naver, host: "imap.naver.com", port: 993, user: "kim", on: true)
    static let ehlo = "250-smtp.gmail.com at your service\r\n250-SIZE 35882577\r\n250-AUTH LOGIN PLAIN XOAUTH2\r\n250 SMTPUTF8\r\n"
    static let draft = MailDraft(accountID: nil, to: [Recipient(name: "김부장", address: "kim@naver.com", provenance: .contact)],
                                 cc: [Recipient(name: nil, address: "lee@daum.net", provenance: .ownerWords)],
                                 subject: "회의 시간 변경", body: "안녕하세요.\n10시로 미뤄요.")

    /// A sender wired to scripted servers; `imap` stays nil unless the sent copy is saved.
    func sender(_ smtp: FakeWire?, imap: FakeWire? = nil, opened: @escaping (String, Int) -> Void = { _, _ in },
                imapOpened: @escaping () -> Void = {}) -> MailSender {
        var s = MailSender()
        s.connect = { h, p in
            opened(h, p)
            guard let smtp else { throw IMAPError.network("offline") }
            return smtp
        }
        s.connectIMAP = { _ in
            imapOpened()
            guard let imap else { throw IMAPError.network("offline") }
            return imap
        }
        return s
    }

    func send(_ s: MailSender, _ a: MailAccount = MailSenderTests.gmail, draft: MailDraft = MailSenderTests.draft, inReplyTo: String? = nil) async -> MailSendResult {
        await s.send(draft: draft, from: a, password: "app-pw", messageID: Self.seed, inReplyTo: inReplyTo, now: Self.now)
    }

    // MARK: Message

    func testWholeMessageBytes() {
        let m = MailMessage.build(from: "me@gmail.com", fromName: "원창연", to: Self.draft.to, cc: [], subject: Self.draft.subject,
                                  body: Self.draft.body, messageID: MailMessage.messageID(seed: Self.seed, from: "me@gmail.com"),
                                  inReplyTo: nil, date: Self.now, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!)
        XCTAssertEqual(String(decoding: m, as: UTF8.self), """
        Date: Mon, 5 Oct 2026 10:00:00 +0900\r
        From: =?UTF-8?B?7JuQ7LC97Jew?= <me@gmail.com>\r
        To: =?UTF-8?B?6rmA67aA7J6l?= <kim@naver.com>\r
        Subject: =?UTF-8?B?7ZqM7J2YIOyLnOqwhCDrs4Dqsr0=?=\r
        Message-ID: <11111111-2222-3333-4444-555555555555@gmail.com>\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        7JWI64WV7ZWY7IS47JqULg0KMTDsi5zroZwg66+466SE7JqULg==\r

        """)
        // Read back the way the IMAP side reads mail.
        let h = IMAPParse.headers(m)
        XCTAssertEqual(IMAPParse.sender(h["from"]!), "원창연")
        XCTAssertEqual(IMAPParse.date(h["date"]!), Self.now)
    }

    func testKoreanSubjectRoundTripsInShortWords() {
        let subject = "다음 주 화요일 오후 세 시 회의는 본사 3층 대회의실에서 진행합니다 🙂 참석 여부를 알려 주세요"
        let header = "Subject: " + MailMessage.text(subject)
        let lines = header.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(lines.count, 2)
        for word in header.split(whereSeparator: { $0 == " " || $0 == "\r\n" }) where word.hasPrefix("=?") {
            XCTAssertLessThanOrEqual(word.count, 75, String(word))
        }
        lines.forEach { XCTAssertLessThanOrEqual($0.utf8.count, 78, $0) }
        XCTAssertEqual(IMAPParse.headers(Data((header + "\r\n").utf8))["subject"], subject)
        // Short ASCII stays readable; a line break never reaches the header.
        XCTAssertEqual(MailMessage.text("Lunch?"), "Lunch?")
        XCTAssertFalse(MailMessage.text("hi\r\nBcc: evil@x.com").contains("\r\n"))
        XCTAssertEqual(MailMessage.mailbox("Kim \"Boss\"", "k@x.com"), #""Kim \"Boss\"" <k@x.com>"#)
    }

    func testBase64BodyLinesAreAtMost76() {
        let body = String(repeating: "가나다라마바사 abc\n", count: 120)
        let m = String(decoding: MailMessage.build(from: "me@gmail.com", fromName: nil, to: Self.draft.to, cc: [], subject: "s",
                                                   body: body, messageID: "<x@y>", inReplyTo: nil, date: Self.now), as: UTF8.self)
        let parts = m.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        let lines = parts[1].components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(lines.count, 10)
        lines.forEach { XCTAssertLessThanOrEqual($0.count, 76) }
        XCTAssertFalse(m.contains("\n") && m.replacingOccurrences(of: "\r\n", with: "").contains("\n"))   // CRLF only
        let decoded = String(decoding: Data(base64Encoded: lines.joined())!, as: UTF8.self)
        XCTAssertEqual(decoded, body.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testReplyHeadersAndStableMessageID() {
        func build(_ parent: String?) -> String {
            String(decoding: MailMessage.build(from: "me@gmail.com", fromName: nil, to: Self.draft.to, cc: Self.draft.cc,
                                               subject: "Re: 견적", body: "네", messageID: MailMessage.messageID(seed: Self.seed, from: "me@gmail.com"),
                                               inReplyTo: parent, date: Self.now), as: UTF8.self)
        }
        let m = build("CAF=abc@mail.gmail.com")
        XCTAssertTrue(m.contains("\r\nIn-Reply-To: <CAF=abc@mail.gmail.com>\r\nReferences: <CAF=abc@mail.gmail.com>\r\n"))
        XCTAssertTrue(m.contains("\r\nCc: lee@daum.net\r\n"))
        XCTAssertEqual(build("<CAF=abc@mail.gmail.com>"), m)
        XCTAssertFalse(build("x\r\nBcc: evil@x.com").contains("In-Reply-To"))
        XCTAssertEqual(MailMessage.messageID(seed: Self.seed, from: "kim@naver.com"), "<11111111-2222-3333-4444-555555555555@naver.com>")
    }

    func testDotStuffing() {
        XCTAssertEqual(String(decoding: MailMessage.dotStuffed(Data(".a\r\nb\r\n.\r\n..c\r\nd.e\r\n".utf8)), as: UTF8.self),
                       "..a\r\nb\r\n..\r\n...c\r\nd.e\r\n")
    }

    func testEndpointsAndAddresses() {
        XCTAssertEqual(MailSender.smtpEndpoint(for: .gmail)?.host, "smtp.gmail.com")
        XCTAssertEqual(MailSender.smtpEndpoint(for: .naver)?.host, "smtp.naver.com")
        XCTAssertEqual(MailSender.smtpEndpoint(for: .daum)?.host, "smtp.daum.net")
        XCTAssertEqual(MailSender.smtpEndpoint(for: .daum)?.port, 465)
        XCTAssertNil(MailSender.smtpEndpoint(for: .icloud))
        XCTAssertNil(MailSender.smtpEndpoint(for: .custom))
        XCTAssertEqual(MailSender.address(of: Self.naver), "kim@naver.com")
        XCTAssertTrue(MailMessage.isPlainAddress("a.b+c@x.co.kr"))
        for bad in ["a@b", "ab.com", "a b@x.com", "a@x.com>\r\nRCPT TO:<b@y.com", "김@x.com", "a@@x.com"] {
            XCTAssertFalse(MailMessage.isPlainAddress(bad), bad)
        }
    }

    // MARK: Session

    func testHappyPathBytes() async {
        let smtp = FakeWire("220 smtp.gmail.com ESMTP ready\r\n",
                            [Self.ehlo, "235 2.7.0 Accepted\r\n", "250 2.1.0 OK\r\n", "250 2.1.5 OK\r\n", "250 2.1.5 OK\r\n",
                             "354 Go ahead\r\n", "250 2.0.0 OK 1728 queued\r\n", "221 2.0.0 closing\r\n"])
        var endpoint = "", imapOpened = false
        let s = sender(smtp, opened: { endpoint = "\($0):\($1)" }, imapOpened: { imapOpened = true })
        let result = await send(s)
        XCTAssertEqual(result, .sent("<11111111-2222-3333-4444-555555555555@gmail.com>"))
        XCTAssertEqual(endpoint, "smtp.gmail.com:465")
        let message = MailMessage.build(from: "me@gmail.com", fromName: nil, to: Self.draft.to, cc: Self.draft.cc,
                                        subject: Self.draft.subject, body: Self.draft.body,
                                        messageID: "<11111111-2222-3333-4444-555555555555@gmail.com>", inReplyTo: nil, date: Self.now)
        XCTAssertEqual(smtp.sent, ["EHLO [127.0.0.1]\r\n",
                                   "AUTH PLAIN AG1lQGdtYWlsLmNvbQBhcHAtcHc=\r\n",
                                   "MAIL FROM:<me@gmail.com>\r\n",
                                   "RCPT TO:<kim@naver.com>\r\n",
                                   "RCPT TO:<lee@daum.net>\r\n",
                                   "DATA\r\n",
                                   String(decoding: message, as: UTF8.self) + ".\r\n",
                                   "QUIT\r\n"])
        XCTAssertTrue(smtp.closed)
        XCTAssertFalse(imapOpened)   // Gmail files its own sent copy
    }

    func testAuthLoginWhenPlainIsNotOffered() async {
        let smtp = FakeWire("220 smtp.naver.com ESMTP\r\n",
                            ["250-smtp.naver.com\r\n250-AUTH=LOGIN\r\n250 8BITMIME\r\n", "334 VXNlcm5hbWU6\r\n", "334 UGFzc3dvcmQ6\r\n",
                             "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "250 ok\r\n", "354 go\r\n", "250 ok\r\n", "221 bye\r\n"])
        let result = await send(sender(smtp), Self.naver)
        XCTAssertEqual(result, .sent("<11111111-2222-3333-4444-555555555555@naver.com>"))
        XCTAssertEqual(Array(smtp.sent[1...4]), ["AUTH LOGIN\r\n", "a2lt\r\n", "YXBwLXB3\r\n", "MAIL FROM:<kim@naver.com>\r\n"])
    }

    func testWrongAppPassword() async {
        let smtp = FakeWire("220 hi\r\n", [Self.ehlo, "535-5.7.8 Username and Password not accepted.\r\n535 5.7.8 https://support.google.com\r\n"])
        guard case .failed(let why, let retry) = await send(sender(smtp)) else { return XCTFail() }
        XCTAssertTrue(why.contains("앱 비밀번호를 확인해 주세요"), why)
        XCTAssertFalse(retry)
        XCTAssertFalse(smtp.sent.contains { $0.hasPrefix("MAIL") })
    }

    func testRefusedRecipientStopsBeforeData() async {
        var imapOpened = false
        let smtp = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "550 5.1.1 No such user\r\n", "221 bye\r\n"])
        guard case .failed(let why, let retry) = await send(sender(smtp, imapOpened: { imapOpened = true }), Self.naver) else { return XCTFail() }
        XCTAssertTrue(why.contains("받는 주소를 확인해 주세요"), why)
        XCTAssertTrue(why.contains("lee@daum.net"), why)
        XCTAssertFalse(retry)
        XCTAssertFalse(smtp.sent.contains("DATA\r\n"))
        XCTAssertFalse(imapOpened)   // APPEND only after the final 250
    }

    func testDropAfterDataIsUnknownAndBeforeIsRetryable() async {
        let late = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "250 ok\r\n", "354 go\r\n", nil])
        guard case .unknown(let why) = await send(sender(late)) else { return XCTFail() }
        XCTAssertTrue(why.contains("보낸메일함"), why)

        let early = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", nil])
        guard case .failed(_, true) = await send(sender(early)) else { return XCTFail() }
        guard case .failed(_, true) = await send(sender(nil)) else { return XCTFail() }   // no connection at all

        let busy = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", "451 4.3.0 try later\r\n"])
        guard case .failed(_, true) = await send(sender(busy)) else { return XCTFail() }
    }

    func testBodyLineStartingWithDotIsStuffedOnTheWire() async {
        let smtp = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "354 go\r\n", "250 ok\r\n", "221 bye\r\n"])
        var d = Self.draft
        d.cc = []
        d.body = "첫 줄\n.\n.점으로 시작"
        let result = await send(sender(smtp), draft: d)
        XCTAssertEqual(result, .sent("<11111111-2222-3333-4444-555555555555@gmail.com>"))
        let wire = smtp.sent[5]
        XCTAssertTrue(wire.hasSuffix("\r\n.\r\n"))
        XCTAssertEqual(wire.components(separatedBy: "\r\n.\r\n").count, 2)   // the end marker is the only lone dot
        let body = wire.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n.\r\n", with: "")
            .replacingOccurrences(of: "\r\n", with: "")
        XCTAssertEqual(Data(base64Encoded: body).map { String(decoding: $0, as: UTF8.self) }, "첫 줄\r\n.\r\n.점으로 시작")
    }

    func testNaverSavesASeenCopyInTheSentFolder() async {
        let smtp = FakeWire("220 hi\r\n", [Self.ehlo, "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "250 ok\r\n", "354 go\r\n", "250 ok\r\n", "221 bye\r\n"])
        let imap = FakeWire("* OK IMAP ready\r\n",
                            ["a1 OK LOGIN completed\r\n",
                             "* LIST (\\HasNoChildren) \"/\" INBOX\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Messages\"\r\na2 OK LIST done\r\n",
                             "+ Ready for literal data\r\n", "a3 OK APPEND completed\r\n", "* BYE\r\na4 OK LOGOUT\r\n"])
        let result = await send(sender(smtp, imap: imap), Self.naver)
        XCTAssertEqual(result, .sent("<11111111-2222-3333-4444-555555555555@naver.com>"))
        let message = MailMessage.build(from: "kim@naver.com", fromName: nil, to: Self.draft.to, cc: Self.draft.cc,
                                        subject: Self.draft.subject, body: Self.draft.body,
                                        messageID: "<11111111-2222-3333-4444-555555555555@naver.com>", inReplyTo: nil, date: Self.now)
        XCTAssertEqual(imap.sent, ["a1 LOGIN \"kim\" \"app-pw\"\r\n", "a2 LIST \"\" \"*\"\r\n",
                                   "a3 APPEND \"Sent Messages\" (\\Seen) {\(message.count)}\r\n",
                                   String(decoding: message, as: UTF8.self) + "\r\n", "a4 LOGOUT\r\n"])
        XCTAssertTrue(imap.closed)
    }

    func testSentFolderByFlagThenByName() {
        func list(_ s: String) -> [IMAPResponse] { s.components(separatedBy: "\n").map { IMAPResponse(text: $0) } }
        XCTAssertEqual(SentCopy.sentFolder(list("* LIST () \"/\" Sent\n* LIST (\\Sent) \"/\" \"보낸 편지\"")), "보낸 편지")
        XCTAssertEqual(SentCopy.sentFolder(list("* LIST () \"/\" INBOX\n* LIST () \".\" Sent")), "Sent")
        XCTAssertNil(SentCopy.sentFolder(list("* LIST () \"/\" INBOX")))
    }
}
