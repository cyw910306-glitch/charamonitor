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

    /// 0...1 of the way to a `goal` of minutes; nil with no goal (0).
    static func progress(_ elapsed: TimeInterval, goal: Int) -> Double? {
        goal > 0 ? min(1, max(0, elapsed / Double(goal * 60))) : nil
    }

    /// The widget's status line: the friend talking, by how long the run is and the time of day.
    static func mood(elapsed: TimeInterval, hour: Int, paused: Bool, polite: Bool) -> String {
        if paused { return L("잠깐 쉬는 중 ☕") }
        if hour >= 23 || hour < 5 { return L("늦은 밤 집중 🌙") }
        let m = elapsed / 60
        if m < 5 { return (6..<9).contains(hour) ? L("아침 집중 ☀️") : L("시작이 반!") }
        if m < 20 { return L("집중 시작!") }
        if m < 45 { return polite ? L("몰입 중이에요 ✨") : L("몰입 중이야 ✨") }
        return polite ? L("대단해요, 오래 버텼어요!") : L("대단해, 오래 버텼어!")
    }
}

/// 위젯 색: a pastel sticker in light mode, a deep tint of the same in dark mode. 그만하기 and the progress bar take `accent`.
/// 복숭아 and 코코아 are 후원 선물 (SponsorGifts). Raw values are saved; never rename one.
enum FocusTheme: String, CaseIterable {
    case lavender, strawberry, mint, lemon, sky, peach, cocoa

    var label: String {
        switch self {
        case .lavender: return L("라벤더")
        case .strawberry: return L("딸기우유")
        case .mint: return L("민트")
        case .lemon: return L("레몬")
        case .sky: return L("하늘")
        case .peach: return L("복숭아")
        case .cocoa: return L("코코아")
        }
    }

    /// Next to the time in the menu bar.
    var emoji: String {
        switch self {
        case .lavender: return "🍇"
        case .strawberry: return "🍓"
        case .mint: return "🌿"
        case .lemon: return "🍋"
        case .sky: return "☁️"
        case .peach: return "🍑"
        case .cocoa: return "☕"
        }
    }

    /// Hexes for light or dark: the card's fill, its text, and the accent (white text on it at least 4.5:1).
    func hexes(dark: Bool) -> (fill: String, ink: String, accent: String) {
        switch (self, dark) {
        case (.lavender, false): return ("#EFE8FC", "#3E3166", "#7459E0")
        case (.lavender, true): return ("#2E2747", "#E4DAF7", "#7459E0")
        case (.strawberry, false): return ("#FFE4EC", "#6E2A40", "#CC3F72")
        case (.strawberry, true): return ("#45263A", "#FFD6E0", "#CC3F72")
        case (.mint, false): return ("#DDF5EA", "#1F4A3C", "#1F8460")
        case (.mint, true): return ("#1F3A33", "#CDEFE0", "#1F8460")
        case (.lemon, false): return ("#FFF4C7", "#5C4500", "#9A6A00")
        case (.lemon, true): return ("#3E3620", "#FFF0B8", "#9A6A00")
        case (.sky, false): return ("#E0F0FD", "#23415E", "#2A72B0")
        case (.sky, true): return ("#1F3247", "#D3EAFB", "#2A72B0")
        case (.peach, false): return ("#FFE9DD", "#5E2E18", "#B4532A")
        case (.peach, true): return ("#40281E", "#FFDCCB", "#B4532A")
        case (.cocoa, false): return ("#F3E6DC", "#4A3426", "#8A5A3C")
        case (.cocoa, true): return ("#33261E", "#F0DFD2", "#8A5A3C")
        }
    }
}

/// 위젯 크기: the scale for the widget's type and padding.
enum FocusSize: String, CaseIterable {
    case small, normal, large

