import AppKit
import Combine
import Contacts
import Foundation

// 문자·메일·알림 알려주기 (AI 비서, direct build only). Off until the user turns each on.
// Privacy: the text of a message, mail or notification lives in memory only, for the bubble and the on-device chat
// (recentLines). Never written to disk or a log, never sent to the cloud chat or anywhere else. Saved: row numbers.

// The App Store build cannot read other apps' data (sandbox): there only 메일 계정 (IMAP, MailAccounts) comes in,
// through the same batching, mute and preview rules. The databases and Apple Mail parts are #if !MAS.

/// What came in, for one bubble line and the chat's recent list.
struct InboxItem: Equatable {
    enum Kind: String { case message, mail, notification }
    var kind: Kind
    /// Sender (문자, 메일) or app name (알림).
    var who: String
    /// Short one-line text: message text, mail subject, or notification title and body. Nil when there is none.
    var preview: String?
    var date: Date
    /// The mail account it came to ("네이버 메일"), for 메일 계정 (IMAP) mail; nil for Apple Mail and the rest.
    var via: String? = nil
    /// MailAccount.id, so switching one account off forgets only its lines.
    var account: String? = nil
}

/// 문자·메일·알림 options, in AppDefaults.store under "assistant.inbox.*". 메일 itself is AssistantSettings.mail.
final class InboxSettings: ObservableObject {
    static let shared = InboxSettings()
    private let d: UserDefaults

    /// Turning one off forgets where it was, so turning it on later starts from now instead of flooding, and forgets
    /// what came in (the chat's "문자 온 거 있어?" must not recite it after the opt-out). A preview off drops the text.
    @Published var messages: Bool { didSet { d.set(messages, forKey: "assistant.inbox.messages"); if !messages { messagesCursor = nil; InboxCenter.forget(.message) } } }
    @Published var messagesPreview: Bool { didSet { d.set(messagesPreview, forKey: "assistant.inbox.messagesPreview"); if !messagesPreview { InboxCenter.forget(.message, previewOnly: true) } } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "assistant.inbox.notifications"); if !notifications { notificationsCursor = nil; InboxCenter.forget(.notification) } } }
    @Published var notificationsPreview: Bool { didSet { d.set(notificationsPreview, forKey: "assistant.inbox.notificationsPreview"); if !notificationsPreview { InboxCenter.forget(.notification, previewOnly: true) } } }
    @Published var mailSubject: Bool { didSet { d.set(mailSubject, forKey: "assistant.inbox.mailSubject"); if !mailSubject { InboxCenter.forget(.mail, previewOnly: true) } } }
    /// Apps (bundle IDs) whose notifications stay quiet.
    @Published var offApps: Set<String> { didSet { d.set(offApps.sorted(), forKey: "assistant.inbox.offApps") } }

    /// The last row seen in chat.db and in the notification database: numbers only, never content.
    var messagesCursor: Int64? {
        get { (d.object(forKey: "assistant.inbox.messagesCursor") as? NSNumber)?.int64Value }
        set { newValue.map { d.set(NSNumber(value: $0), forKey: "assistant.inbox.messagesCursor") } ?? d.removeObject(forKey: "assistant.inbox.messagesCursor") }
    }
    var notificationsCursor: Int64? {
        get { (d.object(forKey: "assistant.inbox.notificationsCursor") as? NSNumber)?.int64Value }
        set { newValue.map { d.set(NSNumber(value: $0), forKey: "assistant.inbox.notificationsCursor") } ?? d.removeObject(forKey: "assistant.inbox.notificationsCursor") }
    }
    /// 전체 디스크 접근 worked once: a refusal after that is an update re-signing the app (ad-hoc signature).
    var hadAccess: Bool {
        get { d.bool(forKey: "assistant.inbox.hadAccess") }
        set { d.set(newValue, forKey: "assistant.inbox.hadAccess") }
    }
    /// The 전체 디스크 접근 word was said; said again only after access came back and went away again.
    var accessNoticeSaid: Bool {
        get { d.bool(forKey: "assistant.inbox.accessNoticeSaid") }
        set { d.set(newValue, forKey: "assistant.inbox.accessNoticeSaid") }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        d = defaults
        messages = defaults.bool(forKey: "assistant.inbox.messages")
        messagesPreview = defaults.bool(forKey: "assistant.inbox.messagesPreview")
        notifications = defaults.bool(forKey: "assistant.inbox.notifications")
        notificationsPreview = defaults.bool(forKey: "assistant.inbox.notificationsPreview")
        mailSubject = defaults.bool(forKey: "assistant.inbox.mailSubject")
        offApps = Set(defaults.stringArray(forKey: "assistant.inbox.offApps") ?? [])
    }
}

