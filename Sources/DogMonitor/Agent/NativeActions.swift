import AppKit
import Contacts
import EventKit
import Foundation

// 비서가 행동하기: the native (non-mail) side of the Executor. EventKit writes go into a dedicated "AI 비서" calendar and
// reminder list, so the owner can see (and the preapproved rule can target) everything the agent made, and each write
// returns an undo id kept for 10 minutes. Messages and KakaoTalk are prepare-only: the app fills a compose sheet or the
// clipboard and the owner presses send. Contacts are read only to turn a name the owner typed into addresses; the
// addresses never go to the AI (only to the mail server or the compose sheet). Every permission is asked on first need.

/// What the Executor calls for native actions. A protocol so PendingActions tests and the integrator can inject fakes;
/// `perform` (below) is shared by every implementation.
protocol NativeActing {
    /// Saves the event; returns the undo id.
    func addEvent(_ e: EventDraft) async throws -> String
    /// Saves the reminder; returns the undo id.
    func addReminder(_ r: ReminderDraft) async throws -> String
    /// Marks it done; returns the undo id, nil when it was already done (nothing to take back).
    func completeReminder(id: String) async throws -> String?
    /// Takes back an add or a done by the id the call returned. An item the owner already deleted counts as undone.
    func undo(_ undoID: String) async throws
    /// The Messages compose sheet with recipients and body filled in.
    func prepareMessage(to: [String], body: String) async throws
    /// Copies to the clipboard and opens KakaoTalk; returns what to tell the owner.
    func prepareKakao(body: String) async -> String
    /// The mail compose sheet: iCloud accounts (no SMTP in v1) and the fallback after a failed send.
    func prepareMail(_ m: MailDraft) async throws
    /// A name the owner typed to addresses (emails, plus phone numbers when `phones`). Asks for Contacts on first use.
    func contactAddresses(_ name: String, phones: Bool) async -> [String]
}

enum NativeActionError: LocalizedError, Equatable {
    /// Not a native action (mail goes to MailSender, links and goals elsewhere).
    case notNative(AgentActionType)
    /// What to show: a missing permission (with where to allow it), a vanished item, a failed save.
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notNative: return L("이 일은 여기서 할 수 없어요.")
        case .message(let s): return s
        }
    }
}

extension NativeActing {
    /// Runs one approved native action. `id` is the FrozenAction id: unused here (EventKit saves are never retried),
    /// kept so every executor path has the same shape as MailSender's.
    func perform(_ action: AgentAction, id: UUID) async throws -> (summary: String, undoID: String?) {
        switch action {
        case .eventAdd(let e):
            return (NativeSummary.eventAdded(e), try await addEvent(e))
        case .reminderAdd(let r):
            return (NativeSummary.reminderAdded(r), try await addReminder(r))
        case .reminderDone(let rid, let title):
            return (NativeSummary.reminderDone(title), try await completeReminder(id: rid))
        case .messagePrepare(let to, let body):
            try await prepareMessage(to: to.map(\.address), body: body)
            return (NativeSummary.messagePrepared, nil)
        case .kakaoPrepare(let body):
            return (await prepareKakao(body: body), nil)
        default:
            throw NativeActionError.notNative(action.type)
        }
    }
}

/// What the owner reads after an action ran. Dates are absolute with the weekday ("10월 13일 (화) 오후 3:00~4:00"),
/// never "내일": the line stays in the chat and is read later.
enum NativeSummary {
    static func eventAdded(_ e: EventDraft) -> String {
        L("일정을 추가했어요: \(e.title), \(span(e.start, e.end)). 초대는 캘린더 앱에서 해 주세요.")
    }

    static func reminderAdded(_ r: ReminderDraft) -> String {
        guard let due = r.due else { return L("미리알림을 추가했어요: \(r.title)") }
        return L("미리알림을 추가했어요: \(r.title), \(when(due))")
    }

    static func reminderDone(_ title: String) -> String {
        title.isEmpty ? L("미리알림을 완료했어요.") : L("미리알림을 완료했어요: \(title)")
    }

