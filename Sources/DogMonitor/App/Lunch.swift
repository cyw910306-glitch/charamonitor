import AppKit
import SwiftUI

// MARK: Rules (pure)

/// 점심 뽑기's menu groups. Raw values are saved; never rename one. `mine` holds the owner's own menus.
enum LunchCategory: String, CaseIterable, Codable {
    case korean, chinese, japanese, western, snack, asian, salad, mine

    var label: String {
        switch self {
        case .korean: return L("한식")
        case .chinese: return L("중식")
        case .japanese: return L("일식")
        case .western: return L("양식")
        case .snack: return L("분식")
        case .asian: return L("아시안")
        case .salad: return L("샐러드")
        case .mine: return L("내 메뉴")
        }
    }

    var emoji: String {
        switch self {
        case .korean: return "🍚"
        case .chinese: return "🥟"
        case .japanese: return "🍣"
        case .western: return "🍝"
        case .snack: return "🍢"
        case .asian: return "🍜"
        case .salad: return "🥗"
        case .mine: return "⭐️"
        }
    }
}

struct LunchMenu: Codable, Equatable, Hashable {
    var name: String
    var category: LunchCategory
}

/// One day's result: the last pull of that day.
struct LunchPick: Codable, Equatable {
    var menu: LunchMenu
    var date: Date
}

/// 점심 뽑기: what can come out, the reel strip, the day's record and the 11:30 nudge. Pure and tested (LunchTests).
enum LunchRules {
    /// In the app's language (stored and shared as shown).
    static let builtIn: [LunchMenu] = [
        (LunchCategory.korean, [L("김치찌개"), L("된장찌개"), L("제육볶음"), L("비빔밥"), L("순두부찌개"), L("불고기"), L("국밥"), L("냉면"), L("칼국수"), L("갈비탕")]),
        (.chinese, [L("짜장면"), L("짬뽕"), L("탕수육"), L("볶음밥"), L("마라탕"), L("마파두부"), L("울면")]),
        (.japanese, [L("초밥"), L("라멘"), L("돈가스"), L("우동"), L("규동"), L("소바"), L("오므라이스")]),
        (.western, [L("파스타"), L("피자"), L("햄버거"), L("리조또"), L("스테이크"), L("샌드위치")]),
        (.snack, [L("떡볶이"), L("김밥"), L("라볶이"), L("순대"), L("쫄면"), L("만두")]),
        (.asian, [L("쌀국수"), L("팟타이"), L("분짜"), L("나시고렝"), L("카레"), L("반미")]),
        (.salad, [L("닭가슴살 샐러드"), L("포케"), L("연어 샐러드"), L("그릭 샐러드"), L("샐러드 랩")]),
    ].flatMap { c, names in names.map { LunchMenu(name: $0, category: c) } }

    /// 최근 3일 결과 빼기: today and the three days before.
    static let recentDays = 3
    static let maxMine = 40, maxName = 20, keepHistory = 14
    /// 11:30, and up to 12:00 for a Mac that woke late.
    static let nudgeAt = 11 * 60 + 30, nudgeFor = 30

    /// A name as typed, tidied: one line, spaces squeezed, at most `maxName` characters. nil when nothing is left.
    static func clean(_ name: String) -> String? {
        let s = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : String(s.prefix(maxName))
    }

