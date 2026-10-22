import AppKit
import Combine
import Foundation

/// The AI 비서 at run time: 먼저 말 걸기 from the samples, the calendar and reminders polls (문자·메일·알림: InboxCenter), iPhone
/// notifications, charamonitor://say and the bubble window. AppDelegate calls start() once.
/// Free: template lines for battery, heat, a finished task and a runaway process. AI 비서 (assistant): AI-written
/// lines and every integration.
@MainActor
final class AssistantCenter: NSObject {
    static let shared = AssistantCenter()
    private let settings = AssistantSettings.shared
    private var detector = NudgeDetector()
    private var gate = NudgeGate()
    private var phoneSent: [PhoneEvent: Date] = [:]
    private var saidRunaway = Set<ProcKey>()
    /// One line held back while muted or inside the cooldown, said once that passes (if it still holds).
    private var pending: (nudge: Nudge, since: Date)?
    private var urlLimiter = URLSayLimiter()
    private var minute = 0
    /// Today's to-do count at the last look (nil: not read yet), so a new tick gets a word of praise.
    private var progress: TodoProgress?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    static let phoneCooldown: TimeInterval = 30 * 60
    /// A held-back line older than this is dropped (a 30-minute-old "task finished" is no news).
    static let pendingFor: TimeInterval = 30 * 60

