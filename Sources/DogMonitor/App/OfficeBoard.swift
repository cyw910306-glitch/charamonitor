import AppKit
import Combine
import SwiftUI

/// 가상 오피스: when the status sets itself. Pure, tested (OfficeTests).
enum OfficeRules {
    /// No keyboard or mouse this long: 자리 비움.
    static let idleAway: TimeInterval = 300

    /// What the 30 s check sets, or nil to keep `current`: a picked 자리 비움, 식사, 화장실, 회의, 집중 or 퇴근 stays until
    /// the owner changes it; a picked 근무 중 and anything the check set itself follow the Mac. A call in front wins over
    /// the 집중 timer, and both over idle (nobody types while listening in a meeting or reading in a focus run).
    static func auto(current: OfficeStatus, autoSet: Bool, idle: TimeInterval, focusing: Bool, inMeeting: Bool) -> OfficeStatus? {
        guard autoSet || current == .working else { return nil }
        if inMeeting { return .meeting }
        if focusing { return .focus }
        return idle >= idleAway ? .away : .working
    }

    /// Sitting at the desk; the others leave a 공석 with their sign on it.
    static func atDesk(_ s: OfficeStatus) -> Bool { s == .working || s == .meeting || s == .focus }
}

/// 모임 정원: 2, 4 or 8 seats for me and my friends; the empty ones wait for an invite, and filling up is a party.
/// Pure, tested (OfficeTests).
struct Gathering: Equatable {
    static let sizes = [2, 4, 8]
    static let key = "office.capacity"

    /// A saved size, 4 when it is none of the three.
    static func capacity(_ saved: Int) -> Int { sizes.contains(saved) ? saved : 4 }
    /// 초대 대기 seats after me and every paired friend.
    static func waiting(capacity: Int, friends: Int) -> Int { max(0, capacity - 1 - friends) }
    /// Me and the online friends fill every seat.
    static func isFull(capacity: Int, online: Int) -> Bool { 1 + online >= capacity }

    private(set) var full = false

    /// True once, as the group fills up; it can fill up again after someone leaves.
    mutating func update(capacity: Int, online: Int) -> Bool {
        let now = Self.isFull(capacity: capacity, online: online)
        defer { full = now }
        return now && !full
    }
}

/// 가상 오피스 (플러그인, `office.on`, off by default): my status for paired friends (SocialBus sends it), set from the
/// menu, my seat or the 30 s auto check, and a floating board of seats. Off: no timer, no panel, no menu items.
final class OfficeCenter: ObservableObject {
    static let shared = OfficeCenter()
    static let onKey = "office.on"

    @Published private(set) var on = false
    /// The 모임 just filled up: confetti on the board for a few seconds.
    @Published private(set) var celebrating = false
    private var gathering = Gathering()
    private var onlineSub: AnyCancellable?
    /// The status came from the check (or the launch default), not a pick.
    private(set) var autoSet = true
    private let defaults: UserDefaults
    private var timer: Timer?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    /// Seat sprites by look, rebuilt only when a look changes. ponytail: cleared past 16 looks; an LRU if offices grow.
    private var sprites: [(SpriteLook, DogSpriteCache)] = []

    init(defaults: UserDefaults = AppDefaults.store) { self.defaults = defaults }

