import AppKit
import Combine
import SwiftUI

/// 퀵물어보기: a click on a 풀밭 친구 (⌥ click or the menu on the 커서 친구, ⌥ click on a 복제 친구) opens a bubble over it with a few questions answered on this Mac, no AI
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

        /// The pill's label: a glyph and two words. VoiceOver reads `title`.
        var short: String {
            switch self {
            case .progress: return L("✅ 오늘 진도")
            case .now: return L("👉 지금 할 일")
            case .next: return L("📅 다음 일정")
            case .cheer: return L("📣 응원해 줘")
            case .dance: return L("💃 춤춰 줘")
            }
        }
    }

    @Published private(set) var answer: String?
    /// The answer was about to-dos: a 할 일 보기 link under it.
    @Published private(set) var todos = false
    /// The friend's face in the header: waving until an answer, then its reaction to it.
    @Published private(set) var card: PoseCard = .wave
    /// The menu bar character's sprites, built once per character rather than on every tap.
    private static let sprites = SpriteHolder()
    /// The last to-do count, drawn as a bar under the 오늘 진도 answer.
    @Published private(set) var progress: TodoProgress?
    /// The chip the answer is for (its pill stays lit), and a count that pops the answer in even when the words repeat.
    @Published private(set) var asked: Chip?
    @Published private(set) var turn = 0

    private var panel: NSPanel?
    private var follow: Timer?
    private var changes: AnyCancellable?
    private var monitors: [Any] = []
    private var anchor: (() -> CGPoint?)?
    /// The friend's own window: its click is its own toggle (close on a second click), not a click elsewhere.
    private weak var owner: NSWindow?
    /// Which friend in `owner` it is over, for friends sharing one window.
    private var key: AnyHashable?

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens it over a friend; again over the same one closes it, over another friend it moves there.
    func toggle(from owner: NSWindow?, key: AnyHashable? = nil, anchor: @escaping () -> CGPoint?) {
        if isOpen, owner === self.owner, key == self.key { close() } else { show(from: owner, key: key, anchor: anchor) }
    }

    func show(from owner: NSWindow?, key: AnyHashable? = nil, anchor: @escaping () -> CGPoint?) {
        seed()
        self.anchor = anchor
        self.owner = owner
        self.key = key
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
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
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
        key = nil
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

    /// Sets what the bubble shows without asking anything: show() clears it, 설정's preview and the QA fill it.
    /// `card` drawn from the menu bar character, and whether to draw it smooth.
    var face: (image: NSImage, smooth: Bool)? {
        let c = Self.sprites.cache(for: .shared)
        return card.art(c).map { ($0, c.smooth) }
    }

    func seed(answer: String? = nil, chip: Chip? = nil, progress: TodoProgress? = nil, todos: Bool = false) {
        self.answer = answer
        self.asked = chip
        self.progress = progress
        self.todos = todos
        card = chip.map { Self.card(for: $0, progress: progress) } ?? .wave
    }

    /// A bubble that answered 오늘 진도 with 3 of 4 done: 설정's live preview and the QA.
    static func sample(_ p: TodoProgress = TodoProgress(done: 3, total: 4)) -> FriendQuickAsk {
        let m = FriendQuickAsk()
        m.seed(answer: TodoProgress.answer(p, polite: !AssistantModel.persona().style.banmal), chip: .progress, progress: p)
        return m
    }

    // MARK: Answers (this Mac only)

    func ask(_ chip: Chip) async {
        let persona = AssistantModel.persona()
        let polite = !persona.style.banmal
        let s = AssistantSettings.shared   // 캘린더·미리알림 are AI 비서 integrations, with their own switches
        todos = false
        progress = nil
        defer {
            asked = chip
            card = Self.card(for: chip, progress: progress)
            turn += 1
            if MotionStore.shared.quickAskSound && card != .wave { ChimeSound.play(2, volume: 0.25) }
        }
        switch chip {
        case .progress:
            progress = await CalendarLink.shared.todayProgress(enabled: s.reminders)
            answer = TodoProgress.answer(progress, polite: polite)
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

    /// The face that answers `chip`: proud when today's to-dos are all done. Pure.
    nonisolated static func card(for chip: Chip, progress: TodoProgress?) -> PoseCard {
        switch chip {
        case .progress: return progress?.allDone == true ? .proud : .cheer
        case .now, .next: return .wave
        case .cheer: return .cheer
        case .dance: return .dance
        }
    }

    /// The header before any answer, by the hour. Pure.
    nonisolated static func greeting(hour: Int, polite: Bool) -> String {
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        switch hour {
        case 5..<11: return say(L("좋은 아침! 뭐 궁금해?"), L("좋은 아침이에요! 뭐 궁금해요?"))
        case 11..<14: return say(L("점심 먹었어? 뭐 궁금해?"), L("점심 먹었어요? 뭐 궁금해요?"))
        case 14..<18: return say(L("오후도 힘내! 뭐 궁금해?"), L("오후도 힘내요! 뭐 궁금해요?"))
        case 18..<22: return say(L("오늘 하루 어땠어? 뭐 궁금해?"), L("오늘 하루 어땠어요? 뭐 궁금해요?"))
        default: return say(L("밤이 깊었네. 뭐 도와줄까?"), L("밤이 깊었네요. 뭐 도와줄까요?"))
        }
    }

    /// The little burst over a cheer, a dance or all done, in the season's glyphs. Pure.
    nonisolated static func confetti(month: Int) -> [String] {
        switch month {
        case 3...5: return ["🌸", "🌷", "✨"]
        case 6...8: return ["🍉", "🌻", "✨"]
        case 9...11: return ["🍂", "🍁", "✨"]
        case 12: return ["⛄️", "❄️", "✨"]
        default: return ["✨", "💖", "⭐️"]
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


/// 퀵물어보기 색 테마: a pastel sticker in light, a deep tint in dark.
enum QuickAskTheme: String, CaseIterable {
    case peach, mint, lavender, sky, lemon

    var label: String {
        switch self {
        case .peach: return L("복숭아")
        case .mint: return L("민트")
        case .lavender: return L("라벤더")
        case .sky: return L("하늘")
        case .lemon: return L("레몬")
        }
    }

    /// Hexes for light or dark: the bubble's fill, its text, and the accent (white text on it at least 4.5:1).
    func hexes(dark: Bool) -> (fill: String, ink: String, accent: String) {
        switch (self, dark) {
        case (.peach, false): return ("#FFF1E8", "#4A3428", "#C4532E")
        case (.peach, true): return ("#3B2A2A", "#FFE6DA", "#C4532E")
        case (.mint, false): return ("#DDF5EA", "#1F4A3C", "#1F8460")
        case (.mint, true): return ("#1F3A33", "#CDEFE0", "#1F8460")
        case (.lavender, false): return ("#EFE8FC", "#3E3166", "#7459E0")
        case (.lavender, true): return ("#2E2747", "#E4DAF7", "#7459E0")
        case (.sky, false): return ("#E0F0FD", "#23415E", "#2A72B0")
        case (.sky, true): return ("#1F3247", "#D3EAFB", "#2A72B0")
        case (.lemon, false): return ("#FFF4C7", "#5C4500", "#9A6A00")
        case (.lemon, true): return ("#3E3620", "#FFF0B8", "#9A6A00")
        }
    }
}

/// 퀵물어보기 글자 크기: the answer's point size, with the bubble a little wider so lines wrap the same.
enum QuickAskTextSize: String, CaseIterable {
    case small, regular, large

    var label: String {
        switch self {
        case .small: return L("작게")
        case .regular: return L("보통")
        case .large: return L("크게")
        }
    }

    var points: CGFloat {
        switch self {
        case .small: return 12
        case .regular: return 13
        case .large: return 15
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 268
        case .regular: return 300
        case .large: return 330
        }
    }
}

/// 퀵물어보기 움직임: 통통 pops the answer and bursts, 잔잔 fades with a small burst, 멈춤 none. 동작 줄이기 = 멈춤.
enum QuickAskMotion: String, CaseIterable {
    case bouncy, gentle, still

    var label: String {
        switch self {
        case .bouncy: return L("통통")
        case .gentle: return L("잔잔")
        case .still: return L("멈춤")
        }
    }
}

struct FriendQuickAskView: View {
    @ObservedObject var model: FriendQuickAsk
    @ObservedObject var store: MotionStore = .shared
    @Environment(\.colorScheme) private var scheme
    /// The answer pops in from 0.92 on each turn; the burst flies once over a happy face.
    @State private var popped = true
    @State private var burst = false
    @State private var flying = false

    /// 꾸미기 > 움직임 잔잔하게 (or 자동 with 동작 줄이기) is 멈춤 here too.
    private var motion: QuickAskMotion { DesktopKit.reduceMotion ? .still : store.quickAskMotion }

    var body: some View {
        let dark = scheme == .dark
        let hex = store.quickAskTheme.hexes(dark: dark)
        let fill = WeatherArt.color(hex.fill), ink = WeatherArt.color(hex.ink), accent = WeatherArt.color(hex.accent)
        let pt = store.quickAskTextSize.points
        let rim = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    if store.quickAskShowAvatar, let art = model.face { avatar(art, dark: dark) }
                    VStack(alignment: .leading, spacing: 4) {
                        if let a = model.answer { answer(a, ink: ink, accent: accent, pt: pt) } else { greeting(ink: ink, pt: pt) }
                    }
                    .frame(maxWidth: .infinity, minHeight: store.quickAskShowAvatar ? 38 : 0, alignment: .leading)
                    .scaleEffect(popped || motion != .bouncy ? 1 : 0.92, anchor: .leading)
                    .opacity(popped || motion == .still ? 1 : 0)
                }
                ChipFlow(spacing: 6) {
                    ForEach(FriendQuickAsk.Chip.allCases, id: \.self) { c in
                        Button(c.short) { Task { await model.ask(c) } }
                            .buttonStyle(QuickChipStyle(fill: accent.opacity(model.asked == c ? 0.4 : 0.16), ink: ink, pt: pt - 1,
                                                        squish: motion != .still))
                            .accessibilityLabel(c.title)
                            .accessibilityAddTraits(model.asked == c ? .isSelected : [])
                    }
                }
                Button { model.openAI() } label: {
                    Label("더 물어보기", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuickChipStyle(fill: accent, ink: .white, pt: pt - 1, weight: .bold, squish: motion != .still))
            }
            .frame(width: store.quickAskTextSize.width, alignment: .leading)
            .padding(12)
            .background(rim.fill(fill))
            .overlay(rim.strokeBorder(Color.white.opacity(dark ? 0.18 : 1), lineWidth: 2.5))
            .overlay { if burst { confetti } }
            SpeechBubbleView.Tail().fill(fill).frame(width: 14, height: 7).rotationEffect(.degrees(180))
                .padding(.top, -2.5)   // over the rim's bottom edge, so bubble and tail read as one sticker
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(8)
        .fixedSize()
        .foregroundStyle(ink)
        .onChange(of: model.turn) { _ in react() }
    }

    /// The friend's face: a white-rimmed sticker, waving or reacting to the answer.
    private func avatar(_ art: (image: NSImage, smooth: Bool), dark: Bool) -> some View {
        let r = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Image(nsImage: art.image).resizable().interpolation(art.smooth ? .high : .none).aspectRatio(contentMode: .fit)
            .padding(2)
            .frame(width: 38, height: 38)
            .background(r.fill(Color.white.opacity(dark ? 0.1 : 0.75)))
            .overlay(r.strokeBorder(Color.white.opacity(dark ? 0.3 : 1), lineWidth: 2))
            .accessibilityHidden(true)
    }

    private func greeting(ink: Color, pt: CGFloat) -> some View {
        let polite = !AssistantModel.persona().style.banmal
        return Group {
            Text(verbatim: FriendQuickAsk.greeting(hour: Calendar.current.component(.hour, from: Date()), polite: polite))
                .font(.system(size: pt, weight: .semibold, design: .rounded))
            Text(verbatim: polite ? L("AI 없이도 이건 바로 알려 드려요") : L("AI 없이도 이건 바로 알려 줄게"))
                .font(.system(size: pt - 2, design: .rounded)).foregroundStyle(ink.opacity(0.65))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func answer(_ a: String, ink: Color, accent: Color, pt: CGFloat) -> some View {
        Text(verbatim: a).font(.system(size: pt, design: .rounded)).fixedSize(horizontal: false, vertical: true)
        if let p = model.progress, p.total > 0 {
            HStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.12))
                        Capsule().fill(accent).frame(width: max(6, g.size.width * min(1, CGFloat(p.done) / CGFloat(p.total))))
                    }
                }
                .frame(height: 6)
                Text(verbatim: "\(p.done)/\(p.total)").font(.system(size: pt - 2, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(ink.opacity(0.75))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("오늘 할 일"))
            .accessibilityValue("\(p.done)/\(p.total)")
        }
        if model.todos {
            Button("할 일 보기") {
                if let url = URL(string: "x-apple-reminderkit://") { NSWorkspace.shared.open(url) }
                model.close()
            }
            .buttonStyle(.link).font(.system(size: pt - 2, weight: .medium, design: .rounded)).tint(accent)
        }
    }

    /// The season's glyphs flying out from the middle and fading. Never under 멈춤 or 동작 줄이기.
    private var confetti: some View {
        let glyphs = FriendQuickAsk.confetti(month: Calendar.current.component(.month, from: Date()))
        let far: CGFloat = motion == .bouncy ? 1 : 0.6
        let angles: [Double] = [-160, -120, -60, -20, 30, 150]
        return ZStack {
            ForEach(angles.indices, id: \.self) { i in
                let a = angles[i] * .pi / 180, d = (i.isMultiple(of: 2) ? 70 : 52) * far
                Text(verbatim: glyphs[i % glyphs.count]).font(.system(size: 15))
                    .offset(x: flying ? cos(a) * d : 0, y: flying ? sin(a) * d * 0.6 : 0)
                    .scaleEffect(flying ? 1 : 0.4)
                    .opacity(flying ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A new answer: pop it in, and burst over a cheer, a dance or all done.
    private func react() {
        guard motion != .still else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { popped = false; flying = false; burst = model.card != .wave }
        DispatchQueue.main.async {
            withAnimation(motion == .bouncy ? .spring(response: 0.3, dampingFraction: 0.7) : .easeOut(duration: 0.15)) { popped = true }
            guard burst else { return }
            withAnimation(.easeOut(duration: 0.7)) { flying = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { burst = false }
        }
    }
}

/// The bubble's capsule pills: soft fill, rounded type, a small squish while pressed (none under 멈춤).
private struct QuickChipStyle: ButtonStyle {
    var fill: Color
    var ink: Color
    var pt: CGFloat
    var weight: Font.Weight = .medium
    var squish = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: pt, weight: weight, design: .rounded))
            .foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(squish && configuration.isPressed ? 0.94 : 1)
            .animation(squish ? .easeOut(duration: 0.1) : nil, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