/// Holds what came in while a line is not due, so a burst becomes one line ("문자 3개 왔어"). Pure.
/// Messages and mail are asked for one by one: no 먼저 말 걸기 cooldown, only held while muted.
struct InboxBatcher {
    /// After a line, what comes within this long waits and is said together.
    static let window: TimeInterval = 60
    /// Held longer than this (a long mute) is no news any more.
    static let maxAge: TimeInterval = 30 * 60
    private(set) var held: [InboxItem] = []
    private(set) var lastSaid: Date?

    mutating func add(_ items: [InboxItem]) { held += items }

    /// What to say now as one line (empty: nothing yet).
    mutating func take(now: Date, muted: Bool) -> [InboxItem] {
        held.removeAll { now.timeIntervalSince($0.date) > Self.maxAge }
        guard !held.isEmpty, !muted else { return [] }
        if let lastSaid, now.timeIntervalSince(lastSaid) < Self.window, now >= lastSaid { return [] }
        defer { held = []; lastSaid = now }
        return held
    }
}

/// The bubble words. Pure.
enum InboxLine {
    /// One item: "엄마한테서 문자 왔어: 저녁 먹었어?"; more: "문자 3개 왔어: 엄마, 김철수 외 1명".
    /// 메일 계정 mail starts with its account when all came to one: "네이버 메일: 김철수한테서 메일 왔어: 제목".
    static func line(_ items: [InboxItem], polite: Bool) -> String? {
        guard let first = items.first else { return nil }
        if let via = first.via, items.allSatisfy({ $0.via == via }) {
            return line(items.map { var i = $0; i.via = nil; return i }, polite: polite).map { "\(via): " + $0 }
        }
        let end = polite ? L("왔어요") : L("왔어")
        if items.count == 1 {
            let head: String
            switch first.kind {
            case .message: head = L("\(first.who)한테서 문자 \(end)")
            case .mail: head = L("\(first.who)한테서 메일 \(end)")
            case .notification: head = L("\(first.who) 알림 \(end)")
            }
            return head + (first.preview.map { ": " + short($0) } ?? "")
        }
        var whos: [String] = []
        for i in items where !whos.contains(i.who) { whos.append(i.who) }
        let names = whos.prefix(2).joined(separator: ", ") + (whos.count > 2 ? L(" 외 \(whos.count - 2)") : "")
        switch first.kind {
        case .message: return L("문자 \(items.count)개 \(end): \(names)")
        case .mail: return L("메일 \(items.count)통 \(end): \(names)")
        case .notification: return L("알림 \(items.count)개 \(end): \(names)")
        }
    }

