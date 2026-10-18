import AppKit
import CoreAudio
import AVFoundation
import CoreImage
import EventKit
import Foundation

// The opt-in links of the AI 비서: iPhone notifications, charamonitor://say, calendar and reminders, Apple Mail,
// the spoken voice and the meeting mute. Messages and other apps' notifications are in Inbox*.swift: direct build
// only, off until turned on, and they need 전체 디스크 접근 (no public way to read them).

// MARK: - iPhone (ntfy / Pushover)

enum Phone {
    static let ntfyServer = "https://ntfy.sh"

    /// "charamonitor-" + 16 random letters and digits. A topic is a password: whoever knows it can read it.
    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "charamonitor-" + String((0..<16).map { _ in chars.randomElement()! })
    }

    static func subscribeURL(_ topic: String) -> URL? { URL(string: "\(ntfyServer)/\(topic)") }

    /// ntfy JSON publish (titles in a header would have to be ASCII).
    static func ntfyRequest(topic: String, title: String, body: String) -> URLRequest? {
        guard let url = URL(string: ntfyServer) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["topic": topic, "title": title, "message": body, "tags": ["computer"]])
        return r
    }

    static func pushoverRequest(user: String, token: String, title: String, body: String) -> URLRequest? {
        guard let url = URL(string: "https://api.pushover.net/1/messages.json"), !user.isEmpty, !token.isEmpty else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves "&", "=" and "+" alone in values, which a form body would misread.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let fields = [("token", token), ("user", user), ("title", title), ("message", body)]
        r.httpBody = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: safe) ?? "")" }.joined(separator: "&").data(using: .utf8)
        return r
    }

    /// Sends with the user's settings. Returns nil on success, else what to show.
    @discardableResult
    static func send(title: String, body: String, settings s: AssistantSettings = .shared) async -> String? {
        let request = s.phoneService == .ntfy
            ? ntfyRequest(topic: s.ntfyTopic, title: title, body: body)
            : pushoverRequest(user: s.pushoverUser, token: s.pushoverToken, title: title, body: body)
        guard let request else { return L("Pushover 사용자 키와 앱 토큰을 넣어 주세요.") }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? nil : L("보내지 못했어요 (응답 \(code)).")
        } catch {
            return L("보내지 못했어요. 인터넷 연결을 확인해 주세요.")
        }
    }

    /// The subscribe link as a QR code for the iPhone camera.
    static func qr(_ text: String, size: CGFloat = 120) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width * 2, y: size / out.extent.height * 2))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - charamonitor://say?text=

enum AssistantURL {
    static let scheme = "charamonitor"
    /// What a say link shows before its text, so a line from outside never passes for the character's own.
    static var prefix: String { L("단축어: ") }

    /// The text of a say link, cut to the bubble limit; nil for anything else. The scheme only ever speaks:
    /// any web page can open it, so it must not run, open or change anything.
    static func sayText(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "say",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value
        else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(SpeechBubbleCenter.maxLength))
    }
}

/// Spacing for say links: any web page can open one, so at most one per `spacing` and `perHour` an hour. Pure.
struct URLSayLimiter {
    static let spacing: TimeInterval = 30
    static let perHour = 10
    private(set) var recent: [Date] = []

    mutating func allow(now: Date) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0) < 3600 && $0 <= now }
        if let last = recent.last, now.timeIntervalSince(last) < Self.spacing { return false }
        guard recent.count < Self.perHour else { return false }
        recent.append(now)
        return true
    }
}

// MARK: - Calendar and reminders (EventKit)

final class CalendarLink {
    static let shared = CalendarLink()
    let store = EKEventStore()
    /// Events and reminders already announced, so each is said once.
    private var said = Set<String>()

