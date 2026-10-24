import AppKit
import Combine
import SwiftUI

/// Who is talking in a speech bubble.
enum SpeechSource: String {
    case pet          // 펫 키우기: hungry, 20-20-20 눈 휴식, mission done
    case assistant    // AI 비서: 먼저 말 걸기, answers, charamonitor://say
    case system       // template lines from the app itself (free)
}

/// The picture card a line can pop up with (리액션 스티커): one of the character's own frames, drawn big. 뿌듯 glows.
enum PoseCard: String, CaseIterable {
    case cheer, dance, proud, sleepy, wave

    /// The frame it shows from `cache`: an extra motion where the character has one, else a pose.
    func art(_ cache: DogSpriteCache) -> NSImage? {
        switch self {
        case .cheer: return (cache.frames(forExtra: .eat) ?? cache.frames(for: .walk)).first
        case .dance, .proud: return (cache.frames(forExtra: .special) ?? cache.frames(for: .run)).first
        case .sleepy: return cache.frames(for: .lying).first
        case .wave: return cache.frames(for: .walk).first
        }
    }

    /// The menu bar character's frame for this card, and whether to draw it smooth (an illustration).
    var art: (image: NSImage, smooth: Bool)? {
        let cache = DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: 3)
        return art(cache).map { ($0, cache.smooth) }
    }

    var glows: Bool { self == .proud }
}

struct SpeechLine: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var source: SpeechSource
    var date: Date
    /// An important line (calendar, battery, tour): lines that are not held themselves do not replace it while it shows.
    var hold = false
    /// Seconds it stays, nil = long enough to read (SpeechBubbleWindow.duration). A calendar alert stays longer,
    /// and the tour waits for its click.
    var seconds: TimeInterval?
    /// News (calendar, a phone notification, a goal): the bubble shows a close mark. A click anywhere still closes it.
    var closable = false
    /// A picture card under the words (리액션 스티커).
    var card: PoseCard?
    /// 오늘의 운세: its card under the words.
    var fortune: FortuneReading?
    /// Where it points: the top middle of a desktop friend (screen points), followed while it shows; nil when that
    /// friend is gone. No anchor: the menu bar icon (or the cursor friend).
    var anchor: (() -> CGPoint?)?
    /// Hangs under `anchor` (a friend's feet along the top of the screen), its tail up.
    var under = false
    /// Under the menu bar icon even while the 커서 친구 is on (the tour).
    var atIcon = false
    /// A friend's photo thumbnail under the words (사진 메시지).
    var photo: NSImage?
    /// What a click does before the bubble closes (a photo opens big).
    var tap: (() -> Void)?

    static func == (a: SpeechLine, b: SpeechLine) -> Bool { a.id == b.id }

    var shown: TimeInterval { seconds ?? SpeechBubbleWindow.duration(text) }

    /// Whether a new line may replace this one at `now`: a held line keeps off every unheld line, whatever its source
    /// (an AI-written nudge is .assistant too), until it would have hidden by itself. Another held line may.
    func yields(hold newHold: Bool, now: Date) -> Bool {
        !hold || newHold || now.timeIntervalSince(date) >= shown
    }
}

/// Several lines for one moment, never the same one twice in a row (a refilled shuffle bag). Safe from any thread.
enum LinePick {
    private static let lock = NSLock()
    /// The index last picked per key.
    private(set) static var last: [String: Int] = [:]

    /// An index in 0..<n, never `last` when there are two or more. `random(k)` gives 0..<k (tests pass their own).
    static func next(_ n: Int, last: Int?, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        guard n > 1 else { return 0 }
        guard let last, (0..<n).contains(last) else { return random(n) }
        let r = random(n - 1)
        return r >= last ? r + 1 : r
    }

    /// One of `lines` for `key` ("nudge.hot", "pet.hungry"), not the one this key gave last time.
    static func pick<T>(_ key: String, _ lines: [T]) -> T {
        lock.lock(); defer { lock.unlock() }
        let i = next(lines.count, last: last[key])
        last[key] = i
        return lines[i]
    }
}

/// When the bubble on screen goes: `shown` after its line came, pushed on while the pointer rests on it, and never
/// sooner than `hoverGrace` after the pointer leaves. A wall-clock time, so a timer that App Nap fires late still finds it due.
struct BubbleDeadline {
    static let hoverGrace: TimeInterval = 3
    private(set) var at: Date
    private(set) var hovering = false

    init(_ line: SpeechLine) { at = line.date + line.shown }

