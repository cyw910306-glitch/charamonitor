import XCTest
@testable import DogMonitor

/// A scripted IMAP server: answers each command from `script` (verb -> reply, "$T" = the command's tag), in small
/// chunks so literals and lines arrive split. Never a real connection.
final class FakeIMAP: IMAPTransport {
    var script: [String: String]
    var greeting = "* OK [CAPABILITY IMAP4rev1] ready\r\n"
    private(set) var sent: [String] = []
    private var out: [Data] = []
    var chunk = 7
    var closed = false

    init(_ script: [String: String]) {
        self.script = script
        queue(greeting)
    }

    private func queue(_ s: String) {
        let b = Array(s.utf8)
        stride(from: 0, to: b.count, by: chunk).forEach { out.append(Data(b[$0..<min($0 + chunk, b.count)])) }
    }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self)
        sent.append(line)
        let words = line.trimmingCharacters(in: .newlines).split(separator: " ")
        let tag = String(words[0])
        let verb = words[1] == "UID" ? "UID " + words[2] : String(words[1])
        queue((script[verb] ?? "$T OK done\r\n").replacingOccurrences(of: "$T", with: tag))
    }

    func receive() async throws -> Data { out.isEmpty ? Data() : out.removeFirst() }
    func close() { closed = true }
}

final class IMAPTests: XCTestCase {
    static let examine = "* 3 EXISTS\r\n* OK [UIDVALIDITY 77] UIDs valid\r\n* OK [UIDNEXT 105] Predicted next UID\r\n$T OK [READ-ONLY] EXAMINE completed\r\n"