    /// A bare build (no Info.plist) would be killed by the system on the request; refuse instead.
    static func canAsk(_ type: EKEntityType) -> Bool {
        let keys = type == .event ? ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription"]
                                  : ["NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription"]
        return keys.allSatisfy { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    static func authorized(_ type: EKEntityType) -> Bool {
        let s = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14, *) { return s == .fullAccess }
        return s == .authorized
    }

    /// Asks once (macOS 14+: full access; 13: the old request). Returns nil when allowed, else what to show.
    func request(_ type: EKEntityType) async -> String? {
        let what = type == .event ? L("캘린더") : L("미리알림")
        guard Self.canAsk(type) else { return L("이 빌드에서는 \(what)을 연결할 수 없어요.") }
        if Self.authorized(type) { return nil }
        let ok: Bool
        if #available(macOS 14, *) {
            ok = (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
        } else {
            ok = (try? await store.requestAccess(to: type)) ?? false
        }
        return ok ? nil : L("시스템 설정 > 개인정보 보호 및 보안 > \(what)에서 캐릭모니터를 허용해 주세요.")
    }

    /// Today's events still ahead, as "15:00 팀 회의" (at most 3), for the chat prompt. Only while the user's own
    /// 캘린더 switch is on: macOS's permission alone is not consent to read them (Info.plist promises as much).
    func todayLines(now: Date = Date(), enabled: Bool = AssistantSettings.shared.calendar) -> [String] {
        guard enabled else { return [] }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return todayEvents(now: now).prefix(3).map { "\(f.string(from: $0.startDate)) \($0.title ?? "일정")" }
    }

    /// Today's events from `now` on that count (CalendarLink.counts), soonest first.
    func todayEvents(now: Date = Date()) -> [EKEvent] {
        guard Self.authorized(.event) else { return [] }
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        return store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter(Self.counts).sorted { $0.startDate < $1.startDate }
    }

    /// Incomplete reminders due today, as "할 일: 10:00 보고서" (the time only when one is set), soonest first.
    /// Only while the user's 미리알림 switch is on.
    func todayReminders(now: Date = Date(), enabled: Bool = AssistantSettings.shared.reminders) async -> [String] {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return await todayTodos(now: now, enabled: enabled).map { "할 일: " + ($0.timed ? f.string(from: $0.due) + " " : "") + $0.title }
    }

    /// One open reminder.
    struct Todo: Equatable {
        var id: String
        var title: String
        var due: Date
        /// A time of day is set (not only the date).
        var timed: Bool
    }

    /// Incomplete reminders due today, soonest first. Only while the user's 미리알림 switch is on.
    func todayTodos(now: Date = Date(), enabled: Bool = AssistantSettings.shared.reminders) async -> [Todo] {
        guard enabled, Self.authorized(.reminder) else { return [] }
        let day = Calendar.current.startOfDay(for: now)
        let p = store.predicateForIncompleteReminders(withDueDateStarting: day, ending: day.addingTimeInterval(86_400), calendars: nil)
        return await withCheckedContinuation { done in
            store.fetchReminders(matching: p) { reminders in
                let items = (reminders ?? []).map { r in
                    Todo(id: r.calendarItemIdentifier, title: r.title ?? L("할 일"),
                         due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? day, timed: r.dueDateComponents?.hour != nil)
                }
                done.resume(returning: items.sorted { $0.due < $1.due })
            }
        }
    }

    /// Done today of today's to-dos (completed since midnight plus the ones still open and due today); nil while
    /// reminders are off or not allowed.
    func todayProgress(now: Date = Date(), enabled: Bool = AssistantSettings.shared.reminders) async -> TodoProgress? {
        guard enabled, Self.authorized(.reminder) else { return nil }
        let open = await todayTodos(now: now, enabled: enabled).count
        let p = store.predicateForCompletedReminders(withCompletionDateStarting: Calendar.current.startOfDay(for: now), ending: now, calendars: nil)
        let done = await withCheckedContinuation { c in store.fetchReminders(matching: p) { c.resume(returning: $0?.count ?? 0) } }
        return TodoProgress(done: done, total: done + open)
    }

    /// Ticks reminder `id` off (집중 위젯's 완료). Returns whether it was saved.
    @discardableResult
    func complete(_ id: String) -> Bool {
        guard Self.authorized(.reminder), let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        r.isCompleted = true
        return (try? store.save(r, commit: true)) != nil
    }

    /// The morning's count for 출근 인사: "오늘 일정 2개 · 첫 일정 10:00 '팀 회의' · 미리알림 3개". `events` nil: calendar
    /// off; `reminders` nil: reminders off. Pure.
    static func brief(_ events: [(start: Date, title: String)]?, reminders: Int?) -> String {
        var parts: [String] = []
        if let events {
            if let first = events.first {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                let time = f.string(from: first.start), title = first.title
                parts.append(L("오늘 일정 \(events.count)개"))
                parts.append(L("첫 일정 \(time) '\(title)'"))
            } else {
                parts.append(L("오늘 일정 없음"))
            }
        }
        if let reminders, reminders > 0 { parts.append(L("미리알림 \(reminders)개")) }
        return parts.joined(separator: " · ")
    }

    /// Whether an event is worth a word: not all-day, cancelled ("취소:" in the title too), declined or marked free.
    static func counts(_ e: EKEvent) -> Bool {
        !e.isAllDay && e.status != .canceled && e.availability != .free && !cancelledTitle(e.title ?? "")
            && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }

    /// "취소: 주간 회의", "Canceled: Weekly sync": what some calendars leave of a cancelled meeting.
    static func cancelledTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return ["취소:", "취소됨:", "[취소]", "canceled:", "cancelled:"].contains { t.hasPrefix($0) }
    }