    /// What the lever can land on: the ticked groups' menus (and the owner's under 내 메뉴), without the last
    /// `recentDays` days' results when `skipRecent`, unless that leaves nothing.
    static func pool(mine: [String], categories: Set<LunchCategory>, history: [LunchPick], skipRecent: Bool,
                     now: Date, calendar: Calendar = .current) -> [LunchMenu] {
        let all = builtIn.filter { categories.contains($0.category) }
            + (categories.contains(.mine) ? mine.map { LunchMenu(name: $0, category: .mine) } : [])
        guard skipRecent else { return all }
        let today = calendar.startOfDay(for: now)
        let recent = Set(history.filter {
            let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date), to: today).day ?? .max
            return (0...recentDays).contains(d)
        }.map(\.menu.name))
        let fresh = all.filter { !recent.contains($0.name) }
        return fresh.isEmpty ? all : fresh
    }

    /// `history` with `pick` as its day's result (a later pull the same day replaces the earlier one), oldest first,
    /// the newest `keepHistory` days kept.
    static func record(_ pick: LunchPick, into history: [LunchPick], calendar: Calendar = .current) -> [LunchPick] {
        let rest = history.filter { !calendar.isDate($0.date, inSameDayAs: pick.date) }
        return Array((rest + [pick]).sorted { $0.date < $1.date }.suffix(keepHistory))
    }

    /// The reel's run: `length` menus from `pool`, then `final`, where it stops.
    static func strip<R: RandomNumberGenerator>(to final: LunchMenu, from pool: [LunchMenu], length: Int = 18, using rng: inout R) -> [LunchMenu] {
        (0..<length).compactMap { _ in pool.randomElement(using: &rng) } + [final]
    }

    /// Seconds before each of `steps` reel steps: quick at first, slowing into the stop.
    static func delays(_ steps: Int) -> [TimeInterval] {
        (0..<steps).map { i in
            let t = Double(i) / Double(max(steps - 1, 1))
            return 0.05 + 0.32 * t * t * t
        }
    }

    /// Whether the 11:30 nudge is due at `now`: a workday (`days`, Calendar weekdays) that is no holiday, 11:30 to
    /// 12:00, not said yet today (`lastDay`, WorkHours.day).
    static func nudgeDue(now: Date, days: Set<Int>, lastDay: String?, calendar: Calendar = .current) -> Bool {
        let day = WorkHours.day(now, calendar: calendar)
        guard lastDay != day, days.contains(calendar.component(.weekday, from: now)), !WorkHours.krHolidays.contains(day) else { return false }
        let m = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return (nudgeAt..<nudgeAt + nudgeFor).contains(m)
    }
}

// MARK: The lever

/// 점심 뽑기 레버: a slot machine panel. Pull the lever (as often as you like) and the reel spins and stops on a menu
/// from the ticked groups; the character holds it up and says it. The owner's own menus, 최근 3일 결과 빼기 and an
/// 11:30 nudge (off until turned on). Menu names only: no network, no location. Other features read `Lunch.last`.
final class Lunch: ObservableObject {
    static let shared = Lunch()