    /// Whether to hide at `now`. While hovered it is never due; `at` moves on by `hoverGrace` instead.
    mutating func due(now: Date) -> Bool {
        if hovering { at = max(at, now + Self.hoverGrace); return false }
        return now >= at
    }

    mutating func hover(_ on: Bool, now: Date) {
        hovering = on
        if !on { at = max(at, now + Self.hoverGrace) }
    }
}

/// Whether a line may show: never while muted (잠시 조용히, or a call app in front), and the same words from
/// the same source at most once in 10 minutes. Pure; the 먼저 말 걸기 spacing (NudgeGate) is on top of this.
struct BubbleGate {
    static let repeatWindow: TimeInterval = 10 * 60
    private(set) var recent: [String: Date] = [:]

    /// `repeats`: news that may be the same words again (a second "엄마한테서 문자 왔어"), still never while muted.
    mutating func allow(_ text: String, source: SpeechSource, muted: Bool, now: Date, repeats: Bool = false) -> Bool {
        guard !muted else { return false }
        let key = source.rawValue + "|" + text
        if !repeats, let last = recent[key], now.timeIntervalSince(last) < Self.repeatWindow { return false }
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        recent[key] = now
        return true
    }
}

/// The one speech bubble of the menu bar character, shared by 펫 키우기 and AI 비서 so they never talk over each other.
/// Callers only say(); SpeechBubbleWindow draws it under the menu bar icon (or by the cursor friend).
final class SpeechBubbleCenter: ObservableObject {
    static let shared = SpeechBubbleCenter()
    static let maxLength = 200

    @Published private(set) var current: SpeechLine?
    private var gate = BubbleGate()
    /// QA and tests: what counts as muted (default: 잠시 조용히, 쉿 모드 or a call app in front).
    var isMuted: () -> Bool = { AssistantSettings.shared.isMuted() || FriendVisit.quietMode || MeetingMute.inMeeting() }

