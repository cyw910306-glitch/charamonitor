import AppKit
import SwiftUI

// A friend's chat as a visit (their character pops up over the Dock with the line), and the friend window.

/// A photo in the chat: the thumbnail, and the photo while it is one of the newest `PhotoRules.keepFull`.
struct ChatPhoto: Equatable {
    var thumb: Data
    var full: Data?
}

/// Chat history, in memory only: the last 50 lines per friend, never on disk (대화 모아보기 copies them, TalkLog; photos stay in memory).
final class SocialChat: ObservableObject {
    static let shared = SocialChat()
    static let keep = 50

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var mine: Bool
        var text: String
        /// The app's own line in the history (a dropped talk), not the friend's words.
        var note = false
        var photo: ChatPhoto?
    }

    @Published private(set) var log: [String: [Entry]] = [:]

    func append(_ friendID: String, _ text: String, mine: Bool, note: Bool = false, photo: PreparedPhoto? = nil) {
        var lines = log[friendID] ?? []
        lines.append(Entry(mine: mine, text: text, note: note, photo: photo.map { ChatPhoto(thumb: $0.thumb, full: $0.full) }))
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        // About 2 MiB each: the older photos keep only their thumbnail.
        let full = lines.indices.filter { lines[$0].photo?.full != nil }
        full.dropLast(PhotoRules.keepFull).forEach { lines[$0].photo?.full = nil }
        log[friendID] = lines
        if self === Self.shared { TalkLog.shared.add(TalkEntry(thread: friendID, name: "", text: text, mine: mine, note: note)) }
    }

    func clear(_ friendID: String) { log[friendID] = nil }
}

/// The friend's character in a small panel at the bottom right for 8 s, a speech line on it. A click opens their window.
final class FriendVisit {
    static let shared = FriendVisit()
    static let seconds: TimeInterval = 8
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    static let quietKey = "quiet.mode"
    /// 쉿 모드 (the menu bar menu, a 단축키): off at first, kept across launches.
    static var quietMode: Bool {
        get { AppDefaults.store.bool(forKey: quietKey) }
        set { AppDefaults.store.set(newValue, forKey: quietKey) }
    }

    /// 쉿 모드, a call app in front or a screen recorder running: no pop-up, bubble, emote or doodle (the menu gets
    /// an unread dot instead). Everything friendly that might show asks here.
    static func quiet() -> Bool {
        quietMode || MeetingMute.inMeeting()
            || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(MeetingMute.recorders.contains) == true }
    }

    /// Whether it showed. `named` puts "이름: " before the line. `photo` shows under it; a click on the bubble runs `tap`.
    @discardableResult
    func show(_ friendID: String, line: String, named: Bool = true, photo: NSImage? = nil, tap: (() -> Void)? = nil) -> Bool {
        guard let f = SocialBus.shared.friend(friendID), !Self.quiet() else { return false }
        let cache = DogSpriteCache(SpriteLook(friend: f.look), pixelSize: 2)
        let size = cache.imageSize
        let click = VisitClickView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: AnimatedDog(cache: cache, pose: .walk, cpu: 0.2))
        host.frame = click.bounds
        click.addSubview(host)
        click.onClick = { FriendWindow.open(friendID) }
        click.setAccessibilityElement(true)
        click.setAccessibilityRole(.button)
        click.setAccessibilityLabel(f.nickname)

        let p = panel ?? Self.makePanel()
        panel = p
        p.contentView = click
        p.setContentSize(size)
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        p.setFrameOrigin(CGPoint(x: vf.maxX - size.width - 40, y: vf.minY + 8))
        p.orderFrontRegardless()

        let text = named ? "\(f.nickname): \(line)" : line
        // 잠시 조용히 (or another held line) keeps the bubble off: then no visit either, the menu shows the unread dot.
        guard SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true, seconds: Self.seconds,
                                            anchor: { [weak p] in p.flatMap { $0.isVisible ? CGPoint(x: $0.frame.midX, y: $0.frame.maxY) : nil } },
                                            photo: photo, tap: tap)
        else { p.orderOut(nil); return false }
        hide?.cancel()
        let w = DispatchWorkItem { [weak p] in p?.orderOut(nil) }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds, execute: w)
        return true
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // a friend's words never go out in a screen share
        return p
    }
}

/// Takes the click (also the first one while another app is active).
private final class VisitClickView: NSView {
    var onClick: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// One window per friend: the chat, 무전기, 같이 놀기 and 원격 지원 요청.
enum FriendWindow {
    private static var windows: [String: NSWindow] = [:]
    private static var delegates: [String: Closer] = [:]

