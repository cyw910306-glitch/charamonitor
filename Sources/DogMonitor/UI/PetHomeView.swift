import SwiftUI

/// Sections under the room.
enum PetTab: String, CaseIterable, Identifiable {
    case missions = "미션", shop = "상점", decor = "꾸미기", focus = "집중", diary = "일기"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .missions: return L("미션")
        case .shop: return L("상점")
        case .decor: return L("꾸미기")
        case .focus: return L("집중")
        case .diary: return L("일기")
        }
    }

}

/// "펫 키우기" page: the pixel room, the four gauges and 밥 주기 · 쓰다듬기 · 씻기기.
struct PetHomeView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: AppSettings
    let onBack: () -> Void
    @ObservedObject private var pet = PetModel.shared
    @StateObject private var sprites = SpriteHolder()
    @State private var tab: PetTab

    /// `tab` lets the QA render open another section.
    init(monitor: SystemMonitor, settings: AppSettings, tab: PetTab = .missions, onBack: @escaping () -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.onBack = onBack
        _tab = State(initialValue: tab)
    }

    private var s: PetState { pet.state }

    var body: some View {
        PageScaffold(title: L("펫 키우기"), onBack: onBack) {
            VStack(alignment: .leading, spacing: 10) {
                status
                PetRoomView(cache: sprites.cache(for: settings), state: s, reaction: pet.reaction)
                gauges
                careButtons
                Picker("", selection: $tab) {
                    ForEach(PetTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                section
            }
        }
        .onAppear { pet.adopt() }
    }

    // MARK: Top

    private var status: some View {
        HStack(spacing: 8) {
            Text(settings.characterName).font(.system(size: 13, weight: .bold)).lineLimit(1)
            Text("Lv \(s.level)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            FillBar(fraction: Double(s.xp) / Double(PetState.xpNeeded(s.level)), color: .purple, height: 6)
                .frame(width: 70)
                .accessibilityLabel("다음 레벨까지")
            if s.stage != .baby { Text(s.stage.title).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            coinLabel
        }
    }

    private var coinLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.circle.fill").foregroundStyle(.yellow)
            Text("\(s.coins) 코인").monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private var gauges: some View {
        let rows = [[PetGauge.food, .mood], [.energy, .clean]]
        return VStack(spacing: 6) {
            ForEach(rows, id: \.self) { pair in
                HStack(spacing: 14) { ForEach(pair, id: \.self) { gauge($0) } }
            }
        }
    }

    private func gauge(_ g: PetGauge) -> some View {
        let v = s.value(g)
        return HStack(spacing: 5) {
            Image(systemName: g.symbol).font(.system(size: 10)).foregroundStyle(Self.color(g)).frame(width: 14)
            Text(g.title).font(.system(size: 11)).frame(width: 38, alignment: .leading)
            FillBar(fraction: v / 100, color: v < 25 ? .red : Self.color(g), height: 7)
            Text("\(Int(v.rounded()))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.title)
        .accessibilityValue("\(Int(v.rounded()))")
    }

    static func color(_ g: PetGauge) -> Color {
        switch g {
        case .food: return .orange
        case .mood: return .pink
        case .energy: return Color(red: 0.85, green: 0.68, blue: 0.1)
        case .clean: return .blue
        }
    }

    private var careButtons: some View {
        HStack(spacing: 8) {
            careButton(s.isAway ? L("밥 주고 데려오기") : L("밥 주기"), symbol: "fork.knife") { pet.care(.feed) }
            careButton(L("쓰다듬기"), symbol: "heart.fill") { pet.care(.pet) }
                .disabled(s.isAway)
            careButton(L("씻기기"), symbol: "sparkles") { pet.care(.wash) }
                .disabled(s.isAway)
        }
    }

    private func careButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: Sections

    @ViewBuilder private var section: some View {
        switch tab {
        case .missions: missions
        case .shop: shop
        case .decor: decor
        case .focus: focus
        case .diary: diary
        }
    }

    private var missions: some View {
        VStack(spacing: 8) {
            Panel {
                HStack {
                    Text("오늘의 미션").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if s.attendStreak > 0 {
                        Label("출석 \(s.attendStreak)일째", systemImage: "calendar").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ForEach(s.today.missions, id: \.self) { kind in
                    let done = s.today.done.contains(kind)
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
                        Text(kind.title).strikethrough(done, color: .secondary)
                        Spacer()
                        Text("\(min(s.today[kind], kind.target))/\(kind.target)").monospacedDigit().foregroundStyle(.secondary)
                        Text("+\(kind.reward)").monospacedDigit().foregroundStyle(done ? Color.secondary : Color.warn).frame(width: 30, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                }
            }
            Panel {
                Text("진화").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(PetStage.allCases.dropFirst(), id: \.self) { stage in
                        let got = s.stage >= stage
                        VStack(spacing: 4) {
                            if let a = PetRoomArt.accessory(stage) {
                                Image(decorative: a.image, scale: 1).interpolation(.none).resizable()
                                    .frame(width: CGFloat(a.width) * 2, height: CGFloat(a.height) * 2)
                                    .frame(height: 16)
                                    .opacity(got ? 1 : 0.35)
                            }
                            Text("Lv \(stage.level) \(stage.title)").font(.system(size: 11, weight: got ? .semibold : .regular))
                                .foregroundStyle(got ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(got ? "얻음" : "아직")
                    }
                }
                Text("원래 캐릭터 그림은 그대로, 머리 위에 장식이 더해져요.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var shop: some View {
        VStack(spacing: 8) {
            HStack {
                Text("코인으로만 사요. 뽑기는 없어요.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                coinLabel
            }
            shopGrid(L("가구"), PetCatalog.all.filter { $0.kind == .wall || $0.kind == .floor })
            shopGrid(L("벽지"), PetCatalog.items(.wallpaper))
            shopGrid(L("바닥"), PetCatalog.items(.floorTile))
        }
    }

    private func shopGrid(_ title: String, _ items: [PetItem]) -> some View {
        Panel {
            Text(title).font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(items) { shopCard($0) }
            }
        }
    }

    private func shopCard(_ item: PetItem) -> some View {
        let owned = s.owned.contains(item.id)
        let inUse = s.wallpaper == item.id || s.floor == item.id || s.slots.contains(item.id)
        let art = PetRoomArt.preview(item)
        let k = min(2, 34 / CGFloat(max(art.height, 1)), 74 / CGFloat(max(art.width, 1)))
        return VStack(spacing: 4) {
            Image(decorative: art, scale: 1).interpolation(.none).resizable()
                .frame(width: CGFloat(art.width) * k, height: CGFloat(art.height) * k)
                .frame(height: 36)
            Text(item.name).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            if owned {
                if item.kind == .wallpaper || item.kind == .floorTile, !inUse {
                    Button("바꾸기") { pet.cover(item.id) }.controlSize(.small)
                } else {
                    Text(inUse ? "사용 중" : "보유 중").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(height: 18)
                }
            } else {
                Button("\(item.price) 코인") { pet.buy(item.id) }
                    .controlSize(.small)
                    .disabled(s.coins < item.price)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }

    private var decor: some View {
        VStack(spacing: 8) {
            Panel {
                Text("벽").font(.system(size: 13, weight: .semibold))
                ForEach(0..<3, id: \.self) { slotRow($0, label: L("벽 \($0 + 1)"), kind: .wall) }
                Divider()
                Text("바닥").font(.system(size: 13, weight: .semibold))
                ForEach(3..<6, id: \.self) { slotRow($0, label: L("바닥 \($0 - 2)"), kind: .floor) }
            }
            Panel {
                coverRow(L("벽지"), kind: .wallpaper, current: s.wallpaper)
                coverRow(L("바닥재"), kind: .floorTile, current: s.floor)
                Text("상점에서 산 것만 고를 수 있어요.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func slotRow(_ slot: Int, label: String, kind: PetItem.Kind) -> some View {
        let current = s.slots[slot].flatMap(PetCatalog.item)
        let choices = PetCatalog.items(kind).filter { s.owned.contains($0.id) }
        return HStack {
            Text(label).font(.system(size: 12)).frame(width: 44, alignment: .leading)
            Menu(current?.name ?? L("비어 있음")) {
                ForEach(choices) { item in Button(item.name) { pet.place(item.id, slot: slot) } }
                if choices.isEmpty { Text("산 가구가 없어요") }
                Divider()
                Button("비우기") { pet.place(nil, slot: slot) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private func coverRow(_ label: String, kind: PetItem.Kind, current: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 44, alignment: .leading)
            Menu(PetCatalog.item(current)?.name ?? current) {
                ForEach(PetCatalog.items(kind).filter { s.owned.contains($0.id) }) { item in Button(item.name) { pet.cover(item.id) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var focus: some View {
        VStack(spacing: 8) {
            Panel {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                            Text(Self.clock(s.focus.map { $0.endsAt.timeIntervalSince(ctx.date) } ?? PetFocus.work))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        Text(s.focus?.mode == .work ? "집중 중 · 끝나면 코인 15개" : s.focus?.mode == .rest ? "쉬는 시간 · 기지개 켜요" : "25분 집중, 5분 휴식")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.focus == nil {
                        Button { pet.startFocus() } label: { Label("집중 시작", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button { pet.stopFocus() } label: { Label("그만하기", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                    }
                }
                Text("오늘 집중 \(s.today[.focus])번").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            focusGrass
            Panel {
                Toggle(isOn: Binding(get: { s.eyeRest }, set: { pet.setEyeRest($0) })) {
                    Text("20-20-20 눈 휴식 알림").font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("화면을 20분 보면 캐릭터가 말풍선으로 20초 동안 6미터 먼 곳을 보자고 알려 줘요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 집중 잔디: the last 12 weeks, a column a week with Monday on top, darker for more rounds, today outlined.
    private var focusGrass: some View {
        let today = s.today.day
        // The state's day, not the wall clock: rollDay is forward only, so a clock set back leaves today.day ahead.
        let anchor = Calendar.current.date(byAdding: .day, value: today - PetState.dayNumber(Date()), to: Date()) ?? Date()
        let monday = today - (Calendar.current.component(.weekday, from: anchor) + 5) % 7
        let first = monday - 7 * 11
        let thisWeek = (monday...today).reduce(0) { $0 + s.focusCount($1) }
        var caption = L("이번 주 \(thisWeek)번")
        if let best = s.focusBest(first...today) {
            let date = Calendar.current.date(byAdding: .day, value: best.day - today, to: anchor) ?? anchor
            caption += L(" · 최고 \(Self.monthDay.string(from: date)) \(best.count)번")
        }
        return Panel {
            Text("집중 기록").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = first + week * 7 + row
                            let n = s.focusCount(day)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(n == 0 ? Color.primary.opacity(0.08) : Color.accentColor.opacity([0.35, 0.55, 0.8, 1][min(n, 4) - 1]))
                                .overlay { if day == today { RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.7), lineWidth: 1) } }
                                .frame(width: 10, height: 10)
                                .opacity(day > today ? 0 : 1)
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("12주 집중 기록"))
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MMMd")   // 10월 14일
        return f
    }()

    static func clock(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var diary: some View {
        Panel {
            Text("성장 일기").font(.system(size: 13, weight: .semibold))
            diaryRow(L("오늘"), PetState.diaryLine(s.today, level: s.level))
            if s.diary.isEmpty {
                Text("하루가 지나면 여기에 한 줄씩 적혀요.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(s.diary.prefix(14)) { diaryRow(Self.dayFormat.string(from: $0.date), $0.text) }
            }
        }
    }

    private func diaryRow(_ when: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(when).foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(width: 84, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MMMdE")   // 10월 3일 (금)
        return f
    }()
}
