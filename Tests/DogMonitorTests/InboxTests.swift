#if !MAS
import SQLite3
import XCTest
@testable import DogMonitor

/// 문자·메일·알림 알려주기 on made-up databases in a temp folder. Never opens the user's own chat.db or notifications.
final class InboxTests: XCTestCase {
    private var dir: URL!
    private var writers: [OpaquePointer?] = []
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        writers.forEach { sqlite3_close($0) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// A writable database left open in WAL mode, so new rows sit in the -wal file like Messages' do.
    private func makeDB(_ name: String, _ sql: String) -> (path: String, db: OpaquePointer?) {
        let path = dir.appendingPathComponent(name).path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "pragma journal_mode=wal; pragma wal_autocheckpoint=0; " + sql, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(db)))
        writers.append(db)
        return (path, db)
    }

    private func insert(_ db: OpaquePointer?, _ sql: String, _ blobs: [Data?]) {
        var s: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &s, nil), SQLITE_OK)
        for (i, b) in blobs.enumerated() {
            if let b { _ = b.withUnsafeBytes { sqlite3_bind_blob(s, Int32(i + 1), $0.baseAddress, Int32(b.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            else { sqlite3_bind_null(s, Int32(i + 1)) }
        }
        XCTAssertEqual(sqlite3_step(s), SQLITE_DONE)
        sqlite3_finalize(s)
    }

    private func typedstream(_ s: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: s))
    }

    // MARK: attributedBody

    func testAttributedBodyDecodesTypedstream() {
        XCTAssertEqual(AttributedBody.text(typedstream("저녁 먹었어?")), "저녁 먹었어?")
        let long = String(repeating: "가나다라마바사 ", count: 20)   // over 127 bytes: the 0x81 length form
        XCTAssertEqual(AttributedBody.text(typedstream(long)), long)
    }

    func testAttributedBodyRejectsBrokenBlobs() {
        let blob = typedstream(String(repeating: "길다", count: 100))
        XCTAssertNil(AttributedBody.text(blob.prefix(blob.count / 2)))   // cut inside the text
        XCTAssertNil(AttributedBody.text(Data("NSString".utf8)))
        XCTAssertNil(AttributedBody.text(Data([0x00, 0x01])))
        // Hand-made: header, 0x81 with a length past the end.
        XCTAssertNil(AttributedBody.text(Data("NSString".utf8) + Data([1, 0x94, 0x84, 1, 0x2B, 0x81, 0xFF, 0x7F, 0x41])))
    }

    // MARK: chat.db

    private func chatDB() -> (path: String, db: OpaquePointer?) {
        makeDB("chat.db", """
            create table handle (ROWID integer primary key, id text);
            create table chat (ROWID integer primary key, chat_identifier text, display_name text);
            create table chat_message_join (chat_id integer, message_id integer);
            create table message (ROWID integer primary key, guid text, text text, attributedBody blob, handle_id integer,
                date integer, is_from_me integer, item_type integer, associated_message_type integer, service text,
                cache_has_attachments integer);
            insert into handle values (1, '+821012345678'), (2, 'kim@example.com');
            """)
    }

    private func addMessage(_ db: OpaquePointer?, _ id: Int, handle: Int, text: String?, body: Data? = nil, fromMe: Int = 0,
                            itemType: Int = 0, reaction: Int = 0, at offset: TimeInterval = 0) {
        let date = Int64(t0.addingTimeInterval(offset).timeIntervalSinceReferenceDate * 1e9)
        let t = text.map { "'\($0)'" } ?? "null"
        insert(db, "insert into message values (\(id), 'g\(id)', \(t), ?, \(handle), \(date), \(fromMe), \(itemType), \(reaction), 'iMessage', 0)", [body])
    }

    func testMessagesReadsNewReceivedRowsThroughWAL() {
        let (path, db) = chatDB()
        let m = MessagesDB(path: path)
        XCTAssertEqual(m.access(), .ok)
        XCTAssertEqual(m.maxRowID(), 0)
        addMessage(db, 1, handle: 1, text: "옛날 문자")
        XCTAssertEqual(m.maxRowID(), 1)
        addMessage(db, 2, handle: 1, text: nil, body: typedstream("저녁 먹었어?"))
        addMessage(db, 3, handle: 1, text: "내가 보낸 것", fromMe: 1)
        addMessage(db, 4, handle: 1, text: "좋아요 반응", reaction: 2000)
        addMessage(db, 5, handle: 1, text: "그룹 이름 변경", itemType: 2)
        addMessage(db, 6, handle: 2, text: "회의 자료요")
        let rows = m.messages(after: 1) ?? []
        XCTAssertEqual(rows.map(\.rowID), [2, 6])
        XCTAssertEqual(rows.map(\.text), ["저녁 먹었어?", "회의 자료요"])
        XCTAssertEqual(rows.first?.handle, "+821012345678")
        XCTAssertEqual(rows.first?.date.timeIntervalSinceReferenceDate ?? 0, t0.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(m.messages(after: 6)?.count, 0)
    }

    func testStepLearnsThenMovesCursor() {
        let (path, db) = chatDB()
        let m = MessagesDB(path: path)
        addMessage(db, 1, handle: 1, text: "과거")
        addMessage(db, 2, handle: 1, text: "과거 2")
        let first = InboxCenter.step(cursor: nil, max: m.maxRowID, fetch: { m.messages(after: $0) }, id: \.rowID)
        XCTAssertEqual(first.cursor, 2)
        XCTAssertTrue(first.rows.isEmpty, "the first poll never reads out the past")
        addMessage(db, 3, handle: 2, text: "새 문자")
        let next = InboxCenter.step(cursor: first.cursor, max: m.maxRowID, fetch: { m.messages(after: $0) }, id: \.rowID)
        XCTAssertEqual(next.cursor, 3)
        XCTAssertEqual(next.rows.map(\.text), ["새 문자"])
        // A cursor past the end (the database was rebuilt) goes back to the end.
        XCTAssertEqual(InboxCenter.step(cursor: 99, max: m.maxRowID, fetch: { m.messages(after: $0) }, id: \.rowID).cursor, 3)
        // Unreadable: not ok, cursor kept.
        let none = MessagesDB(path: dir.appendingPathComponent("nope/chat.db").path)
        let fail = InboxCenter.step(cursor: 5, max: none.maxRowID, fetch: { none.messages(after: $0) }, id: \.rowID)
        XCTAssertFalse(fail.ok)
        XCTAssertEqual(fail.cursor, 5)
    }

    func testAccessMissingAndWrongFile() {
        XCTAssertEqual(ReadOnlyDB.access(dir.appendingPathComponent("gone/db").path, table: "record"), .missing)
        XCTAssertEqual(ReadOnlyDB.access(dir.appendingPathComponent("db").path, table: "record"), .missing)
        let (path, _) = makeDB("other.db", "create table x (a);")
        XCTAssertEqual(ReadOnlyDB.access(path, table: "record"), .missing)
    }

    // MARK: Notification Center database

    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    func testNotificationsParseAndProgress() {
        let (path, db) = makeDB("db", """
            create table app (app_id integer primary key, identifier text);
            create table record (rec_id integer primary key, app_id integer, uuid blob, data blob, delivered_date real);
            insert into app values (1, 'com.kakao.KakaoTalkMac'), (2, 'com.tinyspeck.slackmacgap');
            """)
        let n = NotificationsDB(path: path)
        XCTAssertEqual(n.access(), .ok)
        let date = t0.timeIntervalSinceReferenceDate
        insert(db, "insert into record values (1, 1, null, ?, \(date))", [plist(["app": "com.kakao.KakaoTalkMac", "req": ["titl": "엄마", "body": "밥 먹었니"]])])
        XCTAssertEqual(n.maxRecID(), 1)
        // Localized fields come as [format, resolved, args].
        insert(db, "insert into record values (2, 2, null, ?, \(date))",
               [plist(["app": "com.tinyspeck.slackmacgap", "req": ["titl": ["%@ in #dev", "김철수 in #dev", ["김철수"]], "subt": "", "body": ["배포 끝"]]])])
        insert(db, "insert into record values (3, 2, null, ?, null)", [plist(["app": "x"])])   // not delivered yet
        let rows = n.records(after: 0) ?? []
        XCTAssertEqual(rows.map(\.recID), [1, 2])
        XCTAssertEqual(rows[0], NotificationsDB.Row(recID: 1, bundle: "com.kakao.KakaoTalkMac", title: "엄마", body: "밥 먹었니", date: t0))
        XCTAssertEqual(rows[1].title, "김철수 in #dev")
        XCTAssertEqual(rows[1].body, "배포 끝")
        XCTAssertEqual(n.records(after: 2)?.count, 0)
        XCTAssertEqual(n.topApps(), ["com.tinyspeck.slackmacgap", "com.kakao.KakaoTalkMac"])
        XCTAssertNil(NotificationsDB.parse(Data("not a plist".utf8)))
    }

    func testWhichNotificationsAreSaid() {
        let off: Set<String> = ["com.tinyspeck.slackmacgap"]
        XCTAssertTrue(NotificationsDB.shouldSay("com.kakao.KakaoTalkMac", off: off, skip: [], own: "com.jelly.dogmonitor"))
        XCTAssertFalse(NotificationsDB.shouldSay("com.tinyspeck.slackmacgap", off: off, skip: []))
        XCTAssertFalse(NotificationsDB.shouldSay("com.jelly.dogmonitor", off: [], skip: [], own: nil), "never our own")
        XCTAssertFalse(NotificationsDB.shouldSay("com.apple.ScreenTimeAgent", off: [], skip: []), "system")
        XCTAssertTrue(NotificationsDB.shouldSay("com.apple.MobileSMS", off: [], skip: []))
        XCTAssertFalse(NotificationsDB.shouldSay("com.apple.MobileSMS", off: [], skip: ["com.apple.MobileSMS"]), "said by 문자 already")
        XCTAssertFalse(NotificationsDB.shouldSay("", off: [], skip: []))
    }

    func testNudgeLineCannotInventInbox() {
        XCTAssertTrue(AssistantCenter.invents("카톡 왔어! 배터리도 20%야", from: "맥 배터리가 20% 남았고 충전기가 꽂혀 있지 않다."))
        XCTAssertFalse(AssistantCenter.invents("배터리 20%야, 충전기 꽂아 줘", from: "맥 배터리가 20% 남았고 충전기가 꽂혀 있지 않다."))
        XCTAssertFalse(AssistantCenter.invents("새 메일 왔어", from: "새 메일이 왔다."))
        // Other spellings and spacing of the same made-up news.
        let battery = "맥 배터리가 20% 남았고 충전기가 꽂혀 있지 않다."
        for made in ["메세지 왔어!", "톡이 왔어요", "알림이 와 있어", "연락이 왔어", "답장 왔어", "새 Message!"] {
            XCTAssertTrue(AssistantCenter.invents(made, from: battery), made)
        }
    }

    func testEmptyAndRepostedNotificationsAreNotNews() {
        let kakao = "com.kakao.KakaoTalkMac"
        XCTAssertFalse(NotificationsDB.Row(recID: 1, bundle: kakao).hasText, "badge or sync update")
        XCTAssertTrue(NotificationsDB.Row(recID: 1, bundle: kakao, title: "엄마").hasText)
        var seen: [Int: Date] = [:]
        let a = NotificationsDB.Row(recID: 1, bundle: kakao, title: "엄마", body: "밥 먹었니")
        let b = NotificationsDB.Row(recID: 2, bundle: kakao, title: "아빠", body: "밥 먹었니")
        XCTAssertEqual(NotificationsDB.unseen([a, b], seen: &seen, now: t0).map(\.recID), [1, 2])
        var again = a; again.recID = 3
        XCTAssertEqual(NotificationsDB.unseen([again], seen: &seen, now: t0.addingTimeInterval(600)).count, 0, "posted again after wake")
        XCTAssertEqual(NotificationsDB.unseen([again], seen: &seen, now: t0.addingTimeInterval(1900)).count, 1, "past the window: news again")
    }

    // MARK: Lines and batching

    private func item(_ kind: InboxItem.Kind, _ who: String, _ preview: String? = nil, at s: TimeInterval = 0) -> InboxItem {
        InboxItem(kind: kind, who: who, preview: preview, date: t0.addingTimeInterval(s))
    }

    func testLines() {
        XCTAssertEqual(InboxLine.line([item(.message, "엄마", "저녁 먹었어?")], polite: false), "엄마한테서 문자 왔어: 저녁 먹었어?")
        XCTAssertEqual(InboxLine.line([item(.message, "엄마")], polite: true), "엄마한테서 문자 왔어요")
        XCTAssertEqual(InboxLine.line([item(.mail, "김철수", "회의록 공유")], polite: false), "김철수한테서 메일 왔어: 회의록 공유")
        XCTAssertEqual(InboxLine.line([item(.notification, "카카오톡")], polite: false), "카카오톡 알림 왔어")
        XCTAssertEqual(InboxLine.line([item(.message, "엄마"), item(.message, "아빠"), item(.message, "엄마")], polite: false), "문자 3개 왔어: 엄마, 아빠")
        XCTAssertEqual(InboxLine.line([item(.mail, "a"), item(.mail, "b"), item(.mail, "c"), item(.mail, "d")], polite: true), "메일 4통 왔어요: a, b 외 2")
        XCTAssertNil(InboxLine.line([], polite: false))
        XCTAssertEqual(InboxLine.short("첫 줄\n\n둘째 줄\u{FFFC}"), "첫 줄 둘째 줄")
        XCTAssertEqual(InboxLine.short(String(repeating: "가", count: 40)), String(repeating: "가", count: 30) + "…")
    }

    func testRecentFormat() {
        // Not from today: the date goes in front.
        let day = Date(timeIntervalSinceReferenceDate: 812_000_000)
        XCTAssertFalse(InboxLine.recent(item(.message, "a"), now: t0).contains("/"))
        XCTAssertTrue(InboxLine.recent(item(.message, "a"), now: day).contains("/"))
    }

    // MARK: The chat's lookup (InboxCenter.report)

    func testLatestIsNewestReceivedFirstWithPeriod() {
        let (path, db) = chatDB()
        let m = MessagesDB(path: path)
        addMessage(db, 1, handle: 1, text: "그제 문자", at: -2 * 86_400)
        addMessage(db, 2, handle: 2, text: "어제 문자", at: -86_400)
        addMessage(db, 3, handle: 1, text: "내가 보낸 것", fromMe: 1, at: 10)
        addMessage(db, 4, handle: 1, text: "오늘 문자", at: 0)
        addMessage(db, 5, handle: 1, text: "좋아요 반응", reaction: 2000, at: 20)
        XCTAssertEqual(m.latest(limit: 5)?.map(\.text), ["오늘 문자", "어제 문자", "그제 문자"])
        XCTAssertEqual(m.latest(limit: 1)?.map(\.rowID), [4])
        let yesterday = DateInterval(start: t0.addingTimeInterval(-90_000), end: t0.addingTimeInterval(-3600))
        XCTAssertEqual(m.latest(limit: 5, in: yesterday)?.map(\.text), ["어제 문자"])
        XCTAssertNil(MessagesDB(path: dir.appendingPathComponent("nope/chat.db").path).latest(limit: 3))
    }

    private func settings(messages: Bool = true, preview: Bool = true) -> InboxSettings {
        let d = UserDefaults(suiteName: "inbox-test-\(UUID().uuidString)")!
        let s = InboxSettings(defaults: d)
        s.messages = messages
        s.messagesPreview = preview
        return s
    }

    private func ask(_ q: String, _ s: InboxSettings, previous: String? = nil, mail: [InboxItem] = []) -> String {
        let now = t0.addingTimeInterval(60)
        let query = InboxQuery.parse(q, previous: previous, now: now)
        return InboxCenter.report(query, settings: s, mailOn: !mail.isEmpty, memory: mail,
                                  names: { ["+821012345678": "엄마", "kim@example.com": "김철수"][$0] ?? ContactNames.mask($0) })
            .answer(polite: false, now: now)
    }

    /// The user's screenshot: texts from before the app started are there, the newest one is read out, and a missing
    /// database or a switch that is off is said as such, never as "nothing came".
    func testReportReadsTheDatabaseNow() throws {
        let (path, db) = chatDB()
        InboxCenter.messagesPath = path
        defer { InboxCenter.messagesPath = MessagesDB.path }
        addMessage(db, 1, handle: 2, text: "회의 자료요", at: -3 * 3600)
        addMessage(db, 2, handle: 1, text: nil, body: typedstream("저녁 먹었어?"), at: -60)
        addMessage(db, 3, handle: 1, text: "내가 보낸 것", fromMe: 1, at: 0)
        let s = settings()
        let hm = { (d: Date) -> String in let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
        let newest = hm(t0.addingTimeInterval(-60)), older = InboxReport.time(t0.addingTimeInterval(-3 * 3600), now: t0.addingTimeInterval(60))

        XCTAssertEqual(ask("나 가장 최근에 온 문자 내역 알랴줘.", s), "가장 최근 문자는 엄마한테서 \(newest)에 온 거야: 저녁 먹었어?")
        XCTAssertEqual(ask("문자내용 알려줘.", s), "최근 받은 문자 2개야.\n\(newest) 엄마: 저녁 먹었어?\n\(older) 김철수: 회의 자료요")
        XCTAssertEqual(ask("김철수 문자 읽어줘", s), "김철수한테서 \(older)에 온 문자야: 회의 자료요")
        XCTAssertEqual(ask("아빠한테서 온 문자 있어?", s), "최근 받은 문자 중엔 아빠한테서 온 게 없어.")
        XCTAssertEqual(ask("광고 문자 읽어줘", s).components(separatedBy: "\n").first, "최근 받은 문자 2개야.", "a word that is nobody: no filter")
        XCTAssertEqual(ask("더 보여줘", s, previous: "가장 최근 문자 알려줘"), "그 전 문자는 김철수한테서 \(older)에 온 거야: 회의 자료요")

        let quiet = settings(preview: false)
        XCTAssertEqual(ask("마지막 문자 읽어줘", quiet),
                       "가장 최근 문자는 엄마한테서 \(newest)에 온 거야.\n문자 내용 보기가 꺼져 있어서 보낸 사람과 시각만 알려 줬어. 내용까지 들으려면 비서 설정에서 '내용 미리보기'를 켜 줘.")
        XCTAssertFalse(ask("문자 내용 읽어줘", quiet).contains("저녁"), "preview off: no text")

        XCTAssertEqual(ask("문자 읽어줘", settings(messages: false)), "문자 연동이 꺼져 있어서 지금은 볼 수 없어. 비서 설정에서 '문자 메시지 알려주기'를 켜 줘.")
        InboxCenter.messagesPath = dir.appendingPathComponent("gone/chat.db").path
        XCTAssertEqual(ask("문자 읽어줘", s), "이 맥에서 메시지 기록을 찾지 못했어. 메시지 앱에 로그인했는지 확인해 줘.")

        // Mail: only what came since launch (the app keeps none), said as such when there is none.
        let mail = InboxItem(kind: .mail, who: "쿠팡", preview: "주문 완료", date: t0)
        s.mailSubject = true
        XCTAssertEqual(ask("그럼 메일은?", s, previous: "마지막 문자 읽어줘", mail: [mail]), "가장 최근 메일은 쿠팡한테서 \(hm(t0))에 온 거야: 주문 완료")
    }

    func testSinceSkipsStaleRowsInTheQuery() {
        let (path, db) = chatDB()
        let m = MessagesDB(path: path)
        for i in 1...60 { addMessage(db, i, handle: 1, text: "밀린 \(i)") }   // all at t0
        XCTAssertEqual(m.messages(after: 0)?.count, 50)
        XCTAssertEqual(m.messages(after: 0, since: t0.addingTimeInterval(1))?.count, 0, "a stale backlog never fills the page")
    }

    func testBatcherBundlesWithinAMinuteAndHoldsWhileMuted() {
        var b = InboxBatcher()
        b.add([item(.message, "엄마")])
        XCTAssertEqual(b.take(now: t0, muted: false).count, 1, "the first one right away")
        b.add([item(.message, "아빠", at: 20), item(.message, "누나", at: 40)])
        XCTAssertTrue(b.take(now: t0.addingTimeInterval(40), muted: false).isEmpty, "inside the minute: wait")
        XCTAssertEqual(b.take(now: t0.addingTimeInterval(60), muted: false).map(\.who), ["아빠", "누나"], "then together")
        b.add([item(.message, "친구", at: 200)])
        XCTAssertTrue(b.take(now: t0.addingTimeInterval(200), muted: true).isEmpty, "muted: held")
        XCTAssertEqual(b.take(now: t0.addingTimeInterval(500), muted: false).count, 1, "said once the mute ends")
        b.add([item(.message, "오래됨", at: 600)])
        XCTAssertTrue(b.take(now: t0.addingTimeInterval(600 + InboxBatcher.maxAge + 1), muted: false).isEmpty, "too old")
    }

    // MARK: Senders and Mail

    func testMaskHidesTheMiddle() {
        XCTAssertEqual(ContactNames.mask("+821012345678"), "010-****-5678")
        XCTAssertEqual(ContactNames.mask("010-1234-5678"), "010-****-5678")
        XCTAssertEqual(ContactNames.mask("kim@example.com"), "ki***")
        XCTAssertEqual(ContactNames.mask("1588"), "1588")
    }

    func testMailItemsAndFresh() {
        let out = "OK\u{1E}12\u{1F}김철수 <kim@example.com>\u{1F}회의록\n공유\u{1E}11\u{1F}news@shop.com\u{1F}\n"
        let items = MailLink.items(out)
        XCTAssertEqual(items, [MailLink.Item(id: 12, sender: "김철수", subject: "회의록 공유"), MailLink.Item(id: 11, sender: "news", subject: "")])
        XCTAssertEqual(MailLink.items("OK\n"), [])
        XCTAssertNil(MailLink.items("execution error"))
        let first = MailLink.fresh(items!, seen: nil)
        XCTAssertTrue(first.new.isEmpty, "the first poll only learns")
        let next = MailLink.fresh([MailLink.Item(id: 13, sender: "엄마", subject: "사진")] + items!, seen: first.seen)
        XCTAssertEqual(next.new.map(\.id), [13])
        XCTAssertEqual(next.seen, [11, 12, 13])
    }
}
#endif
