import XCTest
@testable import DogMonitor

/// The day's rhythm: calendar alert leads and filters, 출근·점심·퇴근 인사, holidays, the morning count, honest
/// schedule answers, 춤·응원 and the all-missions moment.
final class ScheduleMomentsTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c }()
    private let jelly = Persona(name: "젤리", style: .friendly)

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testWorkHoursWindowsWorkdaysAndHolidays() {
        var w = WorkHours()
        XCTAssertFalse(w.due(.morning, now: at(2026, 10, 19, 9, 5), calendar: cal), "off until turned on")
        w.greet = Set(WorkHours.Kind.allCases)
        // Monday 2026-10-19.
        XCTAssertTrue(w.due(.morning, now: at(2026, 10, 19, 9, 0), calendar: cal))
        XCTAssertFalse(w.due(.morning, now: at(2026, 10, 19, 8, 59), calendar: cal))
        XCTAssertFalse(w.due(.morning, now: at(2026, 10, 19, 12, 0), calendar: cal), "no 좋은 아침 after 3 hours")
        XCTAssertTrue(w.due(.lunch, now: at(2026, 10, 19, 12, 59), calendar: cal))
        XCTAssertFalse(w.due(.lunch, now: at(2026, 10, 19, 13, 0), calendar: cal))
        XCTAssertTrue(w.due(.leave, now: at(2026, 10, 19, 17, 50), calendar: cal))
        XCTAssertFalse(w.due(.leave, now: at(2026, 10, 19, 17, 49), calendar: cal))
        XCTAssertFalse(w.due(.leave, now: at(2026, 10, 19, 18, 0), calendar: cal))
        XCTAssertEqual(w.minutesToEnd(at(2026, 10, 19, 17, 52), calendar: cal), 8)
        // Saturday, 추석 (Friday 2026-09-25) and 대체공휴일 (Monday 2026-10-05): quiet.
        XCTAssertFalse(w.due(.morning, now: at(2026, 10, 17, 9, 30), calendar: cal))
        XCTAssertFalse(w.due(.morning, now: at(2026, 9, 25, 9, 30), calendar: cal))
        XCTAssertFalse(w.due(.lunch, now: at(2026, 10, 5, 12, 10), calendar: cal))
        XCTAssertEqual(WorkHours.day(at(2026, 3, 2, 10, 0), calendar: cal), "2026-03-02")
        // Typed backwards: no 출근 or 퇴근, lunch still.
        w.start = 18 * 60; w.end = 9 * 60
        XCTAssertFalse(w.due(.morning, now: at(2026, 10, 19, 18, 30), calendar: cal))
        XCTAssertFalse(w.due(.leave, now: at(2026, 10, 19, 8, 55), calendar: cal))
        XCTAssertTrue(w.due(.lunch, now: at(2026, 10, 19, 12, 10), calendar: cal))
    }

    func testCalendarLeadsFireOnceNearestFirst() {
        // [15, 5]: 15 at 12 minutes left, then 5; woken up late with both due: only 5, and never 15 after it.
        XCTAssertEqual(CalendarLink.lead([15, 5], minutesLeft: 12, said: []), 15)
        XCTAssertNil(CalendarLink.lead([15, 5], minutesLeft: 12, said: [15]))
        XCTAssertEqual(CalendarLink.lead([15, 5], minutesLeft: 5, said: [15]), 5)
        XCTAssertNil(CalendarLink.lead([15, 5], minutesLeft: 4, said: [15, 5]))
        XCTAssertEqual(CalendarLink.lead([15, 5], minutesLeft: 3, said: []), 5)
        XCTAssertNil(CalendarLink.lead([10], minutesLeft: 11, said: []))
        XCTAssertTrue(CalendarLink.cancelledTitle("취소: 주간 회의"))
        XCTAssertTrue(CalendarLink.cancelledTitle(" Canceled: Weekly sync"))
        XCTAssertFalse(CalendarLink.cancelledTitle("회의 취소 논의"))
    }

    func testMorningBriefAndNudgeParts() {
        let ten = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!   // brief formats in the Mac's zone
        XCTAssertEqual(CalendarLink.brief([(ten, "팀 회의"), (ten, "점심")], reminders: 3), "오늘 일정 2개 · 첫 일정 10:00 '팀 회의' · 미리알림 3개")
        XCTAssertEqual(CalendarLink.brief([], reminders: 0), "오늘 일정 없음")
        XCTAssertEqual(CalendarLink.brief(nil, reminders: nil), "")
        let morning = Nudge.morning(brief: "오늘 일정 없음")
        XCTAssertTrue(morning.templates(polite: false).allSatisfy { $0.hasSuffix("\n오늘 일정 없음") })
        XCTAssertFalse(morning.flavored, "a tail would follow the count")
        let cal = Nudge.calendar(title: "회의", minutes: 3, place: "3층 회의실")
        XCTAssertTrue(cal.template(polite: true).hasSuffix("\n장소: 3층 회의실"))
        XCTAssertEqual(cal.seconds, 120)
        XCTAssertEqual(Nudge.calendar(title: "회의", minutes: 1).seconds, 60)
        XCTAssertEqual(cal.aged(by: 60), .calendar(title: "회의", minutes: 2, place: "3층 회의실"))
        XCTAssertEqual(cal.motion, [.special])
        XCTAssertEqual(Nudge.lunch.motion, [.eat])
        XCTAssertEqual(Nudge.leave(minutes: 9).aged(by: 120), .leave(minutes: 7))
        XCTAssertNil(Nudge.leave(minutes: 1).aged(by: 60))
        for n: Nudge in [.morning(), .lunch, .leave(minutes: 9)] {
            XCTAssertTrue(n.templates(polite: true).allSatisfy { $0.contains("요") })
            XCTAssertFalse((n.templates(polite: true) + n.templates(polite: false)).contains { $0.contains("\u{2014}") })
        }
        // A longer bubble holds unheld lines off for as long as it shows.
        let held = SpeechLine(text: "회의", source: .system, date: ten, hold: true, seconds: 90)
        XCTAssertFalse(held.yields(hold: false, now: ten + 60))
        XCTAssertTrue(held.yields(hold: false, now: ten + 90))
    }

    func testScheduleAnswersSayWhatIsOff() {
        func ask(_ q: String, calendar: Bool, reminders: Bool, _ personal: [String] = []) -> ChatRequest {
            var r = ChatRequest(persona: jelly, summary: "", history: [], facts: [], personal: personal, question: q)
            r.calendarLinked = calendar; r.remindersLinked = reminders
            return r
        }
        XCTAssertEqual(TemplateEngine.fixed(ask("오늘 할 일 뭐 있어?", calendar: true, reminders: false)),
                       "미리알림 연동이 꺼져 있어서 할 일을 볼 수 없어. 비서 설정에서 켜 줘.")
        XCTAssertEqual(TemplateEngine.fixed(ask("오늘 할 일 뭐 있어?", calendar: true, reminders: true)), "오늘 남은 할 일은 없어.")
        XCTAssertEqual(TemplateEngine.fixed(ask("오늘 일정 알려줘", calendar: false, reminders: true, ["할 일: 10:00 보고서"])),
                       "캘린더 연동은 꺼져 있어서 일정은 볼 수 없어. 할 일은 10:00 보고서가 남았어.")
        // Every branch (다음, 몇 시, part of the day) says the calendar is off instead of "남은 일정은 없어".
        for q in ["다음 회의 몇 시야?", "회의 언제야?", "저녁에 약속 있나?"] {
            XCTAssertEqual(TemplateEngine.fixed(ask(q, calendar: false, reminders: true, ["할 일: 10:00 보고서"])),
                           "캘린더 연동은 꺼져 있어서 일정은 볼 수 없어. 할 일은 10:00 보고서가 남았어.", q)
        }
        XCTAssertEqual(TemplateEngine.fixed(ask("오늘 할 일 뭐 있어?", calendar: false, reminders: true, ["할 일: 10:00 보고서"])),
                       "할 일은 10:00 보고서가 남았어.")
        XCTAssertEqual(AssistantPrompt.scheduleLines(ask("오늘 일정?", calendar: false, reminders: true)),
                       ["캘린더: 연동 꺼짐 (일정을 볼 수 없음)", "미리알림: 오늘 남은 할 일 없음"])
        XCTAssertEqual(AssistantPrompt.scheduleLines(ask("오늘 일정?", calendar: true, reminders: false, ["15:00 리뷰"])),
                       ["15:00 리뷰", "미리알림: 연동 꺼짐 (할 일을 볼 수 없음)"])
    }

    func testDanceAndCheerAreFixedAnswers() {
        for q in ["춤춰 줘", "춤 좀 춰봐", "댄스 보여줘"] { XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), .dance, q) }
        for q in ["응원해 줘", "힘 좀 줘", "나 힘내라고 해줘"] { XCTAssertEqual(AssistantIntent.route(q, hasHistory: false), .cheer, q) }
        XCTAssertNotEqual(AssistantIntent.route("춤 배우는 법 알려줘", hasHistory: false), .dance)
        for q in ["춤 좀 배우고 싶어", "춤 좀 배우고 싶은데 어디서 배워?"] { XCTAssertNotEqual(AssistantIntent.route(q, hasHistory: false), .dance, q) }
        for q in ["힘나게 하는 음식 추천해 줘", "힘내는 방법 알려줘", "우울할 때 힘내는 방법 알려줘", "동료한테 힘내라는 카드 문구 써 줘"] {
            XCTAssertNotEqual(AssistantIntent.route(q, hasHistory: false), .cheer, q)
        }
        XCTAssertNotEqual(AssistantIntent.route("요즘 너무 힘들어", hasHistory: false), .cheer, "a feeling, answered as one")
        let r = ChatRequest(persona: jelly, summary: "", history: [], facts: [], personal: [], question: "춤춰 줘")
        let line = TemplateEngine.fixed(r) ?? ""
        XCTAssertTrue(TemplateEngine.danceLines.contains { line.contains($0.0) }, line)
        XCTAssertFalse(TemplateEngine.modelTakes(r))
        for (b, y) in TemplateEngine.danceLines + TemplateEngine.cheerLines { XCTAssertTrue(y.contains("요"), y); XCTAssertFalse((b + y).contains("\u{2014}")) }
    }

    func testAllMissionsDoneOnlyWithTheLastOne() {
        var day = PetDay(day: 3)
        let done: PetEvent = .missionDone(day.missions[0], coins: 5)
        XCTAssertFalse(PetModel.allDone([done], today: day))
        day.done = Set(day.missions)
        XCTAssertTrue(PetModel.allDone([done], today: day))
        XCTAssertFalse(PetModel.allDone([.hungry], today: day), "no mission finished in this batch")
    }

    func testLeaveQuestionAnsweredFromWorkHoursNeverMadeUp() {
        XCTAssertTrue(TemplateEngine.asksLeave("퇴근까지 얼마나 남았어?"))
        XCTAssertTrue(TemplateEngine.asksLeave("퇴근 몇 시야"))
        XCTAssertFalse(TemplateEngine.asksLeave("퇴근하고 싶다"))
        var r = ChatRequest(persona: jelly, summary: "", history: [], facts: [], personal: [], question: "퇴근까지 얼마나 남았어?")
        XCTAssertTrue(TemplateEngine.fixed(r)!.contains("비서 설정"), "no 퇴근 time set: says where to set it")
        XCTAssertFalse(TemplateEngine.modelTakes(r))
        var w = WorkHours(); w.greet = [.leave]
        r.workHours = w
        r.now = at(2026, 10, 19, 16, 40)
        XCTAssertEqual(TemplateEngine.leave(r, false, calendar: cal), "퇴근(18:00)까지 1시간 20분 남았어.")
        r.now = at(2026, 10, 19, 17, 0)
        XCTAssertEqual(TemplateEngine.leave(r, true, calendar: cal), "퇴근(18:00)까지 1시간 남았어요.")
        r.now = at(2026, 10, 19, 17, 55)
        XCTAssertEqual(TemplateEngine.leave(r, false, calendar: cal), "퇴근(18:00)까지 5분 남았어.")
        r.now = at(2026, 10, 19, 18, 30)
        XCTAssertTrue(TemplateEngine.leave(r, false, calendar: cal).contains("지났어"))
    }
}