    func start() {
        guard observers.isEmpty else { return }
        // Whoever flips `office.on` (the plugin card, a QA script) or opens the plugin writes defaults; no polling.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
            self?.checkFull()
        })
        onlineSub = SocialBus.shared.$online.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.checkFull() }
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        refresh()
    }

    /// The plugin is open and its switch on.
    var enabled: Bool { PluginGate.isOpen(.office) && defaults.bool(forKey: Self.onKey) }

    private func refresh() {
        let want = enabled
        guard want != on else { return }
        on = want
        timer?.invalidate(); timer = nil
        if want {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
            check()
        } else {
            close()
            sprites = []
            // Off: friends see 근무 중 again, not a 식사 picked hours ago.
            autoSet = true
            if SocialBus.shared.myStatus != .working { SocialBus.shared.myStatus = .working }
        }
    }

    /// The auto status (OfficeRules) from idle time, the 집중 timer and a call app in front.
    func check() {
        guard on else { return }
        let bus = SocialBus.shared
        guard let s = OfficeRules.auto(current: bus.myStatus, autoSet: autoSet, idle: PetSignals.idleSeconds(),
                                       focusing: FocusCenter.shared.running, inMeeting: MeetingMute.inMeeting()) else { return }
        autoSet = true
        if bus.myStatus != s { bus.myStatus = s }
    }

    var capacity: Int { Gathering.capacity(defaults.integer(forKey: Gathering.key)) }

    /// The party when the 모임 fills up: confetti on the board, the room's friends cheer, one line.
    private func checkFull() {
        guard on else { gathering = Gathering(); return }
        guard gathering.update(capacity: capacity, online: SocialBus.shared.online.count) else { return }
        celebrating = true
        FriendRoom.shared.play(.party)
        if !FriendVisit.quiet() {
            SpeechBubbleCenter.shared.say(text: L("모임 \(capacity)명이 꽉 찼어요!"), source: .system, aloud: false, repeats: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.celebrating = false }
    }

    /// QA renders: the board as it looks mid-party.
    func qaCelebrate(_ on: Bool) { celebrating = on }

    /// A pick from the menu or my seat.
    func set(_ s: OfficeStatus) {
        autoSet = false
        SocialBus.shared.myStatus = s
    }

    /// 데스크톱 친구 ▸ 내 상태 ▸ and 가상 오피스 열기 (empty while off).
    static func menuItems() -> [NSMenuItem] {
        let c = shared
        guard c.on else { return [] }
        return [.separator(), FriendMenu.submenu(L("내 상태"), c.statusItems()), FriendMenu.item(L("가상 오피스 열기")) { c.show() }]
    }

    func statusItems() -> [NSMenuItem] {
        let mine = SocialBus.shared.myStatus
        return OfficeStatus.allCases.map { s in FriendMenu.item("\(s.emoji) \(s.label)", on: s == mine) { [weak self] in self?.set(s) } }
    }

    /// My seat's click: the seven statuses under the mouse.
    func popStatusMenu() {
        let menu = NSMenu()
        statusItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func show() {
        guard on else { return }
        if panel == nil {
            let p = Self.floatingPanel(title: L("가상 오피스"), size: CGSize(width: 360, height: 260), resizable: true)
            p.contentMinSize = CGSize(width: 240, height: 180)
            if !p.setFrameUsingName("office.board") { p.center() }
            p.setFrameAutosaveName("office.board")
            // Closed: the seats leave the window, so their frame timers stop.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
                p.contentView = nil
            })
            panel = p
        }
        if panel?.contentView == nil { panel?.contentView = NSHostingView(rootView: OfficeBoardView(center: self)) }
        panel?.orderFrontRegardless()
    }

    private func close() { panel?.close() }

    /// A seat's frames at 2 points per art pixel.
    func sprite(_ look: SpriteLook) -> DogSpriteCache {
        if let hit = sprites.first(where: { $0.0 == look }) { return hit.1 }
        if sprites.count >= 16 { sprites = [] }
        let c = DogSpriteCache(look, pixelSize: 2)
        sprites.append((look, c))
        return c
    }

    /// AI 팀원: a border collie, so it never looks like the owner's own dog.
    static let aiLook = FriendLook(character: .dog, id: nil,
                                   profile: DogProfile.presets.first { $0.id == "border-collie" }?.profile, colors: nil, cat: nil, outfit: nil)

    /// A small floating utility panel that never takes the app's activation (가상 오피스, 화면 공유 켜기).
    static func floatingPanel(title: String, size: CGSize, resizable: Bool) -> NSPanel {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        p.title = title
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none   // friends' names and live status stay out of screen shares (원격 지원 too)
        return p
    }
}

/// The board: my seat, the AI 팀원, then every paired friend (offline ones greyed).
struct OfficeBoardView: View {
    @ObservedObject var center: OfficeCenter
    @ObservedObject private var bus = SocialBus.shared
    @AppStorage(Gathering.key, store: AppDefaults.store) private var saved = 4
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var byo = BYOSettings.shared
    @ObservedObject private var draws = GroupDraw.shared

