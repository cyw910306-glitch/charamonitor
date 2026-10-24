import AppKit
import Combine
import SwiftUI

/// 포스트잇 colours. Raw values are saved; never rename one.
enum StickyColor: String, Codable, CaseIterable {
    case lemon, peach, mint, sky, lilac

    var label: String {
        switch self {
        case .lemon: return L("레몬")
        case .peach: return L("복숭아")
        case .mint: return L("민트")
        case .sky: return L("하늘")
        case .lilac: return L("라일락")
        }
    }

    /// The paper, light in both appearances (a paper note stays paper in dark mode).
    var paper: Color {
        switch self {
        case .lemon: return WeatherArt.color("#FFF1A8")
        case .peach: return WeatherArt.color("#FFD6C4")
        case .mint: return WeatherArt.color("#CDF2DC")
        case .sky: return WeatherArt.color("#CFE6FF")
        case .lilac: return WeatherArt.color("#E4D9FF")
        }
    }

    /// The darker strip at the top and the dots.
    var strip: Color {
        switch self {
        case .lemon: return WeatherArt.color("#F5DC5E")
        case .peach: return WeatherArt.color("#FFB596")
        case .mint: return WeatherArt.color("#9EE3BA")
        case .sky: return WeatherArt.color("#A3CCF7")
        case .lilac: return WeatherArt.color("#C7B4F5")
        }
    }
}

/// One 포스트잇. `x`, `y` is the panel's top left in screen points (y up), so folding keeps the strip in place.
struct StickyNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = ""
    var color = StickyColor.lemon
    var x: Double
    var y: Double
    var folded = false
}

/// The notes file: Application Support/DogMonitor/Stickies.json, on this Mac only. Not in 내 설정 파일 (that takes only
/// Packs, Characters and Pictures), never sent anywhere.
enum StickyFile {
    static let maxNotes = 20
    static let maxText = 4000
    /// A bigger file is not read (20 full notes are well under it).
    static let maxBytes = 256 * 1024

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Stickies.json")
    }

    /// The notes in `data`: none when it is too big or broken; past `maxNotes` dropped, long text cut, a position that
    /// is not a number put at 0 (StickyMath.onScreen brings it back), a repeated id dropped.
    static func decode(_ data: Data) -> [StickyNote] {
        guard data.count <= maxBytes, let raw = try? JSONDecoder().decode([StickyNote].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return raw.filter { seen.insert($0.id).inserted }.prefix(maxNotes).map { n in
            var n = n
            if n.text.count > maxText { n.text = String(n.text.prefix(maxText)) }
            if !n.x.isFinite { n.x = 0 }
            if !n.y.isFinite { n.y = 0 }
            return n
        }
    }

    static func encode(_ notes: [StickyNote]) -> Data {
        (try? JSONEncoder().encode(Array(notes.prefix(maxNotes)))) ?? Data("[]".utf8)
    }
}

/// Where notes go and where the 커서 친구 stands to type along. Screen points, y up.
enum StickyMath {
    static let width: CGFloat = 210, height: CGFloat = 190
    /// A folded note: the strip only.
    static let foldedHeight: CGFloat = 30
    /// After the last key this long, the friend goes back.
    static let typingPause: TimeInterval = 1.5
    /// The friend's gap from the note's side.
    static let typingGap: CGFloat = 4

    static func frame(_ n: StickyNote) -> CGRect {
        let h = n.folded ? foldedHeight : height
        return CGRect(x: n.x, y: n.y - h, width: width, height: h)
    }

    /// The top left of a saved note, kept while its strip is on one of `screens`, else in the first screen's top right.
    static func onScreen(_ topLeft: CGPoint, screens: [CGRect]) -> CGPoint {
        let strip = CGRect(x: topLeft.x, y: topLeft.y - foldedHeight, width: width, height: foldedHeight)
        if screens.contains(where: { $0.intersection(strip).width >= 40 && $0.intersection(strip).height >= foldedHeight / 2 }) { return topLeft }
        guard let area = screens.first else { return topLeft }
        return newSpot(count: 0, in: area)
    }

    /// A new note's top left: the upper right of `area`, each one already out 24 pt further down and left (8 then over).
    static func newSpot(count: Int, in area: CGRect) -> CGPoint {
        let step = CGFloat(count % 8) * 24
        return CGPoint(x: max(area.minX, area.maxX - width - 40 - step), y: min(area.maxY, area.maxY - 40 - step))
    }