    /// Header fields dated now (RFC 2822) unless told otherwise.
    static func header(_ from: String, _ subject: String, date: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date ?? f.string(from: Date()))\r\n\r\n"
    }

    static func fetchLine(seq: Int, uid: Int, flags: String, _ h: String) -> String {
        "* \(seq) FETCH (UID \(uid) FLAGS (\(flags)) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {\(h.utf8.count)}\r\n\(h))\r\n"
    }

    // MARK: Reader

    func testReaderJoinsLiteralsAndWaitsForTheRest() {
        var r = IMAPReader()
        let h = "From: a\r\nSubject: b\r\n\r\n"
        r.feed(Data("* 1 FETCH (UID 9 BODY[HEADER] {\(h.utf8.count)}\r\n\(h.prefix(5))".utf8))
        XCTAssertNil(r.next())   // literal not complete yet
        r.feed(Data("\(h.dropFirst(5)) FLAGS (\\Seen))\r\na1 OK done\r\n".utf8))
        let first = r.next()
        XCTAssertEqual(first?.literals, [Data(h.utf8)])
        XCTAssertEqual(first?.text, "* 1 FETCH (UID 9 BODY[HEADER] {\(h.utf8.count)} FLAGS (\\Seen))")
        XCTAssertNil(first?.tag)
        XCTAssertEqual(r.next()?.tag, "a1")
        XCTAssertNil(r.next())
    }

    func testCodesAndQuoting() {
        XCTAssertEqual(IMAPParse.code("UIDNEXT", in: "* OK [UIDNEXT 4392] Predicted"), 4392)
        XCTAssertNil(IMAPParse.code("UIDNEXT", in: "* OK [UIDVALIDITY 1]"))
        XCTAssertEqual(IMAPSession.quoted(#"ab"c\d"#), #""ab\"c\\d""#)
        XCTAssertNil(IMAPSession.quoted("비번"))
        XCTAssertNil(IMAPSession.quoted("a\r\nb"))
    }

    // MARK: Headers

    func testEncodedWords() {
        XCTAssertEqual(IMAPParse.words("=?UTF-8?B?6rmA7LKg7IiY?="), "김철수")
        XCTAssertEqual(IMAPParse.words("=?utf-8?Q?=EC=83=88_=EB=A9=94=EC=9D=BC?= 도착"), "새 메일 도착")
        XCTAssertEqual(IMAPParse.words("=?EUC-KR?B?vsiz58fPvLy/5A==?="), "안녕하세요")
        XCTAssertEqual(IMAPParse.words("=?ks_c_5601-1987?B?sN/A+7yt?="), "견적서")
        // One character split across two words, and the space between them dropped.
        XCTAssertEqual(IMAPParse.words("=?UTF-8?B?7ZqM7J0=?= =?UTF-8?B?mCDsnpDro4wg6rO17Jyg?="), "회의 자료 공유")
        XCTAssertEqual(IMAPParse.words("Re: =?UTF-8?B?6rmA7LKg7IiY?= 님"), "Re: 김철수 님")
        XCTAssertEqual(IMAPParse.words("plain subject"), "plain subject")
        XCTAssertEqual(IMAPParse.words("=?x-unknown?B?YWJj?="), "=?x-unknown?B?YWJj?=")
        // A charset of "*" alone (anyone can send that subject): kept as it is, no crash.
        XCTAssertEqual(IMAPParse.words("=?*?B?QQ==?="), "=?*?B?QQ==?=")
        XCTAssertEqual(IMAPParse.headers(Data("Subject: =?*?B?QQ==?=\r\n".utf8))["subject"], "=?*?B?QQ==?=")
        XCTAssertEqual(IMAPParse.words("=?utf-8*ko?B?6rmA?="), "김")   // RFC 2231 language dropped
        // Labelled EUC-KR, really CP949 (똠 is outside KS X 1001): read as CP949, encoded-word and raw 8-bit.
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let b = "똠방각하".data(using: cp949)!
        XCTAssertEqual(IMAPParse.words("=?euc-kr?B?\(b.base64EncodedString())?="), "똠방각하")
        XCTAssertEqual(IMAPParse.headers(Data("Subject: ".utf8) + b + Data("\r\n".utf8))["subject"], "똠방각하")
    }

    /// A hostile server's literal counts: negative, past Int, past the buffer limit. Never a crash.
    func testBadLiteralCountsAreNotLiterals() {
        XCTAssertEqual(IMAPReader.literalLength("x {12}"), 12)
        XCTAssertEqual(IMAPReader.literalLength("x {12+}"), 12)
        for bad in ["x {-5}", "x {9223372036854775807}", "x {99999999999999999999}", "x {+}", "x {}", "x {1+2}", "x {５}",
                    "x {\(IMAPSession.maxBuffer + 1)}"] {
            XCTAssertNil(IMAPReader.literalLength(bad), bad)
        }
        var r = IMAPReader()
        r.feed(Data("* 1 FETCH (UID 5 BODY[HEADER.FIELDS (FROM)] {-5}\r\nabc\r\n".utf8))
        XCTAssertEqual(r.next()?.literals, [])
        XCTAssertEqual(r.next()?.text, "abc")
        r.feed(Data("* 1 FETCH {9223372036854775807}\r\n".utf8))
        XCTAssertNotNil(r.next())
    }

    func testHeadersUnfoldAndSender() {
        let raw = Data("From: \"=?UTF-8?B?6rmA7LKg7IiY?=\" <kim@naver.com>\r\nSubject: =?UTF-8?B?7ZqM7J0=?=\r\n =?UTF-8?B?mCDsnpDro4wg6rO17Jyg?=\r\n\r\n".utf8)
        let h = IMAPParse.headers(raw)
        XCTAssertEqual(IMAPParse.sender(h["from"]!), "김철수")
        XCTAssertEqual(h["subject"], "회의 자료 공유")
        XCTAssertEqual(IMAPParse.sender("news@shop.com"), "news")
        XCTAssertEqual(IMAPParse.sender("<only@addr.com>"), "only")
        // Raw 8-bit EUC-KR header (old Korean mailers).
        let euc = "Subject: 안녕\r\n".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))))!
        XCTAssertEqual(IMAPParse.headers(euc)["subject"], "안녕")
        XCTAssertNotNil(IMAPParse.date("Sun, 4 Oct 2026 14:05:00 +0900 (KST)"))
        XCTAssertNotNil(IMAPParse.date("4 Oct 2026 14:05 +0000"))
    }

    // MARK: Session

    func testFirstCheckOnlyLearnsAndNeverReads() async throws {
        let s = FakeIMAP(["EXAMINE": Self.examine])
        let (box, mails) = try await IMAPCheck.run(s, user: "me@gmail.com", password: "abcd efgh", since: nil)
        XCTAssertEqual(box, IMAPMailbox(validity: 77, next: 105))
        XCTAssertEqual(mails, [])
        XCTAssertEqual(s.sent, ["a1 LOGIN \"me@gmail.com\" \"abcd efgh\"\r\n", "a2 EXAMINE INBOX\r\n", "a3 LOGOUT\r\n"])
        XCTAssertTrue(s.closed)
    }

    func testNewMailSinceTheLastCheck() async throws {
        let h1 = Self.header("=?UTF-8?B?6rmA7LKg7IiY?= <kim@naver.com>", "=?UTF-8?B?6rKs7KCB7ISc?=")
        let h2 = Self.header("news@shop.com", "Sale")
        let s = FakeIMAP(["EXAMINE": Self.examine,
                          "UID FETCH": Self.fetchLine(seq: 2, uid: 103, flags: "", h1) + "* 2 FETCH (FLAGS ())\r\n"
                            + Self.fetchLine(seq: 3, uid: 104, flags: "\\Seen", h2) + "$T OK FETCH completed\r\n"])
        let (box, mails) = try await IMAPCheck.run(s, user: "kim", password: "pw", since: IMAPMailbox(validity: 77, next: 103))
        XCTAssertEqual(box.next, 105)
        XCTAssertTrue(s.sent.contains("a3 UID FETCH 103:104 (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])\r\n"))
        XCTAssertFalse(s.sent.contains { $0.contains("SELECT") || $0.contains("STORE") || $0.contains("BODY[") })
        XCTAssertEqual(mails.map(\.uid), [103, 104])
        XCTAssertEqual(mails[0].sender, "김철수")
        XCTAssertEqual(mails[0].subject, "견적서")
        XCTAssertFalse(mails[0].seen)
        XCTAssertTrue(mails[1].seen)
        XCTAssertNotNil(mails[0].date)
    }

    func testRenumberedMailboxStartsOver() async throws {
        let s = FakeIMAP(["EXAMINE": Self.examine])
        let (box, mails) = try await IMAPCheck.run(s, user: "u", password: "p", since: IMAPMailbox(validity: 1, next: 50))
        XCTAssertEqual(box.validity, 77)
        XCTAssertEqual(mails, [])
        XCTAssertFalse(s.sent.contains { $0.contains("FETCH") })
    }

    func testABurstFetchesOnlyTheNewest() async throws {
        let s = FakeIMAP(["EXAMINE": Self.examine])
        _ = try await IMAPCheck.run(s, user: "u", password: "p", since: IMAPMailbox(validity: 77, next: 10))
        XCTAssertTrue(s.sent.contains { $0.hasPrefix("a3 UID FETCH 85:104 ") })
    }

    func testLoginRefusedIsALoginError() async {
        let s = FakeIMAP(["LOGIN": "$T NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"])
        do {
            _ = try await IMAPCheck.run(s, user: "u", password: "p", since: nil)
            XCTFail("should throw")
        } catch {
            guard case .login = error as? IMAPError else { return XCTFail("\(error)") }
            XCTAssertTrue(s.closed)
            XCTAssertTrue(MailAccounts.words(error, .gmail).contains("앱 비밀번호"))
        }
    }

    /// Busy or "log in on the web first" is not a wrong password: tried again next time.
    func testPassingLoginRefusalsAreNetworkErrors() async {
        for reply in ["$T NO [UNAVAILABLE] Too many simultaneous connections\r\n", "$T NO [INUSE] busy\r\n",
                      "$T NO [ALERT] Please log in via your web browser\r\n"] {
            do { _ = try await IMAPCheck.run(FakeIMAP(["LOGIN": reply]), user: "u", password: "p", since: nil); XCTFail(reply) } catch {
                guard case .network = error as? IMAPError else { return XCTFail("\(reply): \(error)") }
            }
        }
        for reply in ["$T NO LOGIN failed\r\n", "$T NO [EXPIRED] password expired\r\n", "$T NO [AUTHORIZATIONFAILED] no\r\n"] {
            do { _ = try await IMAPCheck.run(FakeIMAP(["LOGIN": reply]), user: "u", password: "p", since: nil); XCTFail(reply) } catch {
                guard case .login = error as? IMAPError else { return XCTFail("\(reply): \(error)") }
            }
        }
    }

    func testByeAndDroppedConnectionAreNetworkErrors() async {
        let bye = FakeIMAP([:])
        bye.script["EXAMINE"] = "* BYE server shutting down\r\n"
        do { _ = try await IMAPCheck.run(bye, user: "u", password: "p", since: nil); XCTFail() } catch {
            XCTAssertEqual(error as? IMAPError, .network("* BYE server shutting down"))
        }
        let cut = FakeIMAP(["EXAMINE": "* 3 EXISTS\r\n"])   // then nothing: closed
        do { _ = try await IMAPCheck.run(cut, user: "u", password: "p", since: nil); XCTFail() } catch {
            XCTAssertEqual(error as? IMAPError, .network("connection closed"))
        }
    }

    // MARK: Accounts

    @MainActor
    func testAccountsAddPollAndForget() async throws {
        let suite = "test.imap.accounts"
        UserDefaults().removePersistentDomain(forName: suite)
        MailKeychain.prefix = "com.jelly.dogmonitor.test.mail."
        let m = MailAccounts(defaults: UserDefaults(suiteName: suite)!)
        var server = FakeIMAP(["EXAMINE": Self.examine])
        m.connect = { _ in server }
        var said: [InboxItem] = []
        m.deliver = { said += $0 }
        defer {
            m.accounts.forEach { MailKeychain.delete(for: $0) }
            MailKeychain.prefix = "com.jelly.dogmonitor.mail."
            UserDefaults().removePersistentDomain(forName: suite)
        }

        let err = await m.add(preset: .naver, user: "kim", password: "app-pw")
        XCTAssertNil(err)
        let acc = try XCTUnwrap(m.accounts.first)
        XCTAssertEqual(acc.host, "imap.naver.com")
        XCTAssertEqual(MailKeychain.load(for: acc), "app-pw")
        XCTAssertEqual(m.label(acc), "네이버 메일")
        let dup = await m.add(preset: .naver, user: "kim", password: "x")
        XCTAssertNotNil(dup)

        // Two minutes later a new (unread) mail and an old one moved into the inbox.
        let h = Self.header("=?UTF-8?B?6rmA7LKg7IiY?= <kim@x.com>", "점심")
        let old = Self.header("a@b.c", "old", date: "Mon, 1 Jan 2024 09:00:00 +0900")
        server = FakeIMAP(["EXAMINE": Self.examine.replacingOccurrences(of: "105", with: "107"),
                           "UID FETCH": Self.fetchLine(seq: 4, uid: 105, flags: "", h) + Self.fetchLine(seq: 5, uid: 106, flags: "", old) + "$T OK\r\n"])
        let now = Date()
        await m.poll(now: now.addingTimeInterval(3 * 60))
        XCTAssertTrue(server.sent.contains { $0.contains("UID FETCH 105:106") })
        XCTAssertEqual(said.map(\.who), ["김철수"])
        XCTAssertEqual(said.first?.via, "네이버 메일")
        XCTAssertEqual(said.first?.account, acc.id)
        XCTAssertEqual(InboxLine.line([said[0]].map { var i = $0; i.preview = "점심"; return i }, polite: false),
                       "네이버 메일: 김철수한테서 메일 왔어: 점심")

        // A wrong password stops the checks (no repeated failed logins) until a new one is put in.
        server = FakeIMAP(["LOGIN": "$T NO [AUTHENTICATIONFAILED] Invalid\r\n"])
        await m.poll(now: now.addingTimeInterval(6 * 60))
        guard case .login = m.status[acc.id] else { return XCTFail("\(String(describing: m.status[acc.id]))") }
        server = FakeIMAP(["EXAMINE": Self.examine])
        await m.poll(now: now.addingTimeInterval(9 * 60))
        XCTAssertTrue(server.sent.isEmpty)
        let fixed = await m.retry(acc.id, password: "new-pw")
        XCTAssertNil(fixed)
        XCTAssertEqual(MailKeychain.load(for: acc), "new-pw")

        m.remove(acc.id)
        XCTAssertTrue(m.accounts.isEmpty)
        XCTAssertNil(MailKeychain.load(for: acc))
    }

    /// A check that started before a retry or a removal lands nowhere.
    @MainActor
    func testOldChecksDoNotOverwriteNewerState() async throws {
        let suite = "test.imap.race"
        UserDefaults().removePersistentDomain(forName: suite)
        MailKeychain.prefix = "com.jelly.dogmonitor.test.mail."
        let m = MailAccounts(defaults: UserDefaults(suiteName: suite)!)
        m.connect = { _ in FakeIMAP(["EXAMINE": Self.examine]) }
        defer {
            m.accounts.forEach { MailKeychain.delete(for: $0) }
            MailKeychain.prefix = "com.jelly.dogmonitor.mail."
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let added = await m.add(preset: .gmail, user: "me@gmail.com", password: "old")
        XCTAssertNil(added)
        let id = try XCTUnwrap(m.accounts.first).id
        let wrong = "$T NO [AUTHENTICATIONFAILED] Invalid\r\n"

        // (a) A retry with the new password finishes while the poll (old password) is still connecting.
        var calls = 0
        m.connect = { _ in
            calls += 1
            if calls == 1 {
                let fixed = await m.retry(id, password: "new")
                XCTAssertNil(fixed)
                return FakeIMAP(["LOGIN": wrong])
            }
            return FakeIMAP(["EXAMINE": Self.examine])
        }
        await m.poll(now: Date().addingTimeInterval(3 * 60))
        guard case .ok = m.status[id] else { return XCTFail("\(String(describing: m.status[id]))") }

        // (b) Removed while a wrong password is being checked: no status, no notice for the gone account.
        AssistantSettings.shared.integrationNotice = nil
        m.connect = { _ in
            await MainActor.run { m.remove(id) }
            return FakeIMAP(["LOGIN": wrong])
        }
        await m.poll(now: Date().addingTimeInterval(6 * 60))
        XCTAssertNil(m.status[id])
        XCTAssertNil(AssistantSettings.shared.integrationNotice)
    }

    func testMultiAccountLabelsAndMixedLines() {
        let a = InboxItem(kind: .mail, who: "김", preview: nil, date: Date(), via: "Gmail", account: "1")
        let b = InboxItem(kind: .mail, who: "이", preview: nil, date: Date(), via: "네이버 메일", account: "2")
        XCTAssertEqual(InboxLine.line([a, a], polite: true), "Gmail: 메일 2통 왔어요: 김")
        XCTAssertEqual(InboxLine.line([a, b], polite: false), "메일 2통 왔어: 김, 이")
        XCTAssertTrue(InboxLine.recent(a).hasSuffix(" Gmail 김"))
    }
}

