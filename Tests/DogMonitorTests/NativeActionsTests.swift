import XCTest
@testable import DogMonitor

/// Pure parts only: no EventKit, Contacts or AppKit calls, so no permission prompt ever shows.
final class NativeActionsTests: XCTestCase {
    /// 2026-10-13 (화) at h:m, local time.
    private func day13(_ h: Int, _ m: Int = 0, day: Int = 13) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    // MARK: Fake

    private final class Fake: NativeActing {
        var calls: [String] = []
        func addEvent(_ e: EventDraft) async throws -> String { calls.append("event \(e.title)"); return "e:1" }
        func addReminder(_ r: ReminderDraft) async throws -> String { calls.append("reminder \(r.title)"); return "r:2" }
        func completeReminder(id: String) async throws -> String? { calls.append("done \(id)"); return "d:" + id }
        func undo(_ undoID: String) async throws { calls.append("undo \(undoID)") }
        func prepareMessage(to: [String], body: String) async throws { calls.append("message \(to.joined(separator: ",")) \(body)") }
        func prepareKakao(body: String) async -> String { calls.append("kakao \(body)"); return "붙여넣고 보내 주세요" }
        func prepareMail(_ m: MailDraft) async throws { calls.append("mail") }
        func contactAddresses(_ name: String, phones: Bool) async -> [String] { [] }
    }

    // MARK: Constants

    func testCalendarConstants() {
        XCTAssertEqual(AgentCalendar.title, "AI 비서")
        XCTAssertEqual(AgentCalendar.calendarKey, "assistant.agentCalendarID")
        XCTAssertEqual(AgentCalendar.reminderListKey, "assistant.agentReminderListID")
        XCTAssertEqual(Set([AgentCalendar.eventPrefix, AgentCalendar.reminderPrefix, AgentCalendar.donePrefix]).count, 3)
        XCTAssertEqual(Composer.kakaoBundleID, "com.kakao.KakaoTalkMac")
    }

    // MARK: Summaries

    func testDatesAreAbsoluteWithWeekday() {
        XCTAssertEqual(NativeSummary.when(day13(15)), "10월 13일 (화) 오후 3:00")
        XCTAssertEqual(NativeSummary.span(day13(15), day13(16)), "10월 13일 (화) 오후 3:00~4:00")
        XCTAssertEqual(NativeSummary.span(day13(11, 30), day13(13)), "10월 13일 (화) 오전 11:30~오후 1:00")
        XCTAssertEqual(NativeSummary.span(day13(22), day13(9, day: 14)), "10월 13일 (화) 오후 10:00~10월 14일 (수) 오전 9:00")
    }

    func testSummaries() {
        let e = EventDraft(title: "치과", start: day13(15), end: day13(16))
        XCTAssertEqual(NativeSummary.eventAdded(e), "일정을 추가했어요: 치과, 10월 13일 (화) 오후 3:00~4:00. 초대는 캘린더 앱에서 해 주세요.")
        XCTAssertEqual(NativeSummary.reminderAdded(ReminderDraft(title: "우유 사기", due: day13(9))), "미리알림을 추가했어요: 우유 사기, 10월 13일 (화) 오전 9:00")
        XCTAssertEqual(NativeSummary.reminderAdded(ReminderDraft(title: "우유 사기")), "미리알림을 추가했어요: 우유 사기")
        XCTAssertEqual(NativeSummary.reminderDone("우유 사기"), "미리알림을 완료했어요: 우유 사기")
        XCTAssertEqual(NativeSummary.reminderDone(""), "미리알림을 완료했어요.")
        for s in [NativeSummary.eventAdded(e), NativeSummary.messagePrepared] { XCTAssertFalse(s.contains("\u{2014}")) }
    }

    // MARK: Dispatch

    func testPerformRunsNativeActions() async throws {
        let f = Fake()
        let id = UUID()
        var r = try await f.perform(.eventAdd(EventDraft(title: "치과", start: day13(15), end: day13(16))), id: id)
        XCTAssertEqual(r.undoID, "e:1")
        XCTAssertTrue(r.summary.contains("10월 13일 (화)"))
        r = try await f.perform(.reminderAdd(ReminderDraft(title: "우유")), id: id)
        XCTAssertEqual(r.undoID, "r:2")
        r = try await f.perform(.reminderDone(id: "X", title: "우유"), id: id)
        XCTAssertEqual(r.undoID, "d:X")
        r = try await f.perform(.messagePrepare(to: [Recipient(name: "엄마", address: "010-1234-5678", provenance: .contact)], body: "곧 가요"), id: id)
        XCTAssertNil(r.undoID)
        XCTAssertEqual(r.summary, NativeSummary.messagePrepared)
        r = try await f.perform(.kakaoPrepare(body: "안녕"), id: id)
        XCTAssertEqual(r.summary, "붙여넣고 보내 주세요")
        XCTAssertNil(r.undoID)
        XCTAssertEqual(f.calls, ["event 치과", "reminder 우유", "done X", "message 010-1234-5678 곧 가요", "kakao 안녕"])
    }