    /// The bottom left of the friend's drawing (`size`) while it types: on the note's bottom line, right beside it, or
    /// on the left when the right side of `bounds` has no room; kept inside `bounds`.
    static func typingSpot(note: CGRect, size: CGSize, in bounds: CGRect) -> CGPoint {
        var x = note.maxX + typingGap
        if x + size.width > bounds.maxX { x = note.minX - typingGap - size.width }
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        let y = min(max(note.minY, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}

/// The notes, saved half a second after the last change and when the app quits.
final class StickyStore: ObservableObject {
    static let shared = StickyStore(url: StickyFile.defaultURL)

    @Published var notes: [StickyNote]
    /// nil: nothing is read or written (QA).
    private let url: URL?
    private var bag: Set<AnyCancellable> = []

    init(url: URL?) {
        self.url = url
        notes = url.flatMap { try? Data(contentsOf: $0) }.map(StickyFile.decode) ?? []
        $notes.dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
    }

    var canAdd: Bool { notes.count < StickyFile.maxNotes }

    /// A new empty note in `area`'s upper right; nil when there are `maxNotes` already.
    @discardableResult
    func add(in area: CGRect) -> UUID? {
        guard canAdd else { return nil }
        let p = StickyMath.newSpot(count: notes.count, in: area)
        let n = StickyNote(color: StickyColor.allCases[notes.count % StickyColor.allCases.count], x: p.x, y: p.y)
        notes.append(n)
        return n.id
    }

    func update(_ id: UUID, _ change: (inout StickyNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var n = notes[i]
        change(&n)
        if n.text.count > StickyFile.maxText { n.text = String(n.text.prefix(StickyFile.maxText)) }
        if n != notes[i] { notes[i] = n }
    }

    func remove(_ id: UUID) { notes.removeAll { $0.id == id } }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? StickyFile.encode(notes).write(to: url, options: .atomic)
    }
}

/// "포스트잇": notes stuck on the desktop, at the 러그's level behind every window. Drag the strip to move one, ▾ folds
/// it to the strip, the dots change its colour, the bin takes it off (asking first when something is written). While
/// you type in one, the 커서 친구 comes over beside it and types along, a frame a key, and goes back once you stop.
/// The panels stay out of screen shares and recordings: what is written is the owner's.
final class StickyBoard {
    static let shared = StickyBoard()

    private var panels: [UUID: StickyPanel] = [:]
    private var bag: Set<AnyCancellable> = []
    private var started = false
    private var store: StickyStore { .shared }
    private var screens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    func start() {
        guard !started else { return }
        started = true
        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sync($0) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.bringBack() }
            .store(in: &bag)
        bringBack()
    }

    /// 포스트잇 붙이기 (FriendMenu, 설정): a new note on the menu bar's screen, ready to type in.
    func addNote() {
        guard let area = NSScreen.screens.first?.visibleFrame, let id = store.add(in: area) else { return }
        sync(store.notes)
        NSApp.activate(ignoringOtherApps: true)
        panels[id]?.makeKeyAndOrderFront(nil)
    }

    /// Notes left on a screen that is gone come back onto one.
    private func bringBack() {
        for n in store.notes {
            let p = StickyMath.onScreen(CGPoint(x: n.x, y: n.y), screens: screens)
            if p != CGPoint(x: n.x, y: n.y) { store.update(n.id) { $0.x = p.x; $0.y = p.y } }
        }
    }

    private func sync(_ notes: [StickyNote]) {
        let ids = Set(notes.map(\.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }
        for n in notes {
            let p = panels[n.id] ?? make(n)
            let f = StickyMath.frame(n)
            if p.frame != f { p.setFrame(f, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
    }

    private func make(_ n: StickyNote) -> StickyPanel {
        let p = StickyPanel(contentRect: StickyMath.frame(n), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)   // the 러그's and the toys'
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        p.sharingType = .none   // the owner's words stay out of screen shares and recordings
        let id = n.id
        p.contentView = NSHostingView(rootView: StickyNoteView(id: id, store: store, typed: { [weak self] in self?.typed(id) },
                                                               remove: { [weak self] in self?.remove(id) }))
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: p)
            .sink { [weak self, weak p] _ in
                guard let p, let self else { return }
                self.store.update(id) { $0.x = p.frame.minX; $0.y = p.frame.maxY }
            }
            .store(in: &bag)
        panels[id] = p
        return p
    }

    /// A key typed into note `id`: the 커서 친구 types along beside it.
    private func typed(_ id: UUID) {
        guard let f = panels[id]?.frame else { return }
        CursorBuddy.shared.typeAlong(by: f)
    }

    /// The bin: an empty note goes at once, a written one only after 지우기.
    private func remove(_ id: UUID) {
        guard let n = store.notes.first(where: { $0.id == id }) else { return }
        if !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let a = NSAlert()
            a.messageText = L("이 메모를 지울까요?")
            a.informativeText = L("지우면 되돌릴 수 없어요.")
            a.addButton(withTitle: L("지우기"))
            a.addButton(withTitle: L("취소"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        store.remove(id)
    }
}

/// Borderless, yet it takes the keyboard: the note is typed in.
private final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One note: the strip (▾ fold, colour dots or the first line when folded, the bin) over the paper you type on.
struct StickyNoteView: View {
    let id: UUID
    @ObservedObject var store: StickyStore
    var typed: () -> Void = {}
    var remove: () -> Void = {}

    private var note: StickyNote? { store.notes.first { $0.id == id } }

    var body: some View {
        if let n = note {
            VStack(spacing: 0) {
                strip(n)
                if !n.folded {
                    TextEditor(text: Binding(get: { note?.text ?? "" }, set: { t in
                        store.update(id) { $0.text = t }
                        typed()
                    }))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .environment(\.colorScheme, .light)   // dark text on paper in either appearance
                }
            }
            .background(n.color.paper)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func strip(_ n: StickyNote) -> some View {
        HStack(spacing: 6) {
            Button { store.update(id) { $0.folded.toggle() } } label: {
                Image(systemName: n.folded ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(n.folded ? L("펼치기") : L("접기"))
            .accessibilityLabel(n.folded ? L("펼치기") : L("접기"))
            if n.folded {
                Text(verbatim: Self.title(n.text)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .allowsHitTesting(false)
            } else {
                ForEach(StickyColor.allCases, id: \.self) { c in
                    Button { store.update(id) { $0.color = c } } label: {
                        Circle().fill(c.strip).frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.black.opacity(c == n.color ? 0.55 : 0.15), lineWidth: c == n.color ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                    .accessibilityLabel(c.label)
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("메모 지우기"))
            .accessibilityLabel(L("메모 지우기"))
        }
        .foregroundStyle(Color.black.opacity(0.6))
        .padding(.horizontal, 7)
        .frame(height: StickyMath.foldedHeight)
        .background(StripDrag().background(n.color.strip))
    }

    /// A folded note's title: its first line with something written, or 빈 메모.
    static func title(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? L("빈 메모")
    }
}

/// The strip moves the note: a press there drags the borderless window (the move is saved on didMove).
private struct StripDrag: NSViewRepresentable {
    final class Grip: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ nsView: Grip, context: Context) {}
}

/// QA renders (--render-sticky): the five colours, a folded one, the settings card and the friend typing beside a note.
/// A store of its own that never reads or writes the owner's file; nothing shows on screen.
enum StickyQA {
    static func render(to dir: URL) throws {
        let store = StickyStore(url: nil)
        let words = ["오늘 할 일\n- 회의 자료 정리\n- 3시 디자인 리뷰", "점심 메뉴 고민 중…", "", "택배 받기 📦", "퇴근 전에 백업!"]
        for (i, c) in StickyColor.allCases.enumerated() {
            store.notes.append(StickyNote(text: words[i], color: c, x: 0, y: 0))
        }
        store.notes.append(StickyNote(text: "접힌 메모의 첫 줄\n둘째 줄", color: .mint, x: 0, y: 0, folded: true))
        let notes = HStack(alignment: .top, spacing: 12) {
            ForEach(store.notes) { n in
                StickyNoteView(id: n.id, store: store)
                    .frame(width: StickyMath.width, height: n.folded ? StickyMath.foldedHeight : StickyMath.height)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            }
        }
        .padding(16)
        for (a, s) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try DashboardSnapshot.snapshot(notes, appearance: a, to: dir.appendingPathComponent("sticky-notes-\(s).png"))
            try DashboardSnapshot.snapshot(DesktopSettingsView(stickies: store, stickyOnly: true).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("sticky-settings-\(s).png"))
        }
        // The 커서 친구 at its typing spot by a note, the busy pose's frames side by side as the keys go.
        let cache = DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: MotionStore.shared.buddySize.pixelSize)
        let frames = (cache.frames(forExtra: .special)?.isEmpty == false ? cache.frames(forExtra: .special) : nil) ?? cache.frames(for: .run)
        let first = store.notes[0]
        let note = CGRect(x: 0, y: 0, width: StickyMath.width, height: StickyMath.height)
        let spot = StickyMath.typingSpot(note: note, size: cache.imageSize, in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let scene = HStack(alignment: .bottom, spacing: 24) {
            ForEach(Array(frames.prefix(3).enumerated()), id: \.offset) { _, img in
                ZStack(alignment: .bottomLeading) {
                    StickyNoteView(id: first.id, store: store).frame(width: StickyMath.width, height: StickyMath.height)
                    Image(nsImage: img).interpolation(cache.smooth ? .high : .none)
                        .frame(width: cache.imageSize.width, height: cache.imageSize.height)
                        .offset(x: spot.x)
                }
                .frame(width: spot.x + cache.imageSize.width, alignment: .bottomLeading)
            }
        }
        .padding(20)
        .background(Color(red: 0.80, green: 0.86, blue: 0.93))
        try DashboardSnapshot.snapshot(scene, appearance: .aqua, to: dir.appendingPathComponent("sticky-typing.png"))
    }
}
