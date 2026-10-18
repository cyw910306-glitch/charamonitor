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

    var body: some View {
        VStack(spacing: 6) {
            if let t = center.task { TaskPill(title: t.title, onDone: t.id == nil ? nil : { center.completeTask() }) }
            if let s = center.session {
                VStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(s.paused ? Color.secondary : Color.green).frame(width: 6, height: 6)
                        Text(s.paused ? "잠깐 쉬는 중" : "집중 중").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(verbatim: FocusSession.clock(s.elapsed(ctx.date))).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Button(s.paused ? "다시 시작" : "일시정지") { s.paused ? center.resume() : center.pause() }
                            .buttonStyle(.bordered)
                        Button("그만하기") { center.stop() }
                            .buttonStyle(.borderedProminent).tint(Color(red: 0.49, green: 0.38, blue: 0.9))
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                SpeechBubbleView.Tail().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 7).rotationEffect(.degrees(180))
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .padding(8)
        .fixedSize()
    }
}

/// "● 진행 중  주간 회의 자료 정리": the to-do at hand, with a tick to finish it in 미리알림.
struct TaskPill: View {
    let title: String
    var onDone: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
            Text("진행 중").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            if let onDone {
                Button(action: onDone) { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless).help(L("다 했어요")).accessibilityLabel(L("다 했어요"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