    /// Safe from any thread. Blank text is ignored; long text is cut at `maxLength` characters. `aloud` false never
    /// reads it out (lines from outside the app). Returns whether the line showed; from another thread it is posted
    /// later and the answer is true. `repeats` skips the 10-minute same-words gate (BubbleGate). `hold`: an important
    /// line that unheld lines do not cover while it shows (SpeechLine.yields). `seconds`: how long it stays, nil = by length.
    /// `closable`: news, drawn with a close mark (SpeechLine.closable).
    @discardableResult
    func say(text: String, source: SpeechSource, aloud: Bool = true, repeats: Bool = false, hold: Bool = false,
             seconds: TimeInterval? = nil, closable: Bool = false, card: PoseCard? = nil, fortune: FortuneReading? = nil, anchor: (() -> CGPoint?)? = nil,
             under: Bool = false, atIcon: Bool = false, asked: Bool = false, photo: NSImage? = nil, tap: (() -> Void)? = nil) -> Bool {
        // Long dashes out of every line, the agent's and goals' model text included (AssistantPrompt.undash).
        let line = String(AssistantPrompt.undash(text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard !line.isEmpty else { return false }
        let post = { () -> Bool in
            let now = Date()
            guard self.current?.yields(hold: hold, now: now) ?? true,
                  self.gate.allow(line, source: source, muted: !asked && self.isMuted(), now: now, repeats: repeats) else { return false }
            self.current = SpeechLine(text: line, source: source, date: now, hold: hold, seconds: seconds, closable: closable,
                                      card: card, fortune: fortune, anchor: anchor, under: under, atIcon: atIcon, photo: photo, tap: tap)
            if aloud && AssistantSettings.shared.voice { AssistantVoice.shared.speak(line) }
            return true
        }
        if Thread.isMainThread { return post() }
        DispatchQueue.main.async { _ = post() }
        return true
    }

    func dismiss() {
        if Thread.isMainThread { current = nil } else { DispatchQueue.main.async { self.current = nil } }
    }
}

/// Draws SpeechBubbleCenter.current in a small floating panel: just under the menu bar icon, or next to the
/// cursor while the 커서 친구 follows it. A click anywhere on it closes it (or shows the tour's next step); it also
/// goes by itself at its BubbleDeadline, later while the pointer is on it.
final class SpeechBubbleWindow {
    static let shared = SpeechBubbleWindow()
    private var panel: NSPanel?
    private var deadline: BubbleDeadline?
    private var shownID: UUID?
    private var hideTimer: Timer?
    /// An anchored line follows its friend.
    private var followTimer: Timer?
    private var bag = Set<AnyCancellable>()

    func start() {
        guard bag.isEmpty else { return }
        SpeechBubbleCenter.shared.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.show($0) }
            .store(in: &bag)
        // A timer held back through sleep fires late: on waking, a line already past its time goes at once.
        let nc = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSWorkspace.didWakeNotification).merge(with: nc.publisher(for: NSWorkspace.screensDidWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.expire() }
            .store(in: &bag)
    }

    /// Seconds a line stays: long enough to read, 6 to 15.
    static func duration(_ text: String) -> TimeInterval { min(15, max(6, Double(text.count) * 0.15)) }

    private func show(_ line: SpeechLine?) {
        hideTimer?.invalidate()
        followTimer?.invalidate(); followTimer = nil
        deadline = nil
        guard let line else { hide(); return }
        let byCursor = MotionStore.shared.cursorBuddy && !line.atIcon
        let anchor = line.anchor.flatMap { $0() }
        let art = line.card?.art
        let host = NSHostingView(rootView: SpeechBubbleView(text: line.text, tailUp: anchor == nil && !byCursor || line.under,
                                                            closable: line.closable, tailDown: anchor != nil && !line.under, card: line.card, art: art?.image, smooth: art?.smooth ?? false, fortune: line.fortune,
                                                            photo: line.photo, still: DesktopKit.reduceMotion))
        let size = host.fittingSize
        let click = BubbleClickView(frame: NSRect(origin: .zero, size: size))
        host.frame = click.bounds
        click.addSubview(host)
        click.onClick = {
            line.tap?()
            if line.tap != nil || !Tour.advance(line.text) { SpeechBubbleCenter.shared.dismiss() }
        }
        click.onHover = { [weak self] on in
            self?.deadline?.hover(on, now: Date())
            if !on { self?.arm() }
        }
        click.setAccessibilityElement(true)
        click.setAccessibilityRole(.button)
        click.setAccessibilityLabel(line.text)

        let p = panel ?? makePanel()
        panel = p
        p.contentView = click
        p.setContentSize(size)
        p.alphaValue = 1
        let place = { (a: CGPoint, size: CGSize) in line.under ? Self.below(a, size: size) : Self.above(a, size: size, lift: FocusBubble.shared.lift(over: a)) }
        p.setFrameOrigin(anchor.map { place($0, size) } ?? origin(size: size, byCursor: byCursor))
        p.orderFrontRegardless()
        if let follow = line.anchor, anchor != nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak p] _ in
                guard let p, let a = follow() else { return }
                let o = place(a, p.frame.size)
                if o != p.frame.origin { p.setFrameOrigin(o) }
            }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        }

        shownID = line.id
        deadline = BubbleDeadline(line)
        arm()
    }

    /// One timer, at the deadline. It checks again when it fires: hovering pushes the deadline on.
    private func arm() {
        hideTimer?.invalidate()
        guard let at = deadline?.at else { return }
        let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.expire() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func expire() {
        guard var d = deadline else { return }
        let due = d.due(now: Date())
        deadline = d
        guard due else { arm(); return }
        deadline = nil
        if SpeechBubbleCenter.shared.current?.id == shownID { SpeechBubbleCenter.shared.dismiss() }
    }

    /// Fades out (instantly under 동작 줄이기), so a card does not blink away.
    private func hide() {
        guard let p = panel, p.isVisible else { return }
        guard !DesktopKit.reduceMotion else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) { [weak self] in
            if self?.deadline == nil, SpeechBubbleCenter.shared.current == nil { p.orderOut(nil) }
            p.alphaValue = 1
        }
    }

    /// Its tail on `point` (a friend's head), `lift` higher (the 집중 위젯 already sits there), kept on that screen.
    static func above(_ point: CGPoint, size: CGSize, lift: CGFloat = 0) -> CGPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return BuddyMath.clamp(CGPoint(x: point.x - size.width / 2, y: point.y - 4 + lift), size: size, in: screen?.visibleFrame ?? .zero)
    }

    /// Its tail on `point` from under (a friend's feet along the top), kept on that screen.
    static func below(_ point: CGPoint, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return BuddyMath.clamp(CGPoint(x: point.x - size.width / 2, y: point.y + 4 - size.height), size: size, in: screen?.visibleFrame ?? .zero)
    }

    /// Our status item lives in an NSStatusBarWindow; the app has exactly one.
    static var iconFrame: CGRect? { NSApp.windows.first { $0.className == "NSStatusBarWindow" && $0.isVisible }?.frame }

    /// Right under the menu bar icon (by the cursor when there is none).
    static func underIcon(size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let at = iconFrame.map { CGPoint(x: $0.midX - size.width / 2, y: $0.minY - size.height - 2) } ?? CGPoint(x: mouse.x + 16, y: mouse.y + 10)
        let screen = NSScreen.screens.first { NSMouseInRect(CGPoint(x: at.x + size.width / 2, y: at.y + size.height), $0.frame, false) } ?? NSScreen.main
        return BuddyMath.clamp(at, size: size, in: screen?.visibleFrame ?? .zero)
    }

    private func origin(size: CGSize, byCursor: Bool) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let icon = Self.iconFrame
        let anchor: CGPoint = byCursor || icon == nil
            ? CGPoint(x: mouse.x + 16, y: mouse.y + 10)
            : CGPoint(x: icon!.midX - size.width / 2, y: icon!.minY - size.height - 2)
        let screen = NSScreen.screens.first { NSMouseInRect(byCursor ? mouse : CGPoint(x: icon?.midX ?? mouse.x, y: icon?.midY ?? mouse.y), $0.frame, false) }
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        return BuddyMath.clamp(anchor, size: size, in: bounds)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // the SwiftUI shape draws its own
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // never in a screen share or recording: it can carry a text's sender and words
        return p
    }
}

