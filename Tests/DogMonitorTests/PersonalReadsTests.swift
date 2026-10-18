import XCTest
@testable import DogMonitor

/// The personal read tools on fake sources: formatting, access-off lines, read-only IMAP and MIME text. No real data.
@MainActor
final class PersonalReadsTests: XCTestCase {
    static let account = MailAccount(preset: .gmail, host: "imap.gmail.com", port: 993, user: "me@gmail.com", on: true)

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func reads(events: [PersonalReads.Event]? = [], reminders: [PersonalReads.Reminder]? = [], inbox: [InboxItem] = [],
               cards: [ContactsFinder.Card]? = [], imap: FakeIMAP? = nil) -> PersonalReads {
        PersonalReads(events: { _, _ in events }, reminders: { reminders }, inbox: { inbox }, cards: { cards },
                      mailAccounts: { imap == nil ? [] : [Self.account] }, password: { _ in "pw" },
                      connect: { _ in imap! })
    }

    // MARK: Calendar, reminders, inbox, contacts, memory

    func testCalendarListSoonestFirstWithPlaceAndAllDay() {
        let r = reads(events: [
            .init(start: at(7, 9), end: at(7, 10), title: "치과", location: "강남"),
            .init(start: at(6, 15), end: at(6, 16, 30), title: "팀 회의\n(주간)"),
            .init(start: at(8, 0), end: at(9, 0), title: "휴가", allDay: true),
        ])
        XCTAssertEqual(r.calendarList(from: at(6, 0), to: at(9, 0)).components(separatedBy: "\n"), [
            "2026-10-06 15:00~16:30 팀 회의 (주간)",
            "2026-10-07 09:00~10:00 치과 @ 강남",
            "2026-10-08 종일 휴가",
        ])
        XCTAssertTrue(reads(events: nil).calendarList(from: at(6, 0), to: at(7, 0)).contains("꺼져"))
        XCTAssertTrue(reads(events: []).calendarList(from: at(6, 0), to: at(7, 0)).contains("없어요"))
    }

    func testCalendarCapsAt40Lines() {
        let many = (0..<45).map { PersonalReads.Event(start: at(6, 0, $0), end: at(6, 1, $0), title: "e\($0)") }
        let lines = reads(events: many).calendarList(from: at(6, 0), to: at(7, 0)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 41)
        XCTAssertEqual(lines.last, "…외 5개")
    }

    func testRemindersWithIDsDueFirst() async {
        let r = reads(reminders: [.init(id: "R2", title: "우유"), .init(id: "R1", title: "보고서", due: at(7, 18))])
        let text = await r.remindersList()
        XCTAssertEqual(text, "[R1] 보고서 (마감 2026-10-07 18:00)\n[R2] 우유")
        let off = await reads(reminders: nil).remindersList()
        XCTAssertTrue(off.contains("꺼져"))
    }

    func testInboxNewestFirst() {
        let r = reads(inbox: [
            InboxItem(kind: .message, who: "엄마", preview: "저녁 먹어", date: at(6, 9)),
            InboxItem(kind: .mail, who: "김부장", preview: nil, date: at(6, 11), via: "네이버 메일"),
        ])
        XCTAssertEqual(r.inboxRecent(), "2026-10-06 11:00 메일 (네이버 메일) 김부장\n2026-10-06 09:00 문자 엄마: 저녁 먹어")
        XCTAssertTrue(reads().inboxRecent().contains("없어요"))
    }

