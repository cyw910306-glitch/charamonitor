import AppKit
import Combine

/// One 집중 (focus) run: counted from its start minus the paused stretches, never by adding up ticks, so a late
/// timer or a sleeping Mac cannot make it drift. Pure.
struct FocusSession: Equatable {
    var start: Date
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0

    var paused: Bool { pausedAt != nil }

    func elapsed(_ now: Date) -> TimeInterval { max(0, (pausedAt ?? now).timeIntervalSince(start) - pausedTotal) }

    mutating func pause(_ now: Date) { if pausedAt == nil { pausedAt = now } }

    mutating func resume(_ now: Date) {
        guard let p = pausedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(p))
        pausedAt = nil
    }

    /// "00:03", "25:00", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds)), h = s / 3600, m = s / 60 % 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
    }
}

/// The to-do being worked on: shown as a pill over the focusing friend (진행 중).
struct FocusTask: Equatable {
    /// The reminder's id (CalendarLink.Todo), nil for a title typed in.
    var id: String?
    var title: String
}

/// 집중 타이머 for the 데스크톱 친구: start, pause, stop; the widget over a friend (FocusBubble) and the
/// menu bar clock follow `session`. In memory only: a relaunch ends a run.
final class FocusCenter: ObservableObject {
    static let shared = FocusCenter()

    @Published private(set) var session: FocusSession?
    @Published var task: FocusTask?
    /// "12:03" for the menu bar while a run counts and 메뉴바에 시간 보이기 is on; nil otherwise.
    @Published private(set) var menuTitle: String?
    /// 메뉴바에 시간 보이기.
    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "focus.menuBar"); tick() } }

    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        showInMenuBar = defaults.object(forKey: "focus.menuBar") as? Bool ?? true
    }

    var running: Bool { session != nil }

    /// Starts a run on `task`, or on today's first open reminder when none is given (only with 미리알림 linked, like
    /// every other 미리알림 read: FriendQuickAsk).
    func start(task: FocusTask? = nil) {
        guard session == nil else { return }
        session = FocusSession(start: Date())
        self.task = task
        if task == nil {
            let linked = AssistantSettings.shared.reminders
            Task { @MainActor in
                if self.session != nil, self.task == nil, let first = await CalendarLink.shared.todayTodos(enabled: linked).first {
                    self.task = FocusTask(id: first.id, title: first.title)
                }
            }
        }
        FocusBubble.shared.show()
        arm()
    }

    func pause() { session?.pause(Date()); tick() }
    func resume() { session?.resume(Date()); tick() }

    /// Ends the run with a word on how long it was (a template line, no model).
    func stop() {
        guard let s = session else { return }
        let minutes = Int(s.elapsed(Date()) / 60)
        session = nil
        task = nil
        timer?.invalidate(); timer = nil
        menuTitle = nil
        FocusBubble.shared.hide()
        let persona = AssistantModel.persona()
        let polite = !persona.style.banmal
        let line: String
        if minutes >= 1 {
            line = polite ? L("\(minutes)분 집중했어요. 수고 많으셨어요!") : L("\(minutes)분 집중했어. 수고했어!")
            DesktopKit.celebrate.send(.proud)
        } else {
            line = polite ? L("잠깐 집중했어요. 다음엔 조금 더 해 봐요.") : L("잠깐 집중했네. 다음엔 조금 더 해 보자.")
        }
        SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false,
                                      card: minutes >= 1 ? .proud : nil, anchor: DesktopFriends.speaker)
    }

    /// "집중 시작" or "집중 그만" in the chat (AssistantIntent.focus): does it and says so.
    func chat(_ question: String, persona: Persona) -> String {
        let polite = !persona.style.banmal
        let q = question.lowercased(), tight = q.filter { !$0.isWhitespace }
        let stopping = AssistantIntent.focusStopWords.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) }
        if stopping {
            guard let s = session else { return polite ? L("지금은 집중하고 있지 않아요.") : L("지금은 집중하고 있지 않아.") }
            let m = Int(s.elapsed(Date()) / 60)
            stop()
            return polite ? L("\(m)분 집중하고 마쳤어요.") : L("\(m)분 집중하고 마쳤어.")
        }
        if let s = session {
            let t = FocusSession.clock(s.elapsed(Date()))
            return polite ? L("이미 집중 중이에요. 지금 \(t)째예요.") : L("이미 집중 중이야. 지금 \(t)째야.")
        }
        start()
        return polite ? L("집중 시작! 다 하면 친구 위의 그만하기를 눌러 주세요.") : L("집중 시작! 다 하면 친구 위의 그만하기를 눌러 줘.")
    }

    /// Ticks the current task off in 미리알림 and lets the progress praise run.
    @MainActor
    func completeTask() {
        guard let id = task?.id else { task = nil; return }
        if CalendarLink.shared.complete(id) {
            task = nil
            AssistantCenter.shared.checkProgress()
        }
    }

    /// A once-a-second tick for the menu bar clock only (the widget has its own TimelineView).
    private func arm() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let title = session.flatMap { s in showInMenuBar ? FocusSession.clock(s.elapsed(Date())) : nil }
        if title != menuTitle { menuTitle = title }
    }
}