    /// Events whose alert time has come (`leads` minutes before, [15, 5] = two alerts), each lead said once.
    /// The meeting's place comes along, cut to 30 characters.
    func dueEvents(now: Date = Date(), leads: [Int] = AssistantSettings.shared.calendarLeads) -> [Nudge] {
        guard Self.authorized(.event), let far = leads.max() else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(Double(far) * 60), calendars: nil))
        return events.filter { Self.counts($0) && $0.startDate > now }.compactMap { e in
            let id = "e:" + (e.eventIdentifier ?? "") + "\(e.startDate.timeIntervalSince1970)"
            let left = max(1, Int((e.startDate.timeIntervalSince(now) / 60).rounded(.up)))
            let saidLeads = Set(leads.filter { said.contains(id + "#\($0)") })
            guard let lead = Self.lead(leads, minutesLeft: left, said: saidLeads) else { return nil }
            leads.filter { $0 >= lead }.forEach { said.insert(id + "#\($0)") }   // the ones already past never fire later
            let place = (e.location ?? "").components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return .calendar(title: e.title ?? L("일정"), minutes: left, place: String(place.prefix(30)))
        }
    }

    /// The lead to say with `minutesLeft` to go: the nearest one already due, unless said. Several due at once (the
    /// Mac woke up late) fire once, as the nearest; a later one said makes the earlier ones past. Pure.
    static func lead(_ leads: [Int], minutesLeft: Int, said: Set<Int>) -> Int? {
        guard let nearest = leads.filter({ $0 >= minutesLeft }).min(), !said.contains(nearest) else { return nil }
        return nearest
    }

    /// Reminders due in the next 10 minutes. Calls back on the main thread.
    func dueReminders(now: Date = Date(), _ done: @escaping ([Nudge]) -> Void) {
        guard Self.authorized(.reminder) else { done([]); return }
        let p = store.predicateForIncompleteReminders(withDueDateStarting: now, ending: now.addingTimeInterval(600), calendars: nil)
        store.fetchReminders(matching: p) { reminders in
            let items = (reminders ?? []).map { ($0.calendarItemIdentifier, $0.title ?? L("할 일")) }
            DispatchQueue.main.async {
                done(items.compactMap { id, title in self.said.insert("r:" + id).inserted ? .reminder(title) : nil })
            }
        }
    }
}

// MARK: - Apple Mail (direct build only)

#if !MAS
enum MailLink {
    static let bundleID = "com.apple.mail"

    struct Item: Equatable {
        var id: Int
        var sender: String
        var subject: String
    }

    enum Poll: Equatable {
        /// Unread inbox messages, newest first (at most `limit`).
        case unread([Item])
        /// macOS said no to controlling Mail (-1743, 이 앱이 Mail을 제어하는 것을 허용 안 함).
        case denied
        /// Mail is closed, slow or answered something else: try again next time.
        case unavailable
    }

    static let limit = 20

