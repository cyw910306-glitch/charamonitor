import SwiftUI

/// Saved 상황별 모션 choices and the 커서 친구 toggle.
final class MotionStore: ObservableObject {
    static let shared = MotionStore()
    static let buddyKey = "cursorBuddy"

    private let defaults: UserDefaults
    @Published var prefs: MotionPrefs { didSet { prefs.save(defaults) } }
    @Published var cursorBuddy: Bool { didSet { defaults.set(cursorBuddy, forKey: Self.buddyKey) } }
    @Published var buddySize: BuddySize { didSet { defaults.set(buddySize.rawValue, forKey: "cursorBuddySize") } }
    @Published var buddyBoost: BuddyBoost { didSet { defaults.set(buddyBoost.rawValue, forKey: "cursorBuddyBoost") } }
    /// 혼자 놀기: idle play, sitting on the front window, the butterfly and clinging on. On by default.
    @Published var buddyPlay: Bool { didSet { defaults.set(buddyPlay, forKey: "cursorBuddyPlay") } }
    /// 누르면 소리 (FriendCry): off by default, and how loud (0...1).
    @Published var buddyCry: Bool { didSet { defaults.set(buddyCry, forKey: "cursorBuddyCry") } }
    @Published var buddyCryVolume: Double { didSet { defaults.set(buddyCryVolume, forKey: "cursorBuddyCryVolume") } }
    /// 퀵물어보기: the bubble's colours, type size, motion, chime and the friend's face in it.
    @Published var quickAskTheme: QuickAskTheme { didSet { defaults.set(quickAskTheme.rawValue, forKey: "quickAskTheme") } }
    @Published var quickAskTextSize: QuickAskTextSize { didSet { defaults.set(quickAskTextSize.rawValue, forKey: "quickAskTextSize") } }
    @Published var quickAskMotion: QuickAskMotion { didSet { defaults.set(quickAskMotion.rawValue, forKey: "quickAskMotion") } }
    @Published var quickAskSound: Bool { didSet { defaults.set(quickAskSound, forKey: "quickAskSound") } }
    @Published var quickAskShowAvatar: Bool { didSet { defaults.set(quickAskShowAvatar, forKey: "quickAskShowAvatar") } }
    /// 맥과 같이 놀기 (MacReactions): 다운로드 배달, 휴지통 and 바쁜 맥, each off by default.
    @Published var macDownloads: Bool { didSet { defaults.set(macDownloads, forKey: "macDownloads") } }
    @Published var macTrash: Bool { didSet { defaults.set(macTrash, forKey: "macTrash") } }
    @Published var macBusy: Bool { didSet { defaults.set(macBusy, forKey: "macBusy") } }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = MotionPrefs.load(defaults)
        cursorBuddy = defaults.bool(forKey: Self.buddyKey)
        buddySize = defaults.string(forKey: "cursorBuddySize").flatMap(BuddySize.init) ?? .medium
        buddyBoost = defaults.string(forKey: "cursorBuddyBoost").flatMap(BuddyBoost.init) ?? .normal
        buddyPlay = defaults.object(forKey: "cursorBuddyPlay") as? Bool ?? true
        buddyCry = defaults.bool(forKey: "cursorBuddyCry")
        buddyCryVolume = min(1, max(0, defaults.object(forKey: "cursorBuddyCryVolume") as? Double ?? 0.5))
        quickAskTheme = defaults.string(forKey: "quickAskTheme").flatMap(QuickAskTheme.init) ?? .peach
        quickAskTextSize = defaults.string(forKey: "quickAskTextSize").flatMap(QuickAskTextSize.init) ?? .regular
        quickAskMotion = defaults.string(forKey: "quickAskMotion").flatMap(QuickAskMotion.init) ?? .bouncy
        quickAskSound = defaults.bool(forKey: "quickAskSound")
        quickAskShowAvatar = defaults.object(forKey: "quickAskShowAvatar") as? Bool ?? true
        macDownloads = defaults.bool(forKey: "macDownloads")
        macTrash = defaults.bool(forKey: "macTrash")
        macBusy = defaults.bool(forKey: "macBusy")
    }
}

/// 커서 친구 크기: whole steps of the dot size, so pixel art stays crisp on Retina (51x30 to 136x80 pt for a dog).
enum BuddySize: String, CaseIterable {
    case small, medium, large, huge

    var pixelSize: CGFloat {
        switch self {
        case .small: return 1.5
        case .medium: return 2
        case .large: return 3
        case .huge: return 4
        }
    }

    var label: String {
        switch self {
        case .small: return L("작게")
        case .medium: return L("보통")
        case .large: return L("크게")
        case .huge: return L("아주 크게")
        }
    }
}

/// How big the 커서 친구 grows when the mouse moves fast (BuddyMath.boost).
enum BuddyBoost: String, CaseIterable {
    case off, gentle, normal, big

    var maxScale: CGFloat {
        switch self {
        case .off: return 1
        case .gentle: return 1.3
        case .normal: return 1.6
        case .big: return 2
        }
    }

    var label: String {
        switch self {
        case .off: return L("끔")
        case .gentle: return L("살짝")
        case .normal: return L("보통")
        case .big: return L("크게")
        }
    }
}

/// The "상황별 모션" panel (the 커서 친구 switch is in DesktopSettingsView). `available` = extra motions of the current character.
struct MotionSettingsView: View {
    @ObservedObject var store: MotionStore = .shared
    let available: Set<ExtraMotion>

    var body: some View {
        VStack(spacing: 8) {
            Panel {
                Text("상황별 모션").font(.system(size: 12, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    ForEach(Situation.allCases, id: \.self) { s in
                        GridRow {
                            Text(s.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            choicePicker(s)
                            frequencyPicker(s)
                        }
                    }
                }
                Text("캐릭터에 없는 모션은 건너뛰고 평소 모습을 보여 줘요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choicePicker(_ s: Situation) -> some View {
        Picker(s.label, selection: entry(s).choice) {
            Text("기본").tag(MotionChoice.standard)
            Text("꺼짐").tag(MotionChoice.off)
            // Every motion stays listed, so a choice saved for another character still shows as selected.
            ForEach(ExtraMotion.allCases, id: \.self) { m in
                Text(available.contains(m) ? Self.label(m) : L("\(Self.label(m)) (이 캐릭터엔 없음)")).tag(MotionChoice.motion(m))
            }
        }
        .labelsHidden().controlSize(.small).frame(width: 130)
    }

    private func frequencyPicker(_ s: Situation) -> some View {
        Picker("\(s.label) 빈도", selection: entry(s).frequency) {
            ForEach(MotionFrequency.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        .disabled(store.prefs[s].choice == .off)
    }

    private func entry(_ s: Situation) -> Binding<MotionPrefs.Entry> {
        Binding(get: { store.prefs[s] }, set: { store.prefs[s] = $0 })
    }

    static func label(_ m: ExtraMotion) -> String {
        switch m {
        case .hungry: return L("밥 찾기")
        case .eat: return L("냠냠 먹기")
        case .special: return L("특수 기술")
        }
    }
}
