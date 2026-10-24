import AppKit
import Carbon.HIToolbox
import SwiftUI

// 단축키: system-wide key combos through Carbon's RegisterEventHotKey (no 손쉬운 사용 permission: the system hands
// us only our own combos, never other keys). Off at first; while off nothing is registered and no handler is installed.

/// What a 단축키 does. Raw values are saved; never rename one.
enum HotkeyAction: String, CaseIterable, Codable {
    case friends, quiet, talk, recent, top, bottom, left, right

    var title: String {
        switch self {
        case .friends: return L("데스크톱 친구 숨기기/보이기")
        case .quiet: return L("쉿 모드")
        case .talk: return L("한마디·메시지 쓰기")
        case .recent: return L("대화 모아보기")
        case .top: return L("친구 상주 위로")
        case .bottom: return L("친구 상주 아래로")
        case .left: return L("친구 상주 왼쪽으로")
        case .right: return L("친구 상주 오른쪽으로")
        }
    }
}

/// A key and its modifiers, as Carbon takes them: `key` a virtual key code (kVK_*), `mods` Carbon's modifier mask.
struct HotkeyCombo: Codable, Equatable, Hashable {
    var key: UInt32
    var mods: UInt32
}

/// Which combos are allowed, the defaults, labels and the saved map. Pure, tested (HotkeyTests).
enum HotkeyRules {
    static let control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey), command = UInt32(cmdKey)
    /// The defaults' modifiers: ⌃⌥⇧. macOS keeps ⌃+arrows (Spaces) and ⌘ combos for itself, Rectangle and Magnet use
    /// ⌃⌥ and ⌃⌥⌘, SIDEY uses ⌃⌥⌘, and ⌥ or ⌥⇧ with a letter types characters (é, ß, ). Hardly anything takes ⌃⌥⇧.
    static let ours = control | option | shift

    static let defaults: [HotkeyAction: HotkeyCombo] = [
        .friends: HotkeyCombo(key: UInt32(kVK_ANSI_D), mods: ours),
        .quiet: HotkeyCombo(key: UInt32(kVK_ANSI_Q), mods: ours),
        .talk: HotkeyCombo(key: UInt32(kVK_ANSI_T), mods: ours),
        .recent: HotkeyCombo(key: UInt32(kVK_ANSI_L), mods: ours),
        .top: HotkeyCombo(key: UInt32(kVK_UpArrow), mods: ours),
        .bottom: HotkeyCombo(key: UInt32(kVK_DownArrow), mods: ours),
        .left: HotkeyCombo(key: UInt32(kVK_LeftArrow), mods: ours),
        .right: HotkeyCombo(key: UInt32(kVK_RightArrow), mods: ours),
    ]

    /// Letters, digits and the arrows only (a layout-proof set: the ANSI key codes, named by their US keycap).
    static let keyNames: [UInt32: String] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
            (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"),
            (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
        ]
        return Dictionary(uniqueKeysWithValues: letters.map { (UInt32($0.0), $0.1) })
    }()

    static func mods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.control) ? control : 0) | (flags.contains(.option) ? option : 0)
            | (flags.contains(.shift) ? shift : 0) | (flags.contains(.command) ? command : 0)
    }

    enum Check: Equatable {
        case ok
        /// No ⌃, ⌥ or ⌘ (⇧ alone just types a capital).
        case needsModifier
        case unsupportedKey
        /// Already another action's.
        case taken(HotkeyAction)
    }

    static func check(_ c: HotkeyCombo, for action: HotkeyAction, in map: [HotkeyAction: HotkeyCombo]) -> Check {
        guard keyNames[c.key] != nil else { return .unsupportedKey }
        guard c.mods & (control | option | command) != 0, c.mods & ~(control | option | shift | command) == 0 else { return .needsModifier }
        if let other = map.first(where: { $0.key != action && $0.value == c })?.key { return .taken(other) }
        return .ok
    }

    /// ⌃⌥⇧⌘ in Apple's order, then the key: "⌃⌥⇧D".
    static func label(_ c: HotkeyCombo) -> String {
        (c.mods & control != 0 ? "⌃" : "") + (c.mods & option != 0 ? "⌥" : "") + (c.mods & shift != 0 ? "⇧" : "")
            + (c.mods & command != 0 ? "⌘" : "") + (keyNames[c.key] ?? "?")
    }

    /// The saved map over the defaults. A saved entry that is not allowed is dropped; a default that a saved entry
    /// took is left unset (no key) rather than doubled.
    static func decode(_ data: Data?) -> [HotkeyAction: HotkeyCombo] {
        let raw = data.flatMap { try? JSONDecoder().decode([String: HotkeyCombo].self, from: $0) } ?? [:]
        var saved: [HotkeyAction: HotkeyCombo] = [:]
        for (k, c) in raw.sorted(by: { $0.key < $1.key }) {
            guard let a = HotkeyAction(rawValue: k), check(c, for: a, in: saved) == .ok else { continue }
            saved[a] = c
        }
        var map = saved
        for (a, c) in defaults where saved[a] == nil && !saved.values.contains(c) { map[a] = c }
        return map
    }

    static func encode(_ map: [HotkeyAction: HotkeyCombo]) -> Data? {
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) }))
    }
}