    /// The latest result (today's or an older day's), nil before the first pull.
    static var last: LunchPick? { shared.history.last }
    /// Today's lunch, nil until the lever is pulled today.
    static var today: LunchPick? { last.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil } }

    @Published var mine: [String] { didSet { defaults.set(mine, forKey: "lunch.mine") } }
    @Published var categories: Set<LunchCategory> { didSet { defaults.set(categories.map(\.rawValue), forKey: "lunch.categories") } }
    @Published var skipRecent: Bool { didSet { defaults.set(skipRecent, forKey: "lunch.skipRecent") } }
    @Published var nudge: Bool { didSet { defaults.set(nudge, forKey: "lunch.nudge"); start() } }
    @Published private(set) var history: [LunchPick] { didSet { defaults.set(try? JSONEncoder().encode(history), forKey: "lunch.history") } }

    private let defaults = AppDefaults.store
    private var panel: NSPanel?
    private var timer: Timer?

    init() {
        // Read back capped: a hand-edited or imported preferences file cannot grow the lists.
        mine = Array((defaults.stringArray(forKey: "lunch.mine") ?? []).compactMap(LunchRules.clean).prefix(LunchRules.maxMine))
        let saved = (defaults.stringArray(forKey: "lunch.categories") ?? []).compactMap(LunchCategory.init(rawValue:))
        categories = defaults.object(forKey: "lunch.categories") == nil ? Set(LunchCategory.allCases) : Set(saved)
        skipRecent = defaults.object(forKey: "lunch.skipRecent") as? Bool ?? true
        nudge = defaults.bool(forKey: "lunch.nudge")
        history = Array((defaults.data(forKey: "lunch.history").flatMap { try? JSONDecoder().decode([LunchPick].self, from: $0) } ?? [])
            .filter { LunchRules.clean($0.menu.name) == $0.menu.name }.suffix(LunchRules.keepHistory))
    }

    var pool: [LunchMenu] {
        LunchRules.pool(mine: mine, categories: categories, history: history, skipRecent: skipRecent, now: Date())
    }

    /// One pull: today's result, recorded, and the reel's run to it. nil with no group ticked.
    func pull<R: RandomNumberGenerator>(now: Date = Date(), using rng: inout R) -> (pick: LunchPick, strip: [LunchMenu])? {
        let pool = LunchRules.pool(mine: mine, categories: categories, history: history, skipRecent: skipRecent, now: now)
        guard let menu = pool.randomElement(using: &rng) else { return nil }
        let pick = LunchPick(menu: menu, date: now)
        history = LunchRules.record(pick, into: history)
        SocialBus.shared.shareNote()   // friends' cards show 오늘 점심
        return (pick, LunchRules.strip(to: menu, from: pool, using: &rng))
    }

    /// Adds a menu of the owner's (under 내 메뉴); false when blank, already there or the list is full.
    @discardableResult
    func add(_ name: String) -> Bool {
        guard let n = LunchRules.clean(name), !mine.contains(n), mine.count < LunchRules.maxMine else { return false }
        mine.append(n)
        categories.insert(.mine)
        return true
    }

    func remove(_ name: String) { mine.removeAll { $0 == name } }

    /// The result out loud: the friend cheers and says it with its picture card. Not in a meeting or while the screen
    /// may be recorded (FriendVisit.quiet): the panel shows it anyway.
    func announce(_ pick: LunchPick) {
        guard !FriendVisit.quiet() else { return }
        let persona = AssistantModel.persona()
        let m = pick.menu.name   // a category emoji fits few menus (돈가스 under 🍣)
        let line = persona.style.banmal ? L("오늘 점심은 \(m)! 맛있게 먹자") : L("오늘 점심은 \(m)! 맛있게 드세요")
        DesktopKit.celebrate.send(.cheer)
        SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false, repeats: true, card: .cheer,
                                      anchor: DesktopFriends.speaker)
    }

    func show() {
        if panel == nil {
            let p = OfficeCenter.floatingPanel(title: L("점심 뽑기"), size: CGSize(width: 340, height: 520), resizable: false)
            if !p.setFrameUsingName("lunch.lever") { p.center() }
            p.setFrameAutosaveName("lunch.lever")
            p.sharingType = .readOnly   // only menu names: fine on a shared screen
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: LunchLeverView(lunch: self))
        panel?.orderFrontRegardless()
    }

    /// The 11:30 nudge's minute timer, only while it is on. Call at launch; the switch calls it again.
    func start() {
        timer?.invalidate()
        timer = nil
        guard nudge else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        let now = Date()
        guard nudge, Self.today == nil, !FriendVisit.quiet(),
              LunchRules.nudgeDue(now: now, days: AssistantSettings.shared.workHours.days,
                                  lastDay: defaults.string(forKey: "lunch.nudgedDay")) else { return }
        defaults.set(WorkHours.day(now), forKey: "lunch.nudgedDay")
        let persona = AssistantModel.persona()
        let line = persona.style.banmal ? L("곧 점심이야! 메뉴 고민되면 점심 뽑기 레버를 당겨 봐") : L("곧 점심이에요! 메뉴 고민되면 점심 뽑기 레버를 당겨 보세요")
        SpeechBubbleCenter.shared.say(text: line, source: .system, aloud: false, card: .wave, anchor: DesktopFriends.speaker)
    }

    /// 점심 뽑기 for a 놀이 menu.
    static func menuItem() -> NSMenuItem { FriendMenu.item(L("점심 뽑기")) { Lunch.shared.show() } }
}

/// The panel: the friend holding up the result, the machine (reel window and lever), the groups, 내 메뉴.
struct LunchLeverView: View {
    @ObservedObject var lunch: Lunch
    @ObservedObject private var settings = AppSettings.shared
    /// QA renders: a result already on show.
    var preset: LunchPick?

    @State private var strip: [LunchMenu] = []
    @State private var at = 0
    @State private var spinning = false
    @State private var pulled = false
    @State private var result: LunchPick?
    @State private var hop = false
    @State private var typed = ""