/// Takes every click inside it (the SwiftUI view underneath only draws), including the first click while
/// another app is active.
private final class BubbleClickView: NSView {
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// The bubble itself: text in a rounded card, with a small tail pointing up at the menu bar icon.
struct SpeechBubbleView: View {
    let text: String
    var tailUp = true
    /// A small close mark in the corner (the whole bubble takes the click).
    var closable = false
    /// Pointing down at a desktop friend.
    var tailDown = false
    var card: PoseCard?
    var art: NSImage?
    var smooth = false
    var fortune: FortuneReading?
    var photo: NSImage?
    /// 동작 줄이기: the card fades in, no pop.
    var still = false
    @State private var popped = false
    /// The 시즌 말풍선 색 when one is worn (pale, so its text is dark in both appearances).
    private let tint = SeasonCenter.shared.bubbleHex.map { hex in
        let c = RGBColor(hex: hex)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
    private var paper: Color { tint ?? Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        VStack(spacing: 0) {
            if tailUp { Tail().fill(paper).frame(width: 14, height: 7) }
            words
            if let card, let art {
                PoseCardView(image: art, smooth: smooth, glows: card.glows).padding(.top, 6)
                    .scaleEffect(still || popped ? 1 : 0.6, anchor: .bottom)
                    .opacity(popped ? 1 : 0)
                    .onAppear { withAnimation(still ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.55)) { popped = true } }
            }
            if let fortune { FortuneCardView(reading: fortune).padding(.top, 4) }
            if let photo {
                let s = PhotoZoomView.fit(photo.size, in: CGSize(width: 160, height: 160))
                Image(nsImage: photo).resizable().interpolation(.high)
                    .frame(width: s.width, height: s.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white, lineWidth: 3))
                    .padding(.top, 6)
                    .accessibilityLabel(L("사진, 눌러서 크게 보기"))
            }
            if tailDown { Tail().fill(paper).frame(width: 14, height: 7).rotationEffect(.degrees(180)) }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(card == nil ? 8 : 22)   // room for the shadow (and a card's glow) inside the panel
        .fixedSize()
    }

    private var words: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint == nil ? Color.primary : Color(white: 0.12))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.width(text), alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(paper))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if closable {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                            .padding(5).accessibilityLabel("닫기")
                    }
                }
        }
    }

    /// One line up to 240 pt, wrapping beyond (a fixed-size view would otherwise grow to the whole line).
    static func width(_ text: String) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return min(240, ceil(w) + 2)
    }

    /// The card: about 100 pt, rounded, a white rim; 뿌듯 has a warm glow behind it.
    private struct PoseCardView: View {
        let image: NSImage
        let smooth: Bool
        let glows: Bool

        var body: some View {
            Image(nsImage: image).resizable().interpolation(smooth ? .high : .none).aspectRatio(contentMode: .fit)
                .padding(10)
                .frame(width: 96, height: 96)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white, lineWidth: 3))
                .background {
                    if glows {
                        Circle().fill(RadialGradient(colors: [Color(red: 1, green: 0.86, blue: 0.3).opacity(0.85), .clear],
                                                     center: .center, startRadius: 10, endRadius: 80))
                            .frame(width: 150, height: 150).blur(radius: 6)
                    }
                }
                .accessibilityHidden(true)
        }
    }

    /// The little triangle; FocusBubble uses it too.
    struct Tail: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