    func start() {
        guard timer == nil else { return }
        SpeechBubbleWindow.shared.start()
        InboxCenter.shared.start()   // 문자·메일·알림 알려주기 (App Store build: 메일 계정 only)
        PetSignals.shared.events
            .sink { [weak self] signal in
                guard let self, case .sample(let battery, let load, _) = signal else { return }
                let found = self.detector.feed(battery: battery, load: load, thermal: ProcessInfo.processInfo.thermalState, now: Date())
                found.forEach(self.handle)
            }
            .store(in: &bag)
        // 펫 키우기 lines can go to the iPhone too.
        SpeechBubbleCenter.shared.$current
            .compactMap { $0 }
            .filter { $0.source == .pet }
            .sink { [weak self] line in self?.toPhone(.pet, line.text) }
            .store(in: &bag)
        // A goal missed while the Mac slept catches up once on wake (GoalRunner collapses the missed ticks).
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { _ in MainActor.assumeIsolated { AgentCenter.shared.tick() } }
            .store(in: &bag)
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.everyMinute() } }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func everyMinute() {
        minute += 1
        if let p = pending, !SpeechBubbleCenter.shared.isMuted() {
            pending = nil
            if Date().timeIntervalSince(p.since) < Self.pendingFor { deliver(p.nudge, since: p.since) }
        }
        // A permission taken back (System Settings, or an update re-signing the app) turns its switch off, with a word why.
        if settings.calendar && !CalendarLink.authorized(.event) {
            switchOff(\.calendar, L("캘린더 접근이 꺼져 있어서 일정 알림을 껐어요. 비서 설정에서 다시 켜 주세요."))
        }
        if settings.reminders && !CalendarLink.authorized(.reminder) {
            switchOff(\.reminders, L("미리알림 접근이 꺼져 있어서 미리알림 알림을 껐어요. 비서 설정에서 다시 켜 주세요."))
        }
        // 비서가 행동하기: old cards expire, one due goal runs (it only ever leaves cards).
        AgentCenter.shared.tick()
        if settings.calendar { CalendarLink.shared.dueEvents().forEach(handle) }
        if settings.reminders { CalendarLink.shared.dueReminders { [weak self] in $0.forEach { self?.handle($0) } } }
        if settings.reminders { checkProgress() }
        checkWorkHours(now: Date())
        #if !MAS   // no per-process CPU in the App Store build
        if minute % 5 == 0 { checkRunaway() }
        #endif
    }

    /// A to-do ticked off since the last look: "벌써 2/4!" on a glowing card over a desktop friend, the last one a special
    /// line. Free of the model; muted like every bubble. Also called right after the 집중 위젯 ticks one off.
    func checkProgress() {
        Task { [weak self] in
            guard let now = await CalendarLink.shared.todayProgress(), let self else { return }
            let old = self.progress
            self.progress = now
            let persona = AssistantModel.persona()
            guard let line = TodoProgress.milestone(old: old, new: now, style: persona.style) else { return }
            if now.allDone { DesktopKit.celebrate.send(.proud) }
            SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false, card: .proud, anchor: DesktopFriends.speaker)
        }
    }

    /// 출근·점심·퇴근 인사: each once a day, claimed before it is said. Free (template lines). While a moment plays (a
    /// calendar alert) the 점심·퇴근 line waits a minute, unclaimed, so its motion is not lost. Muted or with an alert held
    /// back, every one waits unclaimed too: `pending` holds one line, and a greeting there would push out a calendar alert.
    private func checkWorkHours(now: Date) {
        let alertHeld: Bool = { switch pending?.nudge { case .calendar?, .reminder?: return true; default: return false } }()
        guard settings.nudges != .off, !alertHeld, !SpeechBubbleCenter.shared.isMuted() else { return }
        let w = settings.workHours, today = WorkHours.day(now)
        guard let kind = WorkHours.Kind.allCases.first(where: { w.due($0, now: now) && settings.workAlerts[$0.rawValue] != today }),
              kind == .morning || !SituationEngine.playing(now: now) else { return }
        settings.workAlerts[kind.rawValue] = today
        switch kind {
        case .lunch: handle(.lunch)
        case .leave: handle(.leave(minutes: w.minutesToEnd(now)))
        case .morning:
            let events = settings.calendar ? CalendarLink.shared.todayEvents(now: now).map { (start: $0.startDate!, title: $0.title ?? L("일정")) } : nil
            guard settings.reminders else { handle(.morning(brief: CalendarLink.brief(events, reminders: nil))); return }
            Task { [weak self] in
                let reminders = await CalendarLink.shared.todayReminders(now: now).count
                self?.handle(.morning(brief: CalendarLink.brief(events, reminders: reminders)))
            }
        }
    }

    #if !MAS
    /// One new runaway process (as 클리너 would offer it) per check.
    private func checkRunaway() {
        guard settings.nudges != .off else { return }
        let tracker = RunawayTracker.shared
        let histories = tracker.histories, context = tracker.context()
        Task.detached {
            let found = RunawayTracker.offer(histories, context)
            await MainActor.run { [weak self] in
                guard let self, let c = found.first(where: { !self.saidRunaway.contains($0.id) }) else { return }
                self.saidRunaway.insert(c.id)
                self.handle(.runaway(c.name))
            }
        }
    }
    #endif

    /// Turns an integration off by itself and says why (bubble now, 비서 설정 until seen).
    private func switchOff(_ key: ReferenceWritableKeyPath<AssistantSettings, Bool>, _ why: String) {
        settings[keyPath: key] = false
        settings.integrationNotice = why
        SpeechBubbleCenter.shared.say(text: why, source: .system, aloud: false)
    }

    /// Says a found moment (AI line when possible, else the template) and tells the iPhone.
    func handle(_ n: Nudge) {
        // The first line, not a pick: picking here too would spend the bubble's LinePick turn (even with the phone off).
        if let e = n.phoneEvent { toPhone(e, n.templates(polite: false)[0]) }
        deliver(n, since: Date())
    }

    /// The bubble part of handle. Muted (잠시 조용히, a call app in front), a held line showing (SpeechLine.yields) or
    /// inside the cooldown: the line waits in `pending` instead of being lost, and nothing is used up.
    private func deliver(_ found: Nudge, since: Date) {
        let now = Date()
        guard let n = found.aged(by: now.timeIntervalSince(since)) else { return }
        let muted = SpeechBubbleCenter.shared.isMuted()
        if SpeechBubbleCenter.shared.current?.yields(hold: n.holdsBubble, now: now) == false { pending = (found, since); return }
        switch n {
        case .calendar, .reminder, .mail, .morning, .lunch, .leave:   // asked for one by one: not spaced out, only held while muted
            if muted { pending = (found, since); return }
        default:
            switch gate.check(settings.nudges, muted: muted, urgent: n.isUrgent, now: now) {
            case .never: return
            case .wait: pending = (found, since); return
            case .say: break
            }
        }
        if let m = n.motion { SituationEngine.play(m, now: now) }
        let persona = AssistantModel.persona()
        let template = n.template(polite: !persona.style.banmal)
        // The user's own line (대사 고치기) is said as written, never rewritten by the AI.
        if LineOverrides.edited(n.lineKey) {
            SpeechBubbleCenter.shared.say(text: template, source: .system, hold: n.holdsBubble, seconds: n.seconds, closable: n.holdsBubble)
            return
        }
        guard settings.aiNudges, OnDeviceEngine.isAvailable else {
            SpeechBubbleCenter.shared.say(text: persona.dress(template, flair: n.flavored), source: .system, hold: n.holdsBubble, seconds: n.seconds, closable: n.holdsBubble)
            return
        }
        Task {
            let line = (try? await OnDeviceEngine.shared.line(persona, situation: n.situation))
                .map { AssistantPrompt.clean($0, persona: persona, max: 120) }
            let said = line.flatMap { $0.isEmpty || Self.invents($0, from: n.situation + " " + template) ? nil : $0 }
            SpeechBubbleCenter.shared.say(text: persona.dress(said.map { $0 + n.tail } ?? template, flair: false), source: .assistant, hold: n.holdsBubble, seconds: n.seconds, closable: n.holdsBubble)
        }
    }

    /// The on-device line names something that did not happen: a 카톡, 문자 or 메일 the situation never mentioned
    /// (a battery nudge came out as "카톡 왔어"). Then the template says it instead.
    nonisolated static func invents(_ line: String, from situation: String) -> Bool {
        let l = line.lowercased(), s = situation.lowercased()
        return inboxWords.contains { l.contains($0) && !s.contains($0) }
    }

    /// Words that make a line sound like something came in. Spacing and spelling vary ("톡이 왔어", "메세지", "알림이 와"),
    /// so stems, not phrases.
    nonisolated static let inboxWords = ["카톡", "카카오", "톡이", "톡 왔", "톡왔", "문자", "메시지", "메세지", "메일", "알림",
                                         "연락", "전화", "답장", "디엠", "message", "kakao", "slack", "슬랙", "텔레그램"]

    private func toPhone(_ e: PhoneEvent, _ text: String) {
        guard settings.phone, settings.phoneEvents.contains(e) else { return }
        let now = Date()
        if let last = phoneSent[e], now.timeIntervalSince(last) < Self.phoneCooldown { return }
        phoneSent[e] = now
        Task { await Phone.send(title: L("캐릭모니터 · \(AppSettings.shared.characterName)"), body: text) }
    }

    /// Called from applicationWillFinishLaunching, so the URL that launched the app is not missed.
    func listenForURLs() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// charamonitor://say?text=... (Shortcuts' "URL 열기"). Shows only when 단축어로 말 시키기 is on,
    /// spaced out (URLSayLimiter), marked as coming from outside, never read aloud. Any web page can open the link.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s),
              let text = AssistantURL.sayText(url), settings.urlSay, urlLimiter.allow(now: Date()) else { return }
        SpeechBubbleCenter.shared.say(text: AssistantURL.prefix + text, source: .assistant, aloud: false)
    }
}