    static var messagePrepared: String { L("메시지 앱에 받는 사람과 내용을 채워 두었어요. 확인하고 직접 보내 주세요.") }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = format
        return f
    }

    /// "10월 13일 (화) 오후 3:00".
    static func when(_ d: Date) -> String {
        formatter(appIsEnglish ? "MMM d (E) h:mm a" : "M월 d일 (E) a h:mm").string(from: d)
    }

    /// "10월 13일 (화) 오후 3:00~4:00"; the end's day only when it differs, its 오전/오후 only when it changes.
    static func span(_ start: Date, _ end: Date) -> String {
        let cal = Calendar.current
        guard cal.isDate(start, inSameDayAs: end) else { return "\(when(start))~\(when(end))" }
        let sameHalf = (cal.component(.hour, from: start) < 12) == (cal.component(.hour, from: end) < 12)
        let time = sameHalf ? "h:mm" : (appIsEnglish ? "h:mm a" : "a h:mm")
        return "\(when(start))~\(formatter(time).string(from: end))"
    }
}

// MARK: - Calendar and reminders

/// EventKit writes into the "AI 비서" calendar and list. Shares CalendarLink's store and its permission request (full
/// access on macOS 14+), so a grant made for reading counts here too.
enum AgentCalendar {
    /// The calendar's and list's name as the owner sees it in Calendar and Reminders.
    static var title: String { L("AI 비서") }
    /// Where the made calendar's and list's identifiers are remembered (AssistantSettings may expose the same keys).
    static let calendarKey = "assistant.agentCalendarID"
    static let reminderListKey = "assistant.agentReminderListID"
    /// Undo id prefixes: an added event, an added reminder, a reminder marked done.
    static let eventPrefix = "e:", reminderPrefix = "r:", donePrefix = "d:"

    private static var store: EKEventStore { CalendarLink.shared.store }

    private static func allow(_ type: EKEntityType) async throws {
        if let why = await CalendarLink.shared.request(type) { throw NativeActionError.message(why) }
    }

    /// The remembered calendar, else one titled "AI 비서" (the remembered id was lost), else a new one in the default
    /// calendar's account. Falls back to the default calendar when the account refuses new calendars (some Exchange
    /// and read-only setups).
    static func target(_ type: EKEntityType, defaults: UserDefaults = AppDefaults.store) -> EKCalendar? {
        let key = type == .event ? calendarKey : reminderListKey
        let fallback = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        if let id = defaults.string(forKey: key), let c = store.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        if let c = store.calendars(for: type).first(where: { $0.title == title && $0.allowsContentModifications }) {
            defaults.set(c.calendarIdentifier, forKey: key)
            return c
        }
        guard let source = fallback?.source else { return fallback }
        let c = EKCalendar(for: type, eventStore: store)
        c.title = title
        c.source = source
        guard (try? store.saveCalendar(c, commit: true)) != nil else { return fallback }
        defaults.set(c.calendarIdentifier, forKey: key)
        return c
    }

    static func addEvent(_ d: EventDraft) async throws -> String {
        try await allow(.event)
        guard let cal = target(.event) else { throw NativeActionError.message(L("일정을 넣을 캘린더가 없어요. 캘린더 앱에서 캘린더를 하나 만들어 주세요.")) }
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = d.title
        e.startDate = d.start
        e.endDate = d.end
        e.location = d.location
        e.notes = d.notes
        do { try store.save(e, span: .thisEvent, commit: true) } catch { throw NativeActionError.message(L("캘린더에 저장하지 못했어요.")) }
        return eventPrefix + (e.eventIdentifier ?? e.calendarItemIdentifier)
    }

    static func addReminder(_ d: ReminderDraft) async throws -> String {
        try await allow(.reminder)
        guard let list = target(.reminder) else { throw NativeActionError.message(L("미리알림을 넣을 목록이 없어요. 미리알림 앱에서 목록을 하나 만들어 주세요.")) }
        let r = EKReminder(eventStore: store)
        r.calendar = list
        r.title = d.title
        r.notes = d.notes
        if let due = d.due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))   // a due date alone does not always ring
        }
        do { try store.save(r, commit: true) } catch { throw NativeActionError.message(L("미리알림에 저장하지 못했어요.")) }
        return reminderPrefix + r.calendarItemIdentifier
    }

    static func completeReminder(id: String) async throws -> String? {
        try await allow(.reminder)
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw NativeActionError.message(L("그 미리알림을 찾지 못했어요.")) }
        if r.isCompleted { return nil }
        r.isCompleted = true
        do { try store.save(r, commit: true) } catch { throw NativeActionError.message(L("미리알림을 완료하지 못했어요.")) }
        return donePrefix + id
    }

    static func undo(_ undoID: String) async throws {
        let id = String(undoID.dropFirst(2))
        switch String(undoID.prefix(2)) {
        case eventPrefix:
            try await allow(.event)
            guard let e = store.event(withIdentifier: id) else { return }
            do { try store.remove(e, span: .thisEvent, commit: true) } catch { throw NativeActionError.message(L("일정을 지우지 못했어요.")) }
        case reminderPrefix:
            try await allow(.reminder)
            guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
            do { try store.remove(r, commit: true) } catch { throw NativeActionError.message(L("미리알림을 지우지 못했어요.")) }
        case donePrefix:
            try await allow(.reminder)
            guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw NativeActionError.message(L("그 미리알림을 찾지 못했어요.")) }
            r.isCompleted = false
            do { try store.save(r, commit: true) } catch { throw NativeActionError.message(L("미리알림을 되돌리지 못했어요.")) }
        default:
            throw NativeActionError.message(L("되돌릴 수 없는 일이에요."))
        }
    }
}

