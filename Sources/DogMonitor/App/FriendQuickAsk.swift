import AppKit
import Combine
import SwiftUI

/// 퀵물어보기: a click on a desktop friend opens a bubble over it with a few questions answered on this Mac, no AI
/// (today's to-dos, what to do now, the next event, a cheer, a dance), and a button to the AI 비서. An answer shows in
/// the same bubble with the chips still under it, so the next question is one tap. A click elsewhere closes it; no Esc,
/// since neither the bubble nor the friends ever take the keyboard (the key press goes to the app in front).
@MainActor
final class FriendQuickAsk: ObservableObject {
    static let shared = FriendQuickAsk()

    enum Chip: CaseIterable {
        case progress, now, next, cheer, dance

        var title: String {
            switch self {
            case .progress: return L("오늘 할 일 얼마나 했어요?")
            case .now: return L("지금 할 일 뭐 있어요?")
            case .next: return L("다음 일정은요?")
            case .cheer: return L("응원해 줘")
            case .dance: return L("춤춰 줘")
            }
        }
    }

    @Published private(set) var answer: String?
    /// The answer was about to-dos: a 할 일 보기 link under it.
    @Published private(set) var todos = false

    private var panel: NSPanel?
    private var follow: Timer?
    private var changes: AnyCancellable?
    private var monitors: [Any] = []
    private var anchor: (() -> CGPoint?)?
    /// The friend's own window: its click is its own toggle (close on a second click), not a click elsewhere.
    private weak var owner: NSWindow?

    var isOpen: Bool { panel?.isVisible == true }

    func show(from owner: NSWindow?, anchor: @escaping () -> CGPoint?) {
        answer = nil
        todos = false
        self.anchor = anchor
        self.owner = owner
        let p = panel ?? makePanel()
        panel = p
        p.contentView = FirstClickHost(rootView: FriendQuickAskView(model: self))
        resize()
        p.orderFrontRegardless()
        // A layout pass only when what it shows changes (an answer); the follow tick just moves it.
        changes = objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.resize() } }
        follow?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        follow = t
        guard monitors.isEmpty else { return }
        // A press anywhere else closes it (the real click goes on to whatever is there).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window !== self.panel, e.window !== self.owner { self.close() }
            }
            return e
        }) { monitors.append(l) }
    }

    func close() {
        follow?.invalidate(); follow = nil
        changes = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        panel?.orderOut(nil)
        anchor = nil
        owner = nil
    }

    private func resize() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        if p.frame.size != size { p.setContentSize(size) }
        place()
    }

    private func place() {
        guard let p = panel else { return }
        guard let a = anchor?() else { close(); return }   // its friend went away
        let o = SpeechBubbleWindow.above(a, size: p.frame.size, lift: FocusBubble.shared.lift(over: a))
        if p.frame.origin != o { p.setFrameOrigin(o) }
    }

    private func makePanel() -> NSPanel {
        let p = QuickAskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // to-do and event titles stay out of screen shares
        return p
    }

    // MARK: Answers (this Mac only)

    func ask(_ chip: Chip) async {
        let persona = AssistantModel.persona()
        let polite = !persona.style.banmal
        let s = AssistantSettings.shared   // 캘린더·미리알림 are AI 비서 integrations, with their own switches
        todos = false
        switch chip {
        case .progress:
            answer = TodoProgress.answer(await CalendarLink.shared.todayProgress(enabled: s.reminders), polite: polite)
            todos = s.reminders
        case .now:
            guard s.reminders && CalendarLink.authorized(.reminder) else { answer = TodoProgress.answer(nil, polite: polite); return }
            answer = TodoProgress.next(await CalendarLink.shared.todayTodos(enabled: true).map(\.title), polite: polite)
            todos = true
        case .next:
            answer = Self.nextEvent(s.calendar ? CalendarLink.shared.todayEvents().first.map { ($0.startDate, $0.title ?? L("일정")) } : nil,
                                    linked: s.calendar && CalendarLink.authorized(.event), polite: polite)
        case .cheer, .dance:
            let lines = chip == .cheer ? TemplateEngine.cheerLines : TemplateEngine.danceLines
            let p = LinePick.pick(chip == .cheer ? "chat.cheer" : "chat.dance", lines)
            answer = persona.exclaim(polite ? p.1 : p.0)
            SituationEngine.play([.special, .eat])
            DesktopKit.celebrate.send(chip == .cheer ? .cheer : .dance)
        }
    }

    /// "다음 일정은 15:00 '팀 회의'예요." Pure.
    static func nextEvent(_ e: (start: Date, title: String)?, linked: Bool, polite: Bool) -> String {
        guard linked else {
            return polite ? L("캘린더가 연결돼 있지 않아서 알 수 없어요. 비서 설정에서 캘린더를 켜 주세요.")
                          : L("캘린더가 연결돼 있지 않아서 몰라. 비서 설정에서 캘린더를 켜 줘.")
        }
        guard let e else { return polite ? L("오늘 남은 일정은 없어요.") : L("오늘 남은 일정은 없어.") }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let t = f.string(from: e.start)
        let end = polite ? Banmal.particle(e.title, "이에요", "예요") : Banmal.particle(e.title, "이야", "야")
        return L("다음 일정은 \(t) '\(e.title)'\(end).")
    }

    /// "더 물어보기" opens the chat.
    func openAI() {
        close()
        CursorBuddy.shared.openAssistant?()
    }
}

private final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct FriendQuickAskView: View {
    @ObservedObject var model: FriendQuickAsk

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let a = model.answer {
                    Text(verbatim: a).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if model.todos {
                        HStack {
                            Spacer()
                            Button("할 일 보기") {
                                if let url = URL(string: "x-apple-reminderkit://") { NSWorkspace.shared.open(url) }
                                model.close()
                            }
                            .buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                    Divider()
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text("무엇이 궁금하세요?").font(.system(size: 12, weight: .semibold))
                    }
                    Text("AI 없이도 이건 바로 알려 드려요").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ChipFlow(spacing: 4) {
                    ForEach(FriendQuickAsk.Chip.allCases, id: \.self) { c in
                        Button(c.title) { Task { await model.ask(c) } }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("더 물어보기") { model.openAI() }
                        .buttonStyle(.borderedProminent).tint(Color(red: 0.49, green: 0.38, blue: 0.9)).controlSize(.small)
                }
            }
            .frame(width: 268, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            SpeechBubbleView.Tail().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 7).rotationEffect(.degrees(180))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(8)
        .fixedSize()
    }
}