/// The registered combos and what they run. Call `start()` once at launch.
final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()
    static let onKey = "hotkeys.on", mapKey = "hotkeys.map"
    private static let signature: OSType = 0x4348_4D4B   // 'CHMK'

    var defaults: UserDefaults = AppDefaults.store
    @Published private(set) var on = false
    @Published private(set) var map: [HotkeyAction: HotkeyCombo] = HotkeyRules.defaults
    /// Combos the system would not take (most likely another app has them).
    @Published private(set) var failed: Set<HotkeyAction> = []
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// While a combo is being recorded: nothing registered, so the keys reach the recorder.
    private var paused = false

    func start() {
        on = defaults.bool(forKey: Self.onKey)
        map = HotkeyRules.decode(defaults.data(forKey: Self.mapKey))
        apply()
    }

    func setOn(_ value: Bool) {
        defaults.set(value, forKey: Self.onKey)
        on = value
        apply()
    }

    /// A new combo for `action`. Nil when it took; else why not, and the old one stays.
    func set(_ c: HotkeyCombo, for action: HotkeyAction) -> String? {
        switch HotkeyRules.check(c, for: action, in: map) {
        case .needsModifier: return L("⌃, ⌥, ⌘ 중 하나 이상과 같이 눌러 주세요")
        case .unsupportedKey: return L("영문, 숫자, 방향키만 쓸 수 있어요")
        case .taken(let other): return L("이미 '\(other.title)'에 쓰고 있어요")
        case .ok: break
        }
        if registering {
            unregister(action)
            guard register(action, c) else {
                if let old = map[action], register(action, old) { failed.remove(action) }
                return L("다른 앱이 이미 쓰는 조합이에요. 원래 단축키를 그대로 둘게요")
            }
            failed.remove(action)
        }
        map[action] = c
        save()
        return nil
    }

    func resetToDefaults() {
        map = HotkeyRules.defaults
        defaults.removeObject(forKey: Self.mapKey)
        apply()
    }

    /// The recorder is listening (true) or done (false).
    func pause(_ value: Bool) {
        paused = value
        apply()
    }

    #if !MAS
    /// QA renders (--render-hotkeys) only.
    func qaShow(on: Bool, failed: Set<HotkeyAction>) {
        self.on = on
        self.failed = failed
    }
    #endif

    private var registering: Bool { on && !paused }

    private func save() { defaults.set(HotkeyRules.encode(map), forKey: Self.mapKey) }

    private func apply() {
        HotkeyAction.allCases.forEach(unregister)
        guard registering else {
            if let h = handler { RemoveEventHandler(h); handler = nil }
            if !on { failed = [] }
            return
        }
        installHandler()
        var bad = Set<HotkeyAction>()
        for (a, c) in map where !register(a, c) { bad.insert(a) }
        failed = bad
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature,
                  let action = HotkeyAction.allCases.indices.contains(Int(id.id)) ? HotkeyAction.allCases[Int(id.id)] : nil
            else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotkeyRun.run(action) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func register(_ a: HotkeyAction, _ c: HotkeyCombo) -> Bool {
        guard let index = HotkeyAction.allCases.firstIndex(of: a) else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
        guard RegisterEventHotKey(c.key, c.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        refs[a] = ref
        return true
    }

    private func unregister(_ a: HotkeyAction) {
        if let r = refs.removeValue(forKey: a) { UnregisterEventHotKey(r) }
    }
}

/// What each action does. The feedback line is `asked`, so 쉿 모드 itself does not hide it.
enum HotkeyRun {
    static func run(_ a: HotkeyAction) {
        switch a {
        case .friends:
            say(DesktopHide.toggle() ? L("데스크톱 친구들을 숨겼어요") : L("데스크톱 친구들이 돌아왔어요"))
        case .quiet:
            FriendVisit.quietMode.toggle()
            say(FriendVisit.quietMode ? L("쉿 모드를 켰어요. 읽지 않은 메시지는 메뉴에 점으로 남아요") : L("쉿 모드를 껐어요"))
        case .talk:
            talk()
        case .recent:
            RecentLog.open()
        case .top: place(.top, L("친구 상주를 위로 옮겼어요"))
        case .bottom: place(.bottom, L("친구 상주를 아래로 옮겼어요"))
        case .left: place(.left, L("친구 상주를 왼쪽으로 옮겼어요"))
        case .right: place(.right, L("친구 상주를 오른쪽으로 옮겼어요"))
        }
    }

    /// The 원격 모임's 한마디 while in a room, else the chat of the first online 근처 친구.
    private static func talk() {
        let meet = RemoteMeet.shared
        if meet.isOn, meet.code != nil { meet.askLine(); return }
        let bus = SocialBus.shared
        if let f = bus.friends.first(where: { bus.online.contains($0.id) }) { FriendWindow.open(f.id); return }
        say(L("원격 모임에 들어가 있거나 근처 친구가 접속해 있을 때 쓸 수 있어요"))
    }

    private static func place(_ edge: RoomEdge, _ line: String) {
        FriendRoom.shared.edge = edge
        say(line)
    }

    private static func say(_ text: String) {
        SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true, seconds: 3,
                                      anchor: DesktopFriends.speaker, asked: true)
    }
}