    var label: String {
        switch self {
        case .small: return L("작게")
        case .normal: return L("보통")
        case .large: return L("크게")
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .normal: return 1
        case .large: return 1.25
        }
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
    /// 메뉴바 시간에 이모지 붙이기: "🍇 12:03", "☕ 12:03" while paused.
    @Published var menuEmoji: Bool { didSet { defaults.set(menuEmoji, forKey: "focus.menuEmoji"); tick() } }
    /// 위젯 색.
    @Published var theme: FocusTheme { didSet { defaults.set(theme.rawValue, forKey: "focus.theme"); tick() } }
    /// 위젯 크기.
    @Published var size: FocusSize { didSet { defaults.set(size.rawValue, forKey: "focus.size") } }
    /// 목표 시간 in minutes, 0 = none: a progress bar on the widget and a cheer when it is reached (the run keeps counting).
    @Published var goalMinutes: Int { didSet { defaults.set(goalMinutes, forKey: "focus.goal") } }
    /// 목표 달성 소리: a chime at the goal and on stopping a run that reached it.
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "focus.sound") } }

    private let defaults: UserDefaults
    private var timer: Timer?
    /// This run reached its goal (cheered once; the stop line says so).
    private var goalHit = false

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        showInMenuBar = defaults.object(forKey: "focus.menuBar") as? Bool ?? true
        menuEmoji = defaults.object(forKey: "focus.menuEmoji") as? Bool ?? true
        theme = defaults.string(forKey: "focus.theme").flatMap(FocusTheme.init) ?? .lavender
        size = defaults.string(forKey: "focus.size").flatMap(FocusSize.init) ?? .normal
        goalMinutes = defaults.object(forKey: "focus.goal") as? Int ?? 25
        sound = defaults.object(forKey: "focus.sound") as? Bool ?? true
    }

    /// QA only (DesktopQA): a run and a pill to draw, with no timer, panel or reminder read.
    func seed(session: FocusSession?, task: FocusTask? = nil) {
        self.session = session
        self.task = task
    }

    var running: Bool { session != nil }

    /// Starts a run on `task`, or on today's first open reminder when none is given (only with 미리알림 linked, like
    /// every other 미리알림 read: FriendQuickAsk).
    func start(task: FocusTask? = nil) {
        guard session == nil else { return }
        session = FocusSession(start: Date())
        goalHit = false
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
        if goalHit {
            line = polite ? L("목표까지 해냈어요! \(minutes)분 집중 완료 🎉") : L("목표까지 해냈다! \(minutes)분 집중 완료 🎉")
            DesktopKit.celebrate.send(.dance)
            chime()
        } else if minutes >= 1 {
            line = polite ? L("\(minutes)분 집중했어요. 수고 많으셨어요!") : L("\(minutes)분 집중했어. 수고했어!")
            DesktopKit.celebrate.send(.proud)
        } else {
            line = polite ? L("잠깐 집중했어요. 다음엔 조금 더 해 봐요.") : L("잠깐 집중했네. 다음엔 조금 더 해 보자.")
        }
        SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false,
                                      card: goalHit ? .dance : minutes >= 1 ? .proud : nil, anchor: DesktopFriends.speaker)
        goalHit = false
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
        guard let s = session else { if menuTitle != nil { menuTitle = nil }; return }
        let elapsed = s.elapsed(Date())
        if !goalHit, !s.paused, goalMinutes > 0, elapsed >= Double(goalMinutes * 60) { reachGoal() }
        let title = showInMenuBar ? (menuEmoji ? (s.paused ? "☕" : theme.emoji) + " " : "") + FocusSession.clock(elapsed) : nil
        if title != menuTitle { menuTitle = title }
    }

    /// The first time this run passes 목표 시간: a cheer, a line and the chime; the time keeps counting.
    private func reachGoal() {
        goalHit = true
        let g = goalMinutes
        let persona = AssistantModel.persona()
        let line = persona.style.banmal ? L("\(g)분 채웠다! 잠깐 쉬어도 돼.") : L("\(g)분 채웠어요! 쉬어 가도 좋아요.")
        DesktopKit.celebrate.send(.cheer)
        SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false, card: .cheer, anchor: DesktopFriends.speaker)
        chime()
    }

    /// AppKit's own Glass sound: no asset, fine in the App Store build.
    private func chime() { if sound && AppSettings.shared.friendSounds { NSSound(named: "Glass")?.play() } }
}