// MARK: - Contacts

/// A name the owner typed to the addresses on its card. Korean names are often stored in one field ("김철수" as the
/// given name) or split ("김" + "철수"), so both orders and the nickname count as the full name.
enum ContactsFinder {
    struct Card: Equatable {
        var given = "", family = "", nickname = "", organization = ""
        var jobTitle = ""
        var emails: [String] = [], phones: [String] = []
    }

    static var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    /// A bare build (no usage string) would be killed by the system on the request.
    static var canAsk: Bool { Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil }

    /// Asks the first time a name needs an address. False without permission (the planner then asks for the address).
    static func requestIfNeeded() async -> Bool {
        if authorized { return true }
        guard canAsk, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// "김 철수님" -> "김철수": no spaces, no case, no 님/씨.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased().filter { !$0.isWhitespace }
        for suffix in ["님", "씨"] where t.hasSuffix(suffix) && t.count > 2 { t.removeLast() }
        return t
    }

    /// Titles Koreans address colleagues by ("김부장님"): the family name plus the card's job title.
    static let titles = ["부장", "차장", "과장", "대리", "주임", "사원", "팀장", "실장", "본부장", "이사", "상무", "전무", "사장",
                         "대표", "원장", "선생", "교수", "매니저", "책임", "선임", "수석", "프로"]

    /// 3 the full name (either order) or nickname, 2 the given name alone, 1 part of the name or the organization, 0 none.
    static func score(_ query: String, _ c: Card) -> Int {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let given = normalize(c.given), family = normalize(c.family)
        let full = [family + given, given + family, normalize(c.nickname)].filter { !$0.isEmpty }
        if full.contains(q) { return 3 }
        if given == q { return 2 }
        // "김부장" -> family 김 and a job title with 부장 (measured 2026-10-05: titles are how people name colleagues).
        if let t = titles.first(where: { q.hasSuffix($0) && q.count > $0.count }), !c.jobTitle.isEmpty,
           normalize(c.jobTitle).contains(t), (family.isEmpty ? String((given + family).prefix(1)) : family) == String(q.dropLast(t.count)) {
            return 2
        }
        if q.count >= 2, full.contains(where: { $0.contains(q) }) || normalize(c.organization).contains(q) { return 1 }
        return 0
    }

    /// Matching cards, best first (exact name before a partial or company match). Stable within a score.
    static func rank(_ query: String, _ cards: [Card]) -> [Card] {
        let scored: [(score: Int, card: Card)] = cards.map { (score(query, $0), $0) }
        // Swift's sort is stable, so equal scores keep the address book's order.
        return scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }.map(\.card)
    }

    /// The addresses of the best-scoring cards only, so an exact "김철수" is not mixed with "김철수 (회사)" partials.
    /// Emails, plus phone numbers when `phones` (Messages takes both). Two or more come back as choice chips.
    static func addresses(_ name: String, phones: Bool, in cards: [Card]) -> [String] {
        let usable = cards.filter { !$0.emails.isEmpty || (phones && !$0.phones.isEmpty) }
        let best = usable.map { score(name, $0) }.max() ?? 0
        guard best > 0 else { return [] }
        var seen = Set<String>()
        return usable.filter { score(name, $0) == best }.flatMap { $0.emails + (phones ? $0.phones : []) }.filter { seen.insert($0).inserted }
    }

    /// Every card's name fields and addresses. Blocking: call off the main thread.
    /// ponytail: reads the whole address book per lookup (a few thousand cards is milliseconds); cache if it shows.
    static func cards(store: CNContactStore = CNContactStore()) -> [Card] {
        guard authorized else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        var out: [Card] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            out.append(Card(given: c.givenName, family: c.familyName, nickname: c.nickname, organization: c.organizationName,
                            jobTitle: c.jobTitle, emails: c.emailAddresses.map { $0.value as String }, phones: c.phoneNumbers.map { $0.value.stringValue }))
        }
        return out
    }

    /// For AgentPlanner.Lookup (synchronous): [] until Contacts is allowed. Blocking.
    static func addresses(_ name: String, phones: Bool = false) -> [String] {
        addresses(name, phones: phones, in: cards())
    }
}