/// 데스크톱 친구 숨기기/보이기: hiding switches off the ones that are out and remembers them; showing switches those back.
enum DesktopHide {
    static let key = "hotkeys.hidden"

    /// Pure, tested: from who is on and what was hidden, which to switch off, which on, and what to remember (nil: nothing hidden).
    static func next(on: [String], hidden: [String]?) -> (off: [String], on: [String], hidden: [String]?) {
        if let h = hidden { return ([], h, nil) }
        return on.isEmpty ? ([], [], nil) : (on, [], on)
    }

    /// Each 데스크톱 친구 switch plus 친구 상주.
    private static var toggles: [DesktopToggle] {
        DesktopFriends.toggles + [DesktopToggle(title: "room", isOn: { FriendRoom.shared.on },
                                                set: { SocialBus.shared.defaults.set($0, forKey: FriendRoom.key) })]
    }

    /// True when it hid them.
    @discardableResult
    static func toggle(_ d: UserDefaults = AppDefaults.store) -> Bool {
        let all = toggles
        // ponytail: kept by title, so a language switch between 숨기기 and 보이기 brings back nothing; the switches still work.
        let n = next(on: all.filter { $0.isOn() }.map(\.title), hidden: d.stringArray(forKey: key))
        all.filter { n.off.contains($0.title) }.forEach { $0.set(false) }
        all.filter { n.on.contains($0.title) }.forEach { $0.set(true) }
        d.set(n.hidden, forKey: key)
        return n.hidden != nil
    }
}

/// 설정 > 데스크톱 친구 > 단축키: the switch, one row per action with its combo and 바꾸기 (press the new keys), 기본값으로.
struct HotkeysSection: View {
    @ObservedObject var keys: Hotkeys = .shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var recording: HotkeyAction?
    @State private var note: String?
    @State private var monitor: Any?
    /// QA renders only: the row that shows as recording.
    var previewRecording: HotkeyAction?

    private var k: CGFloat { settings.settingsTextLarge ? 1.15 : 1 }
    private var accent: Color { settings.palette.accent ?? .accentColor }