    private var shown: LunchPick? { result ?? preset ?? Lunch.today }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                friend
                machine
            }
            groups
            Toggle(L("최근 3일 나온 메뉴 빼기"), isOn: $lunch.skipRecent).font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L("11:30에 점심 알림 (평일)"), isOn: $lunch.nudge).font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .leading)
            mineList
        }
        .padding(14)
        .frame(width: 340)
    }

    // The character with the result on a little sign, hopping when it lands.
    private var friend: some View {
        let cache = DogSpriteCache(SpriteLook(settings), pixelSize: 2)
        let frames = cache.frames(forExtra: .eat) ?? cache.frames(for: .walk)
        return VStack(spacing: 2) {
            if let s = shown, !spinning {
                Text(s.menu.name).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.brown.opacity(0.7), lineWidth: 2))
                    .foregroundStyle(.black)
                    .frame(maxWidth: 104)
                Rectangle().fill(Color.brown.opacity(0.7)).frame(width: 3, height: 10)
            } else {
                Text(verbatim: spinning ? "…" : "?").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
            }
            FramesPlayer(frames: spinning || DesktopKit.reduceMotion ? Array(frames.prefix(1)) : frames, size: cache.imageSize,
                         every: 0.18, smooth: cache.smooth)
                .frame(width: min(cache.imageSize.width, 96), height: min(cache.imageSize.height, 96))
                .offset(y: hop ? -10 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: 108)
    }

    // The cabinet: a three-line reel window, the pull button, and the lever at its side.
    private var machine: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 8) {
                Text(verbatim: "LUNCH").font(.system(size: 11, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                reel
                Button(action: pull) {
                    Text(spinning ? L("돌아가는 중…") : L("레버 당기기")).font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Capsule().fill(Color.yellow))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(spinning || lunch.categories.isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color(red: 0.86, green: 0.25, blue: 0.22), Color(red: 0.62, green: 0.12, blue: 0.14)],
                                                                             startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.yellow.opacity(0.8), lineWidth: 2))
            lever
        }
    }

    private var reel: some View {
        let row = { (i: Int, main: Bool) -> AnyView in
            let m = strip.indices.contains(i) ? strip[i] : (main ? shown?.menu : nil)
            return AnyView(Text(m.map(\.name) ?? (main ? L("뭐 먹지?") : " "))
                .font(.system(size: main ? 15 : 11, weight: main ? .bold : .regular, design: .rounded))
                .foregroundStyle(main ? Color.black : Color.black.opacity(0.35))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 140))
        }
        return VStack(spacing: 4) {
            row(at - 1, false)
            row(at, true)
            row(at + 1, false)
        }
        .padding(.vertical, 6)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .blur(radius: spinning && at < strip.count - 4 ? 0.8 : 0)
        .accessibilityElement()
        .accessibilityLabel(shown.map { L("오늘 점심: \($0.menu.name)") } ?? L("아직 안 뽑았어요"))
    }

    private var lever: some View {
        VStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 18, height: 18).overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
            RoundedRectangle(cornerRadius: 2).fill(Color.gray).frame(width: 5, height: 52)
            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.8)).frame(width: 12, height: 14)
        }
        .rotationEffect(.degrees(pulled ? 150 : 0), anchor: .bottom)
        .frame(width: 26, height: 90)
        .contentShape(Rectangle())
        .onTapGesture(perform: pull)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L("레버 당기기"))
        .accessibilityAction { pull() }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("어떤 메뉴에서 뽑을까요?")).font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(LunchCategory.allCases, id: \.self) { c in
                    let on = lunch.categories.contains(c)
                    Button {
                        if on { lunch.categories.remove(c) } else { lunch.categories.insert(c) }
                    } label: {
                        Text(verbatim: "\(c.emoji) \(c.label)").font(.system(size: 11, weight: on ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 3)
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var mineList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("내 메뉴")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(L("예: 회사 앞 국수집"), text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit(add)
                Button(L("추가"), action: add).controlSize(.small).disabled(LunchRules.clean(typed) == nil)
            }
            if lunch.mine.isEmpty {
                Text(L("자주 가는 곳을 넣으면 \"내 메뉴\"에서 함께 나와요")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(lunch.mine, id: \.self) { m in
                            HStack {
                                Text(m).font(.system(size: 12))
                                Spacer()
                                Button { lunch.remove(m) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel(L("\(m) 지우기"))
                            }
                        }
                    }
                }
                .frame(maxHeight: 90)
            }
        }
    }

    private func add() {
        if lunch.add(typed) { typed = "" }
    }

    private func pull() {
        guard !spinning else { return }
        var rng = SystemRandomNumberGenerator()
        guard let (pick, run) = lunch.pull(using: &rng) else { return }
        result = nil
        if DesktopKit.reduceMotion {
            strip = run; at = run.count - 1
            land(pick)
            return
        }
        spinning = true
        strip = run
        at = 0
        withAnimation(.easeIn(duration: 0.18)) { pulled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { pulled = false } }
        var t: TimeInterval = 0.15
        for (i, d) in LunchRules.delays(run.count - 1).enumerated() {
            t += d
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                at = i + 1
                if i + 1 == run.count - 1 { land(pick) }
            }
        }
    }

    private func land(_ pick: LunchPick) {
        spinning = false
        result = pick
        if !DesktopKit.reduceMotion {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { hop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring()) { hop = false } }
        }
        lunch.announce(pick)
    }
}