    static func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }

    static func open(_ id: String) {
        guard let f = SocialBus.shared.friend(id) else { return }
        SocialBus.shared.markRead(id)
        if let w = windows[id] { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = f.nickname
        w.contentView = NSHostingView(rootView: FriendChatView(friendID: id))
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.sharingType = .none
        let closer = Closer { windows[id] = nil; delegates[id] = nil; if VoiceTalk.shared.live == id { VoiceTalk.shared.end() } }
        w.delegate = closer
        delegates[id] = closer
        windows[id] = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private final class Closer: NSObject, NSWindowDelegate {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        func windowWillClose(_ notification: Notification) { run() }
    }
}

struct FriendChatView: View {
    let friendID: String
    @ObservedObject private var bus = SocialBus.shared
    @ObservedObject private var chat = SocialChat.shared
    @State private var text = ""
    @State private var lastSent = Date.distantPast
    @State private var photoNote: String?
    @State private var dropping = false

    private var friend: SocialFriend? { bus.friends.first { $0.id == friendID } }
    private var isOnline: Bool { bus.online.contains(friendID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chat.log[friendID] ?? []) { line in
                            HStack {
                                if line.mine { Spacer(minLength: 40) }
                                if let photo = line.photo {
                                    ChatPhotoView(photo: photo, title: line.mine ? L("나") : friend?.nickname ?? "")
                                } else {
                                    Text(verbatim: line.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(line.note ? .secondary : .primary)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(line.mine ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                                }
                                if !line.mine { Spacer(minLength: 40) }
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: chat.log[friendID]?.last?.id) { last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            HStack {
                TextField(L("메시지"), text: $text).textFieldStyle(.roundedBorder).onSubmit(send)
                Button(L("보내기"), action: send).disabled(!canSend)
            }
            ChatPhotoBar(friendID: friendID, note: $photoNote)
            if PluginGate.isOpen(.walkieTalkie), bus.defaults.bool(forKey: "social.voice") {
                TalkButton(friendID: friendID).disabled(!isOnline)
            }
            HStack {
                if NetPlay.ready, PluginGate.isOpen(.netPlay) {
                    Button(L("같이 뛰기")) { NetPlay.shared.invite(friendID, .play) }
                    Button(L("별 대결")) { NetPlay.shared.invite(friendID, .starDuel) }
                }
                if PluginGate.isOpen(.remoteHelp) {
                    Button(L("원격 지원 요청")) { RemoteHelp.shared.ask(friendID) }
                }
            }
            .disabled(!isOnline)
            .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 280, minHeight: 320)
        .overlay { if dropping { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4) } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            bus.canPhoto(friendID) && PhotoInput.drop(providers) { photoBar.send($0) }
        }
        .onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff]) { _ in if bus.canPhoto(friendID) { photoBar.send(PhotoInput.pasteboard()) } }
    }

    /// Drops and ⌘V (outside the text field) go the same way as the 사진 menu.
    private var photoBar: ChatPhotoBar { ChatPhotoBar(friendID: friendID, note: $photoNote) }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(isOnline ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(verbatim: friend?.nickname ?? "").font(.headline)
            Text(isOnline ? L("온라인") : L("오프라인")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let s = friend?.status, isOnline {
                Text(verbatim: "\(s.emoji) \(s.label)").font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private var canSend: Bool { isOnline && !SocialText.clean(text).isEmpty }

    private func send() {
        // The friend's Mac takes one line a second; wait out the rest of the second instead of losing it there.
        guard canSend, Date().timeIntervalSince(lastSent) >= 1 else { return }
        if bus.chat(text, to: friendID) {
            text = ""
            lastSent = Date()
        }
    }
}

/// Hold to talk: the mic is on only while pressed, and the button says so in red.
struct TalkButton: View {
    let friendID: String
    @ObservedObject private var talk = VoiceTalk.shared
    /// Resets by itself when the press is cancelled (the button turned disabled, the window went), unlike `onEnded`.
    @GestureState private var pressed = false

    var body: some View {
        let live = talk.live == friendID
        Label(live ? L("말하는 중") : L("누르고 있는 동안 말하기"), systemImage: live ? "mic.fill" : "mic")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(live ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(live ? Color.red : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { down in if down { talk.begin(friendID) } else { stop() } }
            .onDisappear(perform: stop)
            .accessibilityLabel(L("무전기"))
            .accessibilityHint(L("누르고 있는 동안 친구에게 목소리를 보내요"))
    }

    private func stop() { if talk.live == friendID { talk.end() } }
}