    func testPerformRefusesMailAndOthers() async {
        let f = Fake()
        let mail = MailDraft(accountID: nil, to: [Recipient(name: nil, address: "a@b.c", provenance: .ownerWords)], subject: "s", body: "b")
        let others: [AgentAction] = [.mailSend(mail), .mailReply(mail, inReplyTo: "x"), .shopSearch(query: "하기스", store: nil),
                                     .flightSearch(FlightQuery(from: "GMP", to: "CJU", depart: day13(0))),
                                     .goalCreate(GoalDraft(title: "t", kind: .agent(prompt: "p"))), .memoryAdd(key: "k", value: "v"),
                                     .undo(actionID: "x")]
        for a in others {
            do {
                _ = try await f.perform(a, id: UUID())
                XCTFail("\(a.type) should not run here")
            } catch {
                XCTAssertEqual(error as? NativeActionError, .notNative(a.type))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(f.calls.isEmpty, "nothing ran: \(f.calls)")
    }

    // MARK: Contacts ranking

    private let cards = [
        ContactsFinder.Card(given: "철수", family: "김", emails: ["kim@a.com"], phones: ["010-1111-2222"]),
        ContactsFinder.Card(given: "김철수", emails: ["chulsoo@b.com"]),                         // one-field Korean name
        ContactsFinder.Card(given: "김철수2", emails: ["other@c.com"]),
        ContactsFinder.Card(given: "영희", family: "이", nickname: "김부장", emails: ["boss@d.com"]),
        ContactsFinder.Card(given: "John", family: "Smith", emails: ["john@e.com"]),
        ContactsFinder.Card(given: "민수", family: "박", organization: "철수상회", phones: ["010-9999-0000"]),
        ContactsFinder.Card(given: "철수", family: "최", emails: ["choi@f.com"]),
    ]

    func testScore() {
        XCTAssertEqual(ContactsFinder.score("김철수", cards[0]), 3)
        XCTAssertEqual(ContactsFinder.score("김 철수님", cards[0]), 3)
        XCTAssertEqual(ContactsFinder.score("김철수", cards[1]), 3)
        XCTAssertEqual(ContactsFinder.score("김철수", cards[2]), 1)
        XCTAssertEqual(ContactsFinder.score("김부장님", cards[3]), 3)
        XCTAssertEqual(ContactsFinder.score("john smith", cards[4]), 3)
        XCTAssertEqual(ContactsFinder.score("철수", cards[0]), 2)
        XCTAssertEqual(ContactsFinder.score("철수", cards[5]), 1)
        XCTAssertEqual(ContactsFinder.score("수", cards[0]), 0)
        XCTAssertEqual(ContactsFinder.score("", cards[0]), 0)
    }

    func testRankPutsExactNameFirst() {
        let ranked = ContactsFinder.rank("김철수", cards)
        XCTAssertEqual(ranked.map(\.emails), [["kim@a.com"], ["chulsoo@b.com"], ["other@c.com"]])
        XCTAssertEqual(ContactsFinder.rank("철수", cards).map { $0.family + $0.given }, ["김철수", "최철수", "김철수", "김철수2", "박민수"])
        XCTAssertTrue(ContactsFinder.rank("없는사람", cards).isEmpty)
    }

    func testAddressesComeFromTheBestTierOnly() {
        XCTAssertEqual(ContactsFinder.addresses("김철수", phones: false, in: cards), ["kim@a.com", "chulsoo@b.com"])
        XCTAssertEqual(ContactsFinder.addresses("김철수", phones: true, in: cards), ["kim@a.com", "010-1111-2222", "chulsoo@b.com"])
        XCTAssertEqual(ContactsFinder.addresses("김부장", phones: false, in: cards), ["boss@d.com"])
        // A card with only a phone number is no answer for mail.
        XCTAssertEqual(ContactsFinder.addresses("박민수", phones: false, in: cards), [])
        XCTAssertEqual(ContactsFinder.addresses("박민수", phones: true, in: cards), ["010-9999-0000"])
        XCTAssertEqual(ContactsFinder.addresses("없는사람", phones: true, in: cards), [])
    }

    // MARK: mailto

    func testMailtoEncodesEverything() {
        let url = Composer.mailtoURL(to: ["a@b.com", "c@d.com"], cc: ["e@f.com"], subject: "회의 & 일정", body: "1+1=2\n내일 봬요")
        XCTAssertEqual(url?.absoluteString,
                       "mailto:a@b.com,c@d.com?cc=e@f.com&subject=%ED%9A%8C%EC%9D%98%20%26%20%EC%9D%BC%EC%A0%95&body=1%2B1%3D2%0A%EB%82%B4%EC%9D%BC%20%EB%B4%AC%EC%9A%94")
        XCTAssertEqual(Composer.mailtoURL(to: ["a@b.com"], cc: [], subject: "", body: "")?.absoluteString, "mailto:a@b.com")
    }
}