    var body: some View {
        Panel(tint: settings.palette.accent.map { keys.on ? $0 : $0.opacity(0.5) }) {
            HStack(spacing: 8) {
                Text(verbatim: "⌨️").font(.system(size: 14 * k))
                    .frame(width: 26 * k, height: 26 * k)
                    .background(Circle().fill(accent.opacity(0.25)))
                    .accessibilityHidden(true)
                Text(L("단축키")).font(.system(size: 13 * k, weight: .bold, design: .rounded))
                Spacer()
                Toggle(L("단축키"), isOn: Binding(get: { keys.on }, set: { stop(); keys.setOn($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
            }
            Text(L("어떤 앱을 쓰고 있어도 키 조합 한 번으로 친구들을 숨기거나 조용히 시켜요"))
                .font(.system(size: 12 * k)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            if keys.on {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(HotkeyAction.allCases, id: \.self, content: row)
                }
                if let note { Text(verbatim: note).font(.system(size: 11 * k)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button(L("단축키 처음대로")) { stop(); note = nil; keys.resetToDefaults() }.controlSize(.small)
                    Spacer()
                }
                Text(L("기본은 ⌃⌥⇧(control·option·shift)와 글자예요. 다른 앱이 이미 쓰는 조합이면 빨간 표시가 나고, 바꿀 때 막히면 원래 것을 그대로 둬요. 손쉬운 사용 권한은 필요 없어요."))
                    .font(.system(size: 11 * k)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stop)
    }

    private func row(_ a: HotkeyAction) -> some View {
        let listening = (recording ?? previewRecording) == a, bad = keys.failed.contains(a)
        return HStack(spacing: 8) {
            Text(verbatim: a.title).font(.system(size: 12 * k)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if bad { Text(L("다른 앱이 사용 중")).font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(.red) }
            Button(action: { listening ? stop() : record(a) }) {
                Text(verbatim: listening ? L("키를 누르세요 (esc 취소)") : keys.map[a].map(HotkeyRules.label) ?? L("없음"))
                    .font(listening ? .system(size: 11 * k) : .system(size: 12 * k, weight: .medium).monospaced())
                    .frame(minWidth: 70 * k)
            }
            .controlSize(.small)
            .tint(listening ? accent : nil)
            .help(L("눌러서 새 조합을 녹화해요"))
            .accessibilityLabel(Text(verbatim: a.title))
        }
    }

    /// Listens to this window's keys only (a local monitor) until one combo or esc; our own combos are off meanwhile.
    private func record(_ a: HotkeyAction) {
        stop()
        note = nil
        recording = a
        keys.pause(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let c = HotkeyCombo(key: UInt32(e.keyCode), mods: HotkeyRules.mods(e.modifierFlags))
            stop()
            note = keys.set(c, for: a)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording != nil { recording = nil; keys.pause(false) }
    }
}

#if !MAS
/// --render-hotkeys <폴더>: the 단축키 card off, on (one combo refused, one row recording) and 대화 모아보기, light and dark.
enum HotkeysQA {
    static func render(to dir: URL) throws {
        let keys = Hotkeys()
        let talk = TalkLog()
        let t0 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        talk.qaShow([
            TalkEntry(date: t0, thread: TalkEntry.meet, name: "보리", text: L("모임에 들어왔어요"), mine: false),
            TalkEntry(date: t0.addingTimeInterval(60), thread: TalkEntry.meet, name: "보리", text: "점심 뭐 먹어요?", mine: false),
            TalkEntry(date: t0.addingTimeInterval(90), thread: TalkEntry.meet, name: "", text: "국수 어때요", mine: true, msgID: UUID().uuidString, state: .sent),
            TalkEntry(date: t0.addingTimeInterval(300), thread: "f1", name: "", text: "오늘 회의 몇 시죠?", mine: false),
            TalkEntry(date: t0.addingTimeInterval(320), thread: "f1", name: "", text: "3시요", mine: true),
            TalkEntry(date: t0.addingTimeInterval(400), thread: "f1", name: "", text: L("회의 중이라 무전을 듣지 않았어요"), mine: false, note: true),
        ])
        let empty = TalkLog()
        empty.qaShow([])
        let names = ["f1": "콩이"]
        for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            keys.qaShow(on: false, failed: [])
            try DashboardSnapshot.snapshot(HotkeysSection(keys: keys).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("hotkeys-off-\(suffix).png"))
            keys.qaShow(on: true, failed: [.quiet])
            try DashboardSnapshot.snapshot(HotkeysSection(keys: keys, previewRecording: .recent).frame(width: 380).padding(), appearance: a,
                                           to: dir.appendingPathComponent("hotkeys-on-\(suffix).png"))
            try DashboardSnapshot.snapshot(RecentLogView(log: talk, meet: RemoteMeet(), name: { names[$0] ?? "?" }).frame(width: 340, height: 360),
                                           appearance: a, to: dir.appendingPathComponent("recent-\(suffix).png"))
            try DashboardSnapshot.snapshot(RecentLogView(log: empty, meet: RemoteMeet()).frame(width: 340, height: 160),
                                           appearance: a, to: dir.appendingPathComponent("recent-empty-\(suffix).png"))
        }
    }
}
#endif