// MARK: - Compose sheets and KakaoTalk

/// Prepare-only paths: the app fills, the owner sends.
@MainActor
enum Composer {
    nonisolated static let kakaoBundleID = "com.kakao.KakaoTalkMac"

    /// Mail's compose window. NSSharingService has no Cc, so a draft with Cc goes through a mailto link instead.
    static func composeEmail(to: [String], cc: [String], subject: String, body: String) throws {
        if cc.isEmpty, let s = NSSharingService(named: .composeEmail), s.canPerform(withItems: [body]) {
            s.recipients = to
            s.subject = subject
            s.perform(withItems: [body])
            return
        }
        guard let url = mailtoURL(to: to, cc: cc, subject: subject, body: body), NSWorkspace.shared.open(url) else {
            throw NativeActionError.message(L("메일 쓰기 창을 열지 못했어요."))
        }
    }

    /// RFC 6068 mailto. Values are percent-encoded by hand: URLComponents leaves "&", "=" and "+" alone.
    nonisolated static func mailtoURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: safe) ?? "" }
        func addrs(_ a: [String]) -> String {
            a.map { $0.addingPercentEncoding(withAllowedCharacters: safe.union(CharacterSet(charactersIn: "@"))) ?? "" }.joined(separator: ",")
        }
        var fields: [String] = []
        if !cc.isEmpty { fields.append("cc=" + addrs(cc)) }
        if !subject.isEmpty { fields.append("subject=" + enc(subject)) }
        if !body.isEmpty { fields.append("body=" + enc(body)) }
        let head = "mailto:" + addrs(to)
        return URL(string: fields.isEmpty ? head : head + "?" + fields.joined(separator: "&"))
    }

    /// Messages' compose window (iMessage and SMS); the owner presses send.
    static func composeMessage(to: [String], body: String) throws {
        guard let s = NSSharingService(named: .composeMessage), s.canPerform(withItems: [body]) else {
            throw NativeActionError.message(L("메시지 앱을 열지 못했어요."))
        }
        s.recipients = to
        s.perform(withItems: [body])
    }

    /// KakaoTalk has no public API and driving it by Accessibility breaks its terms: the clipboard and the app, nothing more.
    static func kakaoPrepare(body: String) -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kakaoBundleID) else {
            return L("메시지를 복사했어요. 이 맥에 카카오톡이 없어서 열지는 못했어요. 카카오톡에 붙여넣고 보내 주세요.")
        }
        External.openApp(at: app)
        return L("메시지를 복사하고 카카오톡을 열었어요. 받는 사람을 골라 붙여넣고 보내 주세요.")
    }
}

// MARK: - The live implementation

struct NativeActions: NativeActing {
    func addEvent(_ e: EventDraft) async throws -> String { try await AgentCalendar.addEvent(e) }
    func addReminder(_ r: ReminderDraft) async throws -> String { try await AgentCalendar.addReminder(r) }
    func completeReminder(id: String) async throws -> String? { try await AgentCalendar.completeReminder(id: id) }
    func undo(_ undoID: String) async throws { try await AgentCalendar.undo(undoID) }
    func prepareMessage(to: [String], body: String) async throws { try await Composer.composeMessage(to: to, body: body) }
    func prepareKakao(body: String) async -> String { await Composer.kakaoPrepare(body: body) }

    func prepareMail(_ m: MailDraft) async throws {
        try await Composer.composeEmail(to: m.to.map(\.address), cc: m.cc.map(\.address), subject: m.subject, body: m.body)
    }

    func contactAddresses(_ name: String, phones: Bool) async -> [String] {
        guard await ContactsFinder.requestIfNeeded() else { return [] }
        return await Task.detached { ContactsFinder.addresses(name, phones: phones) }.value
    }
}