extension IMAPTests {
    /// 다음 refused the full address: tried once more with the ID, and that login is kept for later checks.
    @MainActor
    func testDaumRetriesWithTheIDAlone() async throws {
        let suite = "test.imap.idlogin"
        UserDefaults().removePersistentDomain(forName: suite)
        MailKeychain.prefix = "com.jelly.dogmonitor.test.mail."
        let m = MailAccounts(defaults: UserDefaults(suiteName: suite)!)
        var servers: [FakeIMAP] = []
        m.connect = { _ in
            let s = FakeIMAP(servers.isEmpty ? ["LOGIN": "$T NO [AUTHENTICATIONFAILED] Invalid\r\n"] : ["EXAMINE": Self.examine])
            servers.append(s)
            return s
        }
        defer {
            m.accounts.forEach { MailKeychain.delete(for: $0) }
            MailKeychain.prefix = "com.jelly.dogmonitor.mail."
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let err = await m.add(preset: .daum, user: "kim@daum.net", password: "pw")
        XCTAssertNil(err)
        XCTAssertEqual(servers.count, 2)
        XCTAssertTrue(servers[1].sent.contains { $0.contains("LOGIN") && $0.contains("kim") && !$0.contains("@") })
        let acc = try XCTUnwrap(m.accounts.first)
        XCTAssertEqual(acc.login, "kim")
        XCTAssertEqual(acc.loginName, "kim")   // what agent reads, SMTP and the sent copy log in with too
        XCTAssertEqual(acc.id, "kim@daum.net@imap.daum.net")   // the keychain key stays the address
        XCTAssertNil(MailAccounts.idLogin(.gmail, "kim@gmail.com"))
    }
}