    var body: some View {
        let cap = Gathering.capacity(saved)
        let online = bus.friends.filter { bus.online.contains($0.id) }.count
        // 그룹 뽑기 winners (items named after people) wear 👑 for a while; re-read whenever the board redraws.
        let crowns = draws.crowns()
        let crowned = { (name: String, shown: String) in crowns.contains(name) ? "👑 " + shown : shown }
        ScrollView {
            gatheringBar(cap, online: online)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 10) {
                Button { center.popStatusMenu() } label: {
                    SeatView(name: crowned(bus.nickname, L("나")), status: bus.myStatus, chip: nil, cache: center.sprite(SpriteLook(settings)), dim: false)
                }
                .buttonStyle(.plain)
                .help(L("눌러서 내 상태 바꾸기"))
                aiSeat
                ForEach(bus.friends) { f in
                    let online = bus.online.contains(f.id)
                    Button { bus.card(f.id).map(FriendCardPanel.show) } label: {
                        SeatView(name: crowned(f.nickname, f.nickname), status: online ? f.status : nil, chip: online ? nil : L("오프라인"),
                                 cache: center.sprite(SpriteLook(friend: f.look)), dim: !online)
                    }
                    .buttonStyle(.plain)
                    .help(L("눌러서 프로필 카드 보기"))
                }
                ForEach(0..<Gathering.waiting(capacity: cap, friends: bus.friends.count), id: \.self) { _ in
                    Button { NearbyWindow.open() } label: { WaitingSeatView() }
                        .buttonStyle(.plain)
                        .help(L("눌러서 친구 추가"))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            if bus.friends.isEmpty {
                Text("플러그인 > 근처 친구에서 친구를 맺으면 친구 자리가 생겨요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(minWidth: 240, minHeight: 180)
        .overlay { if center.celebrating { PartyView().allowsHitTesting(false) } }
    }

    /// 모임 정원 2·4·8 and how many are here now.
    private func gatheringBar(_ cap: Int, online: Int) -> some View {
        HStack(spacing: 8) {
            Text(L("모임 정원")).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            Picker(L("모임 정원"), selection: Binding(get: { cap }, set: { saved = $0 })) {
                ForEach(Gathering.sizes, id: \.self) { Text(L("\($0)명")).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            Spacer()
            Button { GroupDraw.shared.show() } label: { Text(verbatim: "🎲") }.buttonStyle(.borderless).help(L("그룹 뽑기"))
            Text(verbatim: "\(min(1 + online, cap))/\(cap)" + (Gathering.isFull(capacity: cap, online: online) ? " 🎉" : ""))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .fixedSize()   // English is wider: the label shrinks first, the count never wraps
                .accessibilityLabel(Text(L("지금 \(1 + online)명, 정원 \(cap)명")))
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }

    /// 근무 중 while an AI 엔진 is connected (비서 설정 > AI 엔진), else 연결 안 됨, which opens 설정.
    @ViewBuilder private var aiSeat: some View {
        let cache = center.sprite(SpriteLook(friend: OfficeCenter.aiLook))
        if BYOEngine.active(intent: nil, byo) != nil {
            SeatView(name: L("AI 팀원"), status: .working, chip: nil, cache: cache, dim: false)
        } else {
            // ponytail: opens 설정, not 비서 설정 > AI 엔진 itself; a page hook in StatusItemController if people get lost.
            Button { FriendMenu.openSettings?() } label: {
                SeatView(name: L("AI 팀원"), status: nil, chip: L("연결 안 됨"), cache: cache, dim: true)
            }
            .buttonStyle(.plain)
            .help(L("AI 비서에서 AI 엔진을 연결하면 일해요"))
        }
    }
}

/// One desk: the character behind it (or 공석 with the status sign), the name and a status chip.
struct SeatView: View {
    let name: String
    /// nil: no live status (offline, not connected); `chip` says why.
    let status: OfficeStatus?
    let chip: String?
    let cache: DogSpriteCache
    let dim: Bool

    private var present: Bool { status.map(OfficeRules.atDesk) ?? true }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                if present {
                    AnimatedDog(cache: cache, pose: pose, cpu: 0.2)
                        .frame(width: 68, height: 40)
                        .padding(.bottom, 12)
                } else {
                    VStack(spacing: 1) {
                        Text(status?.emoji ?? "").font(.system(size: 18))
                        Text("공석").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 16)
                }
                desk
            }
            .frame(width: 96, height: 60)
            Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(chip ?? status.map { "\($0.emoji) \($0.label)" } ?? "")
                .font(.system(size: 10))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .opacity(dim ? 0.45 : 1)
        .saturation(dim ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(name), \(chip ?? status?.label ?? "")"))
    }

    private var pose: DogPose {
        switch status {
        case .focus: return .fastWalk
        case .meeting: return .slowWalk
        default: return .walk
        }
    }

    /// A desk top with a little monitor, in front of the character's legs.
    private var desk: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.72, green: 0.55, blue: 0.40))
                .frame(width: 92, height: 14)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.25))
                .frame(width: 18, height: 12).offset(x: -6, y: -10)
        }
        .frame(width: 92, height: 14)
    }
}

