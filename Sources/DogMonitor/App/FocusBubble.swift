import AppKit
import Combine
import SwiftUI

/// The 집중 위젯 over a desktop friend's head (or under the menu bar icon when none is out): "집중 중", the time
/// counting up, 일시정지 and 그만하기, and the 진행 중 pill for the to-do at hand. A small panel that takes clicks on
/// its buttons without taking the focus from the app in front; it follows its friend while it shows.
final class FocusBubble {
    static let shared = FocusBubble()
    private var panel: NSPanel?
    private var follow: Timer?
    private var anchor: (() -> CGPoint?)?
    private var changes: AnyCancellable?
    /// The friend's head the widget last went over; nil while it sits under the menu bar icon.
    private var over: CGPoint?

    /// How much higher a speech bubble over `point` sits: the widget's height while the widget is over that same friend.
    func lift(over point: CGPoint) -> CGFloat {
        guard panel?.isVisible == true, let o = over, hypot(o.x - point.x, o.y - point.y) < 24 else { return 0 }
        return panel?.frame.height ?? 0
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        p.contentView = FirstClickHost(rootView: FocusWidget(center: .shared))
        anchor = DesktopFriends.speaker
        resize()
        p.orderFrontRegardless()
        // The size changes only with what it shows (paused, the pill): a layout pass then, not on every follow tick.
        changes = FocusCenter.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.resize() }
        follow?.invalidate()
        // ponytail: 20 fps of following while a run lasts, cheap (no layout, no move while the friend stands still);
        // tie it to the friend's own tick if it ever shows in a profile.
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.place() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        follow = t
    }

    func hide() {
        follow?.invalidate(); follow = nil
        changes = nil
        panel?.orderOut(nil)
        anchor = nil
        over = nil
    }

    private func resize() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        if p.frame.size != size { p.setContentSize(size) }
        place()
    }

    private func place() {
        guard let p = panel else { return }
        over = anchor.flatMap { $0() }
        let size = p.frame.size
        let origin = over.map { SpeechBubbleWindow.above($0, size: size) } ?? SpeechBubbleWindow.underIcon(size: size)
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
    }

    private func makePanel() -> NSPanel {
        let p = FocusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // the to-do title stays out of screen shares
        return p
    }
}

/// Never key: pressing 일시정지 leaves the app in front as it was.
private final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click while another app is active (FriendQuickAsk uses it too).
final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FocusWidget: View {
    @ObservedObject var center: FocusCenter
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let hex = center.theme.hexes(dark: dark)
        let fill = WeatherArt.color(hex.fill), ink = WeatherArt.color(hex.ink), accent = WeatherArt.color(hex.accent)
        let k = center.size.scale
        let rim = RoundedRectangle(cornerRadius: 18 * k, style: .continuous)
        VStack(spacing: 6 * k) {
            if let t = center.task {
                TaskPill(title: t.title, onDone: t.id == nil ? nil : { center.completeTask() }, fill: fill, ink: ink, dark: dark, k: k)
            }
            if let s = center.session {
                VStack(spacing: 0) {
                VStack(spacing: 7 * k) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in status(s, now: ctx.date, ink: ink, accent: accent, k: k) }
                    HStack(spacing: 6 * k) {
                        Button(s.paused ? "다시 시작" : "일시정지") { s.paused ? center.resume() : center.pause() }
                            .buttonStyle(PillButton(fill: ink.opacity(0.12), text: ink, k: k))
                        Button("그만하기") { center.stop() }
                            .buttonStyle(PillButton(fill: accent, text: .white, k: k))
                    }
                }
                .padding(.horizontal, 16 * k).padding(.vertical, 11 * k)
                .background(rim.fill(fill))
                .overlay(rim.strokeBorder(Color.white.opacity(dark ? 0.35 : 1), lineWidth: 2.5))
                SpeechBubbleView.Tail().fill(fill).frame(width: 14 * k, height: 7 * k).rotationEffect(.degrees(180))
                    .padding(.top, -2.5)   // over the rim's bottom edge, so card and tail read as one sticker
                }
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(8)
        .fixedSize()
    }

    /// The heartbeat dot and the friend's line, the time, and the way to 목표 시간: one element for VoiceOver.
    private func status(_ s: FocusSession, now: Date, ink: Color, accent: Color, k: CGFloat) -> some View {
        let elapsed = s.elapsed(now), m = Int(elapsed / 60)
        let polite = !AssistantModel.persona().style.banmal
        let still = DesktopKit.reduceMotion || s.paused   // 꾸미기 > 움직임 too; read every second
        let beat = Int(now.timeIntervalSince1970) % 2 == 0
        let goal = center.goalMinutes
        return VStack(spacing: 5 * k) {
            HStack(spacing: 6 * k) {
                Circle().fill(s.paused ? ink.opacity(0.35) : accent).frame(width: 7 * k, height: 7 * k)
                    .scaleEffect(still || beat ? 1 : 1.35)
                    .animation(still ? nil : .easeInOut(duration: 0.9), value: beat)
                Text(verbatim: FocusSession.mood(elapsed: elapsed, hour: Calendar.current.component(.hour, from: now), paused: s.paused, polite: polite))
                    .font(.system(size: 12 * k, weight: .semibold, design: .rounded)).foregroundStyle(ink.opacity(0.78))
            }
            Text(verbatim: FocusSession.clock(elapsed))
                .font(.system(size: 26 * k, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(ink)
            if let p = FocusSession.progress(elapsed, goal: goal) {
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.12))
                    Capsule().fill(accent).frame(width: max(6, 120 * k * p))
                }
                .frame(width: 120 * k, height: 6 * k)
                Text(verbatim: p >= 1 ? L("목표 달성! 🎉") : L("목표까지 \(max(1, goal - m))분"))
                    .font(.system(size: 11 * k, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.7))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.paused ? L("잠깐 쉬는 중, \(m)분") : L("집중 \(m)분째"))
    }
}

/// "● 진행 중  주간 회의 자료 정리": the to-do at hand, with a tick to finish it in 미리알림. In the widget's colours.
struct TaskPill: View {
    let title: String
    var onDone: (() -> Void)?
    var fill: Color
    var ink: Color
    var dark: Bool
    var k: CGFloat = 1

    var body: some View {
        HStack(spacing: 6 * k) {
            Circle().fill(Color.orange).frame(width: 6 * k, height: 6 * k)
            Text("진행 중").font(.system(size: 11 * k, weight: .medium, design: .rounded)).foregroundStyle(ink.opacity(0.7))
            Text(verbatim: title).font(.system(size: 12 * k, weight: .semibold, design: .rounded)).foregroundStyle(ink)
                .lineLimit(1).frame(maxWidth: 200 * k, alignment: .leading)
            if let onDone {
                Button(action: onDone) { Image(systemName: "checkmark.circle.fill").foregroundStyle(ink.opacity(0.8)) }
                    .buttonStyle(.borderless).help(L("다 했어요")).accessibilityLabel(L("다 했어요"))
            }
        }
        .padding(.horizontal, 11 * k).padding(.vertical, 5 * k)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(dark ? 0.35 : 1), lineWidth: 2))
    }
}

/// The widget's capsule buttons (macOS 13 has no capsule bordered style): a soft press, no motion beyond the dim.
struct PillButton: ButtonStyle {
    var fill: Color
    var text: Color
    var k: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * k, weight: .bold, design: .rounded))
            .foregroundStyle(text)
            .padding(.horizontal, 12 * k).padding(.vertical, 5 * k)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