    /// One line, at most `max` characters.
    static func short(_ s: String, max: Int = 30) -> String {
        let one = s.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    /// For the chat (recentLines): "14:05 문자 엄마: 저녁 먹었어?", with the date when not from today ("10/3 23:50").
    static func recent(_ i: InboxItem, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(i.date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        let kind = i.kind == .message ? L("문자") : i.kind == .mail ? (i.via ?? L("메일")) : L("알림")
        return "\(f.string(from: i.date)) \(kind) \(i.who)" + (i.preview.map { ": " + short($0, max: 60) } ?? "")
    }

    #if !MAS
    /// What 전체 디스크 접근 needs, for 비서 설정.
    static func accessHelp(_ a: InboxAccess, hadAccess: Bool, notifications: Bool) -> String? {
        switch a {
        case .ok: return nil
        case .denied where hadAccess:
            return L("앱이 업데이트되면서 '전체 디스크 접근' 허용이 풀렸어요. 설정에서 캐릭모니터를 한 번 껐다가 다시 켜 주세요. 그래도 안 되면 목록에서 빼고(−) 다시 추가해 주세요.")
        case .denied:
            return L("문자·메일·카톡 알림을 대신 말해드리려면 '전체 디스크 접근' 허용이 필요해요. '시스템 설정 열기'를 누르고 목록에서 캐릭모니터를 켜 주세요. 켠 뒤에는 앱을 한 번 다시 실행해 주세요. 알림 내용은 이 맥 안에서 말풍선으로만 보여주고, 어디에도 저장하거나 보내지 않아요.")
        case .missing:
            return notifications ? L("이 macOS 버전에서는 알림 기록 위치가 바뀌어서 아직 읽을 수 없어요. 다음 업데이트에서 맞춰 드릴게요.")
                                 : L("이 맥에서 메시지 기록을 찾지 못했어요. 메시지 앱에 로그인했는지 확인해 주세요.")
        }
    }
    #endif
}

/// Polls chat.db and the notification database every 30 s and Mail every minute, then says what came in.
/// AssistantCenter.start() starts it. Works only while a switch is on.
@MainActor
final class InboxCenter: ObservableObject {
    static let shared = InboxCenter()
    let settings = InboxSettings.shared

    #if !MAS
    /// Last check of each database (nil: not checked yet), for 비서 설정.
    @Published private(set) var messagesAccess: InboxAccess?
    @Published private(set) var notificationsAccess: InboxAccess?
    /// Apps that notify most, for the 앱별 끄기 list.
    @Published private(set) var topApps: [String] = []

    /// A row older than this when found is history (Messages in iCloud syncing old chats), not news.
    static let fresh: TimeInterval = 30 * 60
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private var seenMail: Set<Int>?
    /// Notifications said lately (hashes), so one posted again is not said again.
    private var seenNotifications: [Int: Date] = [:]
    private var polling = false
    private var missingSaid = false
    /// ponytail: names are looked up on the main thread (a few ms, once per sender); move to a queue if it shows.
    private let contacts = CNContactStore()
    private var names: [String: String] = [:]
    private var appNames: [String: String] = [:]
    #endif

    static let interval: TimeInterval = 30
    private var batches: [InboxItem.Kind: InboxBatcher] = [:]
    private var tick = 0
    private var timer: Timer?

    private nonisolated static let recentLock = NSLock()
    private nonisolated(unsafe) static var recent: [InboxItem] = []
    static let recentMax = 10

    func start() {
        guard timer == nil else { return }
        // The chat's "가장 최근에 온 문자 알려줘": looked up right then, off the main thread (it opens the databases).
        // Never the cloud (inbox questions get the template answer, InboxReport.answer).
        AssistantContext.inbox = { q in
            let mailOn = AssistantSettings.shared.mail || MailAccounts.shared.anyOn
            let memory = InboxCenter.memory()
            return await Task.detached(priority: .userInitiated) {
                InboxCenter.report(q, settings: .shared, mailOn: mailOn, memory: memory)
            }.value
        }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.everyTick() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The last 10 things that came in, oldest first, from switched-on mail accounts. Memory only. Callers must not
    /// send these to the cloud engine: they hold other people's words.
    nonisolated static func memory() -> [InboxItem] {
        let accounts = MailAccounts.shared
        recentLock.lock()
        defer { recentLock.unlock() }
        return recent.filter { $0.account.map(accounts.isOn) ?? true }
    }

    /// One inbox question, answered from what is there now: chat.db and the notification database read on the spot
    /// (texts from before the app started too), mail from what came in since launch (`memory`: the app keeps none).
    /// Each asked kind says whether it is off, unreadable (and why) or read. Blocking: call off the main thread.
    nonisolated static func report(_ q: InboxQuery, settings s: InboxSettings, mailOn: Bool, memory: [InboxItem],
                                   names: ((String) -> String)? = nil) -> InboxReport {
        var r = InboxReport()
        var found: [InboxItem] = []
        if !s.messagesPreview { r.previewOff.insert(.message) }
        if !s.notificationsPreview { r.previewOff.insert(.notification) }
        if !s.mailSubject { r.previewOff.insert(.mail) }
        if q.kinds.contains(.mail) {
            r.states[.mail] = mailOn ? .ok : .off
            if mailOn { found += memory.filter { $0.kind == .mail } }
        }
        #if MAS
        for k in [InboxItem.Kind.message, .notification] where q.kinds.contains(k) { r.states[k] = .unavailable }
        #else
        // A sender to find: a longer page to pick from.
        let page = q.who.isEmpty ? q.skip + q.limit : 200
        func why(_ a: InboxAccess) -> InboxReport.State { a == .denied ? (s.hadAccess ? .deniedAfterUpdate : .denied) : .missing }
        if q.kinds.contains(.message) {
            let db = MessagesDB(path: messagesPath)
            if !s.messages { r.states[.message] = .off }
            else if let rows = db.latest(limit: page, in: q.period) {
                r.states[.message] = .ok
                let store = CNContactStore()
                var cache: [String: String] = [:]
                let name = names ?? { h in ContactNames.name(h, store: store) ?? ContactNames.mask(h) }
                found += rows.map { row in
                    let who = cache[row.handle] ?? name(row.handle)
                    cache[row.handle] = who
                    let text = row.text.map { InboxLine.short($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 } ?? L("사진이나 파일을 보냈어요")
                    return InboxItem(kind: .message, who: who, preview: text, date: row.date)
                }
            } else { r.states[.message] = why(db.access()) }
        }
        if q.kinds.contains(.notification) {
            let db = NotificationsDB(path: notificationsPath)
            if !s.notifications { r.states[.notification] = .off }
            else if let rows = db.latest(limit: 200, in: q.period) {   // a page: apps switched off are left out after
                r.states[.notification] = .ok
                var skip: Set<String> = []
                if s.messages { skip.insert("com.apple.MobileSMS") }
                if mailOn { skip.insert(MailLink.bundleID) }
                found += rows.filter { $0.hasText && NotificationsDB.shouldSay($0.bundle, off: s.offApps, skip: skip) }.map { row in
                    let text = [row.title, row.body].compactMap { $0 }.joined(separator: ": ")
                    return InboxItem(kind: .notification, who: NotificationsDB.appName(row.bundle), preview: text.isEmpty ? nil : text, date: row.date)
                }
            } else { r.states[.notification] = why(db.access()) }
        }
        #endif
        return r.answering(q, found: found)
    }

    #if !MAS
    /// Where report() reads; tests point these at made-up databases.
    nonisolated(unsafe) static var messagesPath = MessagesDB.path
    nonisolated(unsafe) static var notificationsPath = NotificationsDB.path
    #endif

    /// Drops what came in of one kind (a switch turned off), or only its text (a preview turned off). `only` narrows it
    /// (one mail account, or Apple Mail alone).
    nonisolated static func forget(_ kind: InboxItem.Kind, previewOnly: Bool = false, only: (InboxItem) -> Bool = { _ in true }) {
        recentLock.lock()
        defer { recentLock.unlock() }
        if previewOnly { recent = recent.map { var i = $0; if i.kind == kind { i.preview = nil }; return i } }
        else { recent.removeAll { $0.kind == kind && only($0) } }
    }

    /// New 메일 계정 mail (MailAccounts.poll).
    func mailArrived(_ items: [InboxItem]) {
        add(items, kind: .mail)
        flush()
    }

    #if !MAS
    /// Closes the popover; opening it again within 10 minutes comes back to 비서 설정's 연동 panel.
    static func openFullDiskAccess() { PermissionFlow.openSettings(settingsURL) }

    /// Checks the switched-on databases now (비서 설정 opening, a switch turned on) and lists the apps that notify
    /// most. Nothing is opened while both switches are off.
    func refresh() {
        let wantM = settings.messages, wantN = settings.notifications
        guard wantM || wantN else { return }
        names = [:]   // 연락처 may have just been allowed
        // QA render (its own defaults suite): made-up state, never the developer's own chat.db or notification apps.
        if AppDefaults.store !== UserDefaults.standard {
            messagesAccess = wantM ? .ok : nil
            notificationsAccess = wantN ? .ok : nil
            topApps = wantN ? ["com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap"] : []
            return
        }
        Task.detached(priority: .utility) {
            let m = wantM ? MessagesDB().access() : nil, n = wantN ? NotificationsDB().access() : nil
            let apps = n == .ok ? NotificationsDB().topApps() : []
            await MainActor.run {
                if let m { self.messagesAccess = m }
                if let n { self.notificationsAccess = n }
                self.topApps = apps.filter { NotificationsDB.shouldSay($0, off: [], skip: []) }
            }
        }
    }

    func appName(_ bundle: String) -> String {
        if let n = appNames[bundle] { return n }
        let n = NotificationsDB.appName(bundle)
        appNames[bundle] = n
        return n
    }

    #endif

    private func everyTick() {
        tick += 1
        #if !MAS
        if (settings.messages || settings.notifications) && !polling { pollDatabases() }
        // Turned on again later: learn first, no flood. Only Apple Mail's lines: 메일 계정 has its own switches.
        if !AssistantSettings.shared.mail { seenMail = nil; Self.forget(.mail) { $0.account == nil } }
        else if tick % 2 == 0 { pollMail() }
        #endif
        if MailAccounts.shared.anyOn { Task { await MailAccounts.shared.poll() } }   // each account every 2 minutes
        flush()
    }

    #if !MAS

    // MARK: Databases

    /// One poll step: the first run (no cursor) only learns where the table ends; later runs return rows after the
    /// cursor and move it. A cursor past the end (the database was rebuilt) moves back to the end. Pure.
    nonisolated static func step<Row>(cursor: Int64?, max: () -> Int64?, fetch: (Int64) -> [Row]?, id: (Row) -> Int64)
        -> (ok: Bool, cursor: Int64?, rows: [Row]) {
        guard let cursor else { return max().map { (true, $0, []) } ?? (false, nil, []) }
        guard let rows = fetch(cursor) else { return (false, cursor, []) }
        if let last = rows.last { return (true, id(last), rows) }
        if let end = max(), end < cursor { return (true, end, []) }
        return (true, cursor, [])
    }

    private func pollDatabases() {
        polling = true
        let wantM = settings.messages, wantN = settings.notifications
        let mc = settings.messagesCursor, nc = settings.notificationsCursor
        // Rows older than `fresh` (a backlog after a week off, Messages in iCloud syncing old chats) are skipped in
        // the query itself, so they never use up the 50-row page ahead of a text that just came in.
        let since = Date().addingTimeInterval(-Self.fresh)
        Task.detached(priority: .utility) {
            let mdb = MessagesDB(), ndb = NotificationsDB()
            let m = wantM ? Self.step(cursor: mc, max: mdb.maxRowID, fetch: { mdb.messages(after: $0, since: since) }, id: \.rowID) : nil
            let n = wantN ? Self.step(cursor: nc, max: ndb.maxRecID, fetch: { ndb.records(after: $0, since: since) }, id: \.recID) : nil
            // Only a failed read needs to know why (one more open).
            let ma = m.map { $0.ok ? InboxAccess.ok : mdb.access() }, na = n.map { $0.ok ? InboxAccess.ok : ndb.access() }
            await MainActor.run { self.received(m, ma, n, na) }
        }
    }

    private func received(_ m: (ok: Bool, cursor: Int64?, rows: [MessagesDB.Row])?, _ ma: InboxAccess?,
                          _ n: (ok: Bool, cursor: Int64?, rows: [NotificationsDB.Row])?, _ na: InboxAccess?) {
        polling = false
        let now = Date()
        if let m, settings.messages {
            settings.messagesCursor = m.cursor
            messagesAccess = ma
            add(m.rows.filter { now.timeIntervalSince($0.date) < Self.fresh }.map(messageItem), kind: .message)
        }
        if let n, settings.notifications {
            settings.notificationsCursor = n.cursor
            notificationsAccess = na
            var skip: Set<String> = []
            if settings.messages { skip.insert("com.apple.MobileSMS") }
            if AssistantSettings.shared.mail { skip.insert(MailLink.bundleID) }
            let rows = NotificationsDB.unseen(n.rows.filter {
                $0.hasText && now.timeIntervalSince($0.date) < Self.fresh && NotificationsDB.shouldSay($0.bundle, off: settings.offApps, skip: skip)
            }, seen: &seenNotifications, now: now)
            add(rows.map(notificationItem), kind: .notification)
        }
        noticeIfNeeded()
        flush()
    }

    private func messageItem(_ r: MessagesDB.Row) -> InboxItem {
        let who = names[r.handle] ?? {
            let n = ContactNames.name(r.handle, store: contacts) ?? ContactNames.mask(r.handle)
            names[r.handle] = n
            return n
        }()
        let text = r.text.map { InboxLine.short($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 } ?? L("사진이나 파일을 보냈어요")
        return InboxItem(kind: .message, who: who, preview: settings.messagesPreview ? text : nil, date: r.date)
    }

    private func notificationItem(_ r: NotificationsDB.Row) -> InboxItem {
        let text = [r.title, r.body].compactMap { $0 }.joined(separator: ": ")
        return InboxItem(kind: .notification, who: appName(r.bundle),
                         preview: settings.notificationsPreview && !text.isEmpty ? text : nil, date: r.date)
    }

    /// 전체 디스크 접근 taken away or never given: the switches stay on, and the word is said once (bubble and 비서 설정).
    private func noticeIfNeeded() {
        let all = [settings.messages ? messagesAccess : nil, settings.notifications ? notificationsAccess : nil].compactMap { $0 }
        if all.contains(.denied) {
            guard !settings.accessNoticeSaid else { return }
            settings.accessNoticeSaid = true
            notice(settings.hadAccess ? L("업데이트로 '전체 디스크 접근' 허용이 풀렸어요. 비서 설정에서 다시 켜는 법을 확인해 주세요.")
                                      : L("문자·알림을 알려드리려면 '전체 디스크 접근' 허용이 필요해요. 비서 설정을 확인해 주세요."))
        } else if all.contains(.ok) {
            settings.hadAccess = true
            settings.accessNoticeSaid = false
        }
        if settings.notifications && notificationsAccess == .missing && !missingSaid {
            missingSaid = true
            notice(L("이 macOS 버전에서는 알림 기록 위치가 바뀌어서 아직 다른 앱 알림을 읽을 수 없어요."))
        }
    }

    private func notice(_ why: String) {
        AssistantSettings.shared.integrationNotice = why
        SpeechBubbleCenter.shared.say(text: why, source: .system, aloud: false)
    }

    // MARK: Mail

    private func pollMail() {
        Task {
            switch await MailLink.poll() {
            case .unread(let items):
                let (new, seen) = MailLink.fresh(items, seen: seenMail)
                seenMail = seen
                let now = Date()
                add(new.reversed().map { InboxItem(kind: .mail, who: $0.sender,
                                                   preview: settings.mailSubject && !$0.subject.isEmpty ? $0.subject : nil, date: now) }, kind: .mail)
                flush()
            case .denied:
                AssistantSettings.shared.mail = false
                seenMail = nil
                notice(L("Mail 제어 허용이 꺼져 있어서 메일 알림을 껐어요. 비서 설정에서 다시 켜 주세요."))
            case .unavailable:
                break
            }
        }
    }

    #endif

    // MARK: Saying

    private func add(_ items: [InboxItem], kind: InboxItem.Kind) {
        guard !items.isEmpty else { return }
        batches[kind, default: InboxBatcher()].add(items)
        Self.recentLock.lock()
        Self.recent = Array((Self.recent + items).suffix(Self.recentMax))
        Self.recentLock.unlock()
    }

    /// At most one line per call (one bubble at a time); the rest waits for the next tick. Held, not said, while the
    /// screen may be shared (MeetingMute.screenMaybeShared): the line can carry a sender and their words.
    private func flush() {
        let muted = SpeechBubbleCenter.shared.isMuted() || MeetingMute.screenMaybeShared()
        let polite = !AssistantModel.persona().style.banmal
        let apple = AssistantSettings.shared.mail, accounts = MailAccounts.shared
        let on: [InboxItem.Kind: Bool] = [.message: settings.messages, .mail: apple || accounts.anyOn, .notification: settings.notifications]
        let preview: [InboxItem.Kind: Bool] = [.message: settings.messagesPreview, .mail: settings.mailSubject, .notification: settings.notificationsPreview]
        for kind in [InboxItem.Kind.message, .mail, .notification] {
            guard on[kind] == true else { batches[kind] = nil; continue }   // switched off while held: never said
            let items = batches[kind, default: InboxBatcher()].take(now: Date(), muted: muted)
                .filter { i in i.account.map(accounts.isOn) ?? (kind != .mail || apple) }   // its switch went off while held
                .map { var i = $0; if preview[kind] != true { i.preview = nil }; return i }
            guard let line = InboxLine.line(items, polite: polite) else { continue }
            // Same words again is new news (a second text from 엄마): past the 10-minute repeat gate. Not shown
            // (muted meanwhile): back in the batch for the next tick.
            if !SpeechBubbleCenter.shared.say(text: line, source: .assistant, repeats: true, closable: true) { batches[kind]?.add(items) }
            return
        }
    }
}