    func testContactsFindMax5BestFirst() async {
        var cards = [ContactsFinder.Card(given: "철수", family: "김", organization: "회사", jobTitle: "부장",
                                         emails: ["kim@x.com"], phones: ["010-1111-2222"])]
        cards += (0..<7).map { ContactsFinder.Card(given: "철수\($0)", family: "김", emails: ["k\($0)@x.com"]) }
        let text = await reads(cards: cards).contactsFind("김철수")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first, "김철수 (회사, 부장): kim@x.com, 010-1111-2222")
        let none = await reads(cards: cards).contactsFind("박영희")
        XCTAssertTrue(none.contains("찾지 못했어요"))
        let off = await reads(cards: nil).contactsFind("김철수")
        XCTAssertTrue(off.contains("꺼져"))
    }

    func testMemoryReadShowsOnlyVisibleEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = OwnerMemory(url: url)
        XCTAssertTrue(reads().memoryRead(m).contains("없어요"))
        m.add(key: "배송지", value: "회사")
        m.add(key: "여권", value: "M123", showToAI: false)
        XCTAssertEqual(reads().memoryRead(m), "배송지: 회사")
    }

    // MARK: Mail (fake IMAP)

    static func fetch(_ uid: Int, _ from: String, _ subject: String, _ date: String) -> String {
        IMAPTests.fetchLine(seq: uid, uid: uid, flags: "", IMAPTests.header(from, subject, date: date))
    }

    func testMailSearchIsReadOnlyNewestTen() async throws {
        let uids = (1...12).map(String.init).joined(separator: " ")
        let imap = FakeIMAP(["EXAMINE": IMAPTests.examine, "UID SEARCH": "* SEARCH \(uids)\r\n$T OK done\r\n",
                             "UID FETCH": Self.fetch(11, "\"김부장\" <kim@x.com>", "회의 변경", "Mon, 5 Oct 2026 09:00:00 +0900")
                                + Self.fetch(12, "news@y.com", "invoice", "Tue, 6 Oct 2026 09:00:00 +0900") + "$T OK done\r\n"])
        let text = await reads(imap: imap).mailSearch("invoice")
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(text.hasPrefix("[me@gmail.com@imap.gmail.com:12] "), text)
        XCTAssertTrue(text.contains("news: invoice"))
        XCTAssertTrue(text.contains("김부장: 회의 변경"))
        let sent = imap.sent.joined()
        XCTAssertTrue(sent.contains("EXAMINE INBOX"))
        XCTAssertTrue(sent.contains(#"UID SEARCH OR SUBJECT "invoice" FROM "invoice""#))
        XCTAssertTrue(sent.contains("UID FETCH 3,4,5,6,7,8,9,10,11,12 (UID BODY.PEEK["))
        XCTAssertFalse(sent.contains("SELECT "))
        XCTAssertFalse(sent.contains("STORE"))
        XCTAssertTrue(imap.closed)
    }

    func testMailSearchKoreanUsesUTF8Literal() {
        XCTAssertEqual(MailRead.searchArgs("김부장"), "CHARSET UTF-8 OR SUBJECT {9}\r\n김부장 FROM {9}\r\n김부장")
    }

    func testMailSearchNoAccountAndNoMatch() async {
        let none = await reads().mailSearch("x")
        XCTAssertTrue(none.contains("메일 계정이 없어요"))
        let imap = FakeIMAP(["EXAMINE": IMAPTests.examine, "UID SEARCH": "* SEARCH\r\n$T OK done\r\n"])
        let empty = await reads(imap: imap).mailSearch("x")
        XCTAssertTrue(empty.contains("맞는 메일이 없어요"))
        XCTAssertFalse(imap.sent.joined().contains("UID FETCH"))
    }

    func testMailReadPicksPlainTextAndPeeks() async {
        let head = "From: =?UTF-8?B?6rmA7LKg7IiY?= <kim@x.com>\r\nSubject: hello\r\nDate: Mon, 5 Oct 2026 09:00:00 +0900\r\n"
            + "Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n"
        let body = "--b1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>html</p>\r\n"
            + "--b1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=EC=95=88=EB=85=95=\r\n!\r\n--b1--\r\n"
        let line = "* 1 FETCH (UID 7 BODY[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {\(head.utf8.count)}\r\n\(head)"
            + " BODY[TEXT]<0> {\(body.utf8.count)}\r\n\(body))\r\n$T OK done\r\n"
        let imap = FakeIMAP(["EXAMINE": IMAPTests.examine, "UID FETCH": line])
        let text = await reads(imap: imap).mailRead("me@gmail.com@imap.gmail.com:7")
        XCTAssertEqual(text.components(separatedBy: "\n"), ["보낸 사람: 김철수", "제목: hello", "날짜: " + PersonalReads.stamp(IMAPParse.date("Mon, 5 Oct 2026 09:00:00 +0900")!), "", "안녕!"])
        XCTAssertTrue(imap.sent.joined().contains("UID FETCH 7 (UID BODY.PEEK[HEADER.FIELDS"))
        XCTAssertTrue(imap.sent.joined().contains("BODY.PEEK[TEXT]"))
        let bad = await reads(imap: imap).mailRead("other@host:7")
        XCTAssertTrue(bad.contains("찾지 못했어요"))
        let noUID = await reads(imap: imap).mailRead("me@gmail.com@imap.gmail.com:x")
        XCTAssertTrue(noUID.contains("찾지 못했어요"))
    }

    // MARK: MIME text

    func testQuotedPrintableUTF8() {
        let h = ["content-type": "text/plain; charset=UTF-8", "content-transfer-encoding": "quoted-printable"]
        XCTAssertEqual(MIMEText.extract(h, Data("=EC=95=88=EB=85=95=\r\n=ED=95=98=EC=84=B8=EC=9A=94 a=3Db".utf8)), "안녕하세요 a=b")
    }

    func testBase64WithLineBreaksAndCut() {
        let b64 = Data("안녕하세요, 내일 봬요".utf8).base64EncodedString(options: .lineLength64Characters)
        let h = ["content-type": "text/plain; charset=\"utf-8\"", "content-transfer-encoding": "base64"]
        XCTAssertEqual(MIMEText.extract(h, Data(b64.utf8)), "안녕하세요, 내일 봬요")
        XCTAssertFalse(MIMEText.extract(h, Data(b64.prefix(10).utf8)).isEmpty)   // a cut partial fetch still reads
    }

    func testMultipartPrefersPlainInsideMixed() {
        let body = """
        preamble\r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/html\r
        \r
        <b>굵게</b>\r
        --inner\r
        Content-Type: text/plain; charset=euc-kr\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data([0xBE, 0xC8, 0xB3, 0xE7]).base64EncodedString())\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf\r
        \r
        JVBERi0=\r
        --outer--\r
        """
        XCTAssertEqual(MIMEText.extract(["content-type": "multipart/mixed; boundary=\"outer\""], Data(body.utf8)), "안녕")
    }

    func testHTMLOnlyIsStripped() {
        let html = "<html><head><style>p{}</style></head><body><p>안녕 &amp; 반가워</p><br>둘째<script>x()</script></body></html>"
        XCTAssertEqual(MIMEText.extract(["content-type": "text/html; charset=utf-8"], Data(html.utf8)), "안녕 & 반가워\n\n둘째")
    }
}