/// An empty seat of the 모임: a dashed chair waiting for an invite (a click opens 친구 추가).
struct WaitingSeatView: View {
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .frame(width: 44, height: 38)
                    .overlay(Image(systemName: "person.badge.plus").font(.system(size: 15)).foregroundStyle(.secondary))
                    .padding(.bottom, 14)
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.72, green: 0.55, blue: 0.40).opacity(0.45))
                    .frame(width: 92, height: 14)
            }
            .frame(width: 96, height: 60)
            Text(L("빈자리")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(L("초대 대기"))
                .font(.system(size: 10))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.02)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("빈자리, 초대 대기")))
    }
}

/// The 모임 filled up: confetti over the board and one banner.
struct PartyView: View {
    var body: some View {
        GeometryReader { g in
            let colors: [Color] = [.pink, .yellow, .mint, .orange, .purple, .cyan]
            ZStack {
                ForEach(0..<36, id: \.self) { i in
                    // A fixed scatter: the same confetti every time, no randomness to test around.
                    let x = CGFloat((i * 37) % 100) / 100, y = CGFloat((i * 53) % 100) / 100
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(colors[i % colors.count])
                        .frame(width: 5, height: 9)
                        .rotationEffect(.degrees(Double(i * 29)))
                        .position(x: x * g.size.width, y: y * g.size.height * 0.85)
                }
                Text(verbatim: "🎉 " + L("모임이 꽉 찼어요!"))
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Capsule().stroke(Color.pink.opacity(0.6), lineWidth: 1.5))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
        .transition(.opacity)
    }
}

/// 설정 > 플러그인 > 가상 오피스 (Plugins.swift's detail for .office).
struct OfficeSettings: View {
    @AppStorage(OfficeCenter.onKey, store: AppDefaults.store) private var on = false
    @ObservedObject private var bus = SocialBus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("가상 오피스 켜기", isOn: $on).toggleStyle(.switch).controlSize(.small)
                Spacer()
                if on {
                    Menu {
                        ForEach(OfficeStatus.allCases, id: \.self) { s in
                            Button { OfficeCenter.shared.set(s) } label: { Text(verbatim: "\(s.emoji) \(s.label)") }
                        }
                    } label: {
                        Text(verbatim: "\(bus.myStatus.emoji) \(bus.myStatus.label)")
                    }
                    .fixedSize().controlSize(.small)
                    Button("가상 오피스 열기") { OfficeCenter.shared.show() }.controlSize(.small)
                }
            }
            Text("나, AI 팀원, 친구 맺은 맥의 자리와 상태를 한 판에 보여요. 5분 동안 손을 안 대면 자리 비움, 집중 타이머 중엔 집중, 화상 회의 앱이 앞에 있으면 회의로 바뀌어요. 직접 고른 식사, 화장실, 퇴근 같은 상태는 바꿀 때까지 그대로예요. 상태는 친구 맺은 맥에만 가요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