    /// macOS would ask its 자동화 question (never answered for Mail). False when Mail is closed (poll says so) or the
    /// answer is already known. Off the main thread: it may wait on Mail for a moment.
    static func wouldAsk() -> Bool {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false) == OSStatus(errAEEventWouldRequireUserConsent)
    }

    /// Field and record separators unlikely in a sender or subject.
    static let fieldSep = "\u{1F}", recordSep = "\u{1E}"

    /// The newest unread inbox messages: id, sender, subject. Never starts Mail: .unavailable while it is closed.
    /// Runs osascript off the main thread (Mail can take seconds); needs NSAppleEventsUsageDescription in the app.
    /// The first run asks macOS's 자동화 permission, so it is first called right after the user turns the switch on.
    static func poll() async -> Poll {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .unavailable }
        let script = """
        tell application id "com.apple.mail"
            set out to "OK"
            set msgs to (messages of inbox whose read status is false)
            repeat with i from 1 to (count of msgs)
                if i > \(limit) then exit repeat
                set m to item i of msgs
                set s to ""
                try
                    set s to (subject of m) as text
                end try
                set out to out & (character id 30) & ((id of m) as text) & (character id 31) & (sender of m) & (character id 31) & s
            end repeat
            return out
        end tell
        """
        return await Task.detached { () -> Poll in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let pipe = Pipe(), errors = Pipe()
            p.standardOutput = pipe
            p.standardError = errors
            guard (try? p.run()) != nil else { return .unavailable }
            // The permission prompt waits for the user, so give it time.
            let deadline = Date().addingTimeInterval(60)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate(); return .unavailable }
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if isDenial(err) { return .denied }
            guard let items = items(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) else { return .unavailable }
            return .unread(items)
        }.value
    }

    /// The script's "OK" + records of id, sender, subject. Nil for anything else (an error, a timeout).
    static func items(_ out: String) -> [Item]? {
        let records = out.trimmingCharacters(in: .newlines).components(separatedBy: recordSep)
        guard records.first == "OK" else { return nil }
        return records.dropFirst().compactMap { r in
            let f = r.components(separatedBy: fieldSep)
            guard f.count >= 2, let id = Int(f[0]) else { return nil }
            let subject = f.dropFirst(2).joined(separator: " ").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return Item(id: id, sender: name(f[1]), subject: subject)
        }
    }

    /// Ids not in `seen`, plus what to remember next time. The first poll (`seen` nil) only learns.
    static func fresh(_ items: [Item], seen: Set<Int>?) -> (new: [Item], seen: Set<Int>) {
        guard let seen else { return ([], Set(items.map(\.id))) }
        let new = items.filter { !seen.contains($0.id) }
        // Remember what is still unread plus a little history, so a read-then-unread mail is not news again soon.
        let keep = seen.count > 500 ? Set(items.map(\.id)) : seen
        return (new, keep.union(items.map(\.id)))
    }

    /// osascript's error for a refused Apple Event (errAEEventNotPermitted).
    static func isDenial(_ stderr: String) -> Bool { stderr.contains("-1743") }

    /// "2\n김철수 <a@b.c>\nnews@x.com" -> (2, ["김철수", "news"]): names only, never addresses.
    static func parse(_ out: String) -> (count: Int, senders: [String])? {
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let n = Int(first) else { return nil }
        return (n, lines.dropFirst().map(name))
    }

    /// "김철수 <a@b.c>" -> "김철수", "news@x.com" -> "news": names only, never addresses.
    static func name<S: StringProtocol>(_ sender: S) -> String {
        let s = sender.trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        let addr = s.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return addr.split(separator: "@").first.map(String.init) ?? addr
    }
}
#endif

// MARK: - Voice

/// The bubble read aloud (off by default). Korean voices are a separate download on Macs set to other languages.
final class AssistantVoice {
    static let shared = AssistantVoice()
    private let synth = AVSpeechSynthesizer()

    static var koreanVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "ko-KR") ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("ko") }
    }

    static let missingVoiceHelp = L("한국어 음성이 없어요. 시스템 설정 > 손쉬운 사용 > 읽기 및 말하기 > 시스템 음성에서 한국어 음성(유나 등)을 받아 주세요.")

    func speak(_ text: String) {
        guard let voice = Self.koreanVoice else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(u)
    }
}

// MARK: - Meeting mute

enum MeetingMute {
    /// Video call and screen sharing apps: while one of them is in front, the character keeps quiet.
    /// ponytail: front app only. Focus modes have no public read API without an Intents extension; add a
    /// SetFocusFilterIntent when the app moves to xcodebuild.
    static let apps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
                                    "Cisco-Systems.Spark", "com.apple.FaceTime", "com.hnc.Discord", "com.apple.ScreenSharing"]

    static func inMeeting() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return apps.contains(id)
    }

    /// Screen recorders: while one runs, the screen may be going out.
    static let recorders: Set<String> = ["com.apple.screencaptureui", "com.obsproject.obs-studio", "com.loom.desktop"]

    /// Whether the screen may be seen by others (a call in any app, a browser Meet included, or a recording), for
    /// lines that carry other people's words (InboxCenter). Wider than inMeeting: a shared Keynote is in front then.
    /// ponytail: the mic in use stands for "in a call" (no public API says "screen is shared"); dictation also mutes.
    static func screenMaybeShared() -> Bool {
        if inMeeting() || micInUse() { return true }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(recorders.contains) == true }
    }

    /// Some app has the default input device open (Zoom, Teams, Meet in a browser...). No permission needed.
    static func micInUse() -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        a.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &running) == noErr && running != 0
    }
}
