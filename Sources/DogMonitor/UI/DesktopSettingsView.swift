import SwiftUI

/// One 데스크톱 친구 on/off for the menu bar's quick toggles (StatusItemController).
struct DesktopToggle {
    let title: String
    let isOn: () -> Bool
    let set: (Bool) -> Void
}

enum DesktopFriends {
    /// The menu bar's 데스크톱 친구 submenu, in order. Each desktop feature adds its one line here.
    static var toggles: [DesktopToggle] {
        [
            DesktopToggle(title: L("커서 친구"), isOn: { MotionStore.shared.cursorBuddy }, set: { MotionStore.shared.cursorBuddy = $0 }),
            DesktopToggle(title: L("대롱대롱 친구"), isOn: { HangingStore.shared.prefs.on }, set: { HangingStore.shared.prefs.on = $0 }),
            DesktopToggle(title: L("날씨 창문"), isOn: { WeatherWindow.shared.on }, set: { WeatherWindow.shared.on = $0 }),
            DesktopToggle(title: L("풀밭 친구들"), isOn: { MeadowStore.shared.prefs.on }, set: { MeadowStore.shared.prefs.on = $0 }),
            DesktopToggle(title: L("바탕화면 러그"), isOn: { RugStore.shared.prefs.on }, set: { RugStore.shared.prefs.on = $0 }),
        ]
    }

    /// Who a bubble, a reaction card or the 집중 위젯 points at: the 커서 친구 when it is out, else the first 풀밭 친구;
    /// nil = the menu bar icon.
    static var speaker: (() -> CGPoint?)? {
        if CursorBuddy.shared.head() != nil { return { CursorBuddy.shared.head() } }
        if MeadowFriends.shared.head(0) != nil { return { MeadowFriends.shared.head(0) } }
        return nil
    }
}

/// "데스크톱 친구" in 설정: the friend saying hi, 꾸미기, then one sticker card per friend; changes show at once.
/// Sections in order: 꾸미기 / 커서 친구 / 대롱대롱 친구 / 풀밭 친구들 / 바탕화면 러그 / 날씨 창문 / 집중 타이머 / 퀵물어보기.
struct DesktopSettingsView: View {
    @ObservedObject var store: MotionStore = .shared
    @ObservedObject var hanging: HangingStore = .shared
    @ObservedObject var meadow: MeadowStore = .shared
    @ObservedObject var rug: RugStore = .shared
    @ObservedObject var focus: FocusCenter = .shared
    @ObservedObject var settings: AppSettings = .shared
    @StateObject private var quickSample = FriendQuickAsk.sample()
    /// The card that just said hi (a friend switched on) and whose badge is hopping.
    @State private var hello: DesktopTool?
    @State private var hop: DesktopTool?
    @State private var heroHop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            decorSection
            cursorSection
            hangingSection
            meadowSection
            rugSection
            weatherSection
            focusSection
            quickAskSection
        }
        .animation(DesktopKit.reduceMotion ? nil : .easeOut(duration: 0.22), value: store.cursorBuddy)
        .animation(DesktopKit.reduceMotion ? nil : .easeOut(duration: 0.22), value: weather.on)
    }

    // MARK: Hero

    /// The menu bar character waving hello, how many friends are out, and 불러보기 (every friend reacts).
    private var hero: some View {
        let cache = Self.heroCache(SpriteLook(settings))
        let walk = cache.frames(for: .walk)
        let n = DesktopFriends.toggles.filter { $0.isOn() }.count
        let accent = settings.palette.accent ?? Color.secondary
        return HStack(spacing: 12) {
            FramesPlayer(frames: DesktopKit.reduceMotion ? Array(walk.prefix(1)) : walk, size: cache.imageSize, every: 0.16, smooth: cache.smooth)
                .offset(y: heroHop ? -7 : 0)
                .frame(width: 78, height: 78)
                .background(Circle().fill(accent.opacity(0.2)))
                .overlay(Circle().strokeBorder(accent.opacity(0.4), lineWidth: 1.5))
                .accessibilityElement()
                .accessibilityLabel(settings.characterName)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.greeting()).font(.system(size: 15 * k, weight: .bold, design: .rounded))
                Text(n == 0 ? L("다들 쉬는 중이에요. 하나 깨워 볼까요?") : L("친구 \(n)명이 나와 있어요"))
                    .font(f(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: callFriends) {
                    Text("불러보기 👋").font(.system(size: 12 * k, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(accent.opacity(0.22)))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("나와 있는 친구들이 모두 반응해요"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func callFriends() {
        DesktopKit.celebrate.send(PoseCard.allCases.randomElement() ?? .wave)
        guard !DesktopKit.reduceMotion else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { heroHop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { heroHop = false }
        }
    }

    /// The hero's hello by the hour, with a 🎃 late in October and a 🎄 in December.
    static func greeting(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour], from: date)
        switch (c.month ?? 0, c.day ?? 0, c.hour ?? 12) {
        case (10, 24...31, _): return L("🎃 오늘은 살짝 으스스하게")
        case (12, _, _): return L("🎄 포근한 12월이에요")
        case (_, _, 5..<12): return L("좋은 아침이에요")
        case (_, _, 12..<20): return L("오늘도 같이 놀아요")
        default: return L("늦었어요, 살살 놀아요")
        }
    }

    /// The hero's small walk, kept for the last look only.
    private static var heroKept: (look: SpriteLook, cache: DogSpriteCache)?
    private static func heroCache(_ look: SpriteLook) -> DogSpriteCache {
        if let kept = heroKept, kept.look == look { return kept.cache }
        let fresh = DogSpriteCache(look, pixelSize: 2)
        heroKept = (look, fresh)
        return fresh
    }

    // MARK: 커서 친구

    private var cursorSection: some View {
        Panel(tint: tint(.cursor, on: store.cursorBuddy)) {
            header("🐾", "커서 친구", .cursor, isOn: $store.cursorBuddy)
            tagline("커서를 졸졸 따라다녀요")
            if store.cursorBuddy {
                VStack(alignment: .leading, spacing: 7) {
                    row("크기") {
                        Picker("크기", selection: $store.buddySize) {
                            ForEach(BuddySize.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                    row("빠르게 움직이면") {
                        Picker("빠르게 움직이면", selection: $store.buddyBoost) {
                            ForEach(BuddyBoost.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                    row("혼자 놀기") { onOff("혼자 놀기", $store.buddyPlay, .cursor) }
                }
                details("커서를 움직이면 걸어서 따라오고, 커서가 멀리 가면 뛰어와요. 멈추면 곁에서 기다리다 가끔 혼자 놀고, 충전 중엔 밥을 먹어요. 한동안 손을 안 대면 낮잠을 자요.",
                        "혼자 놀기를 켜 두면 가끔 맨 앞 창의 위쪽 끝에 올라가 앉고, 나비를 쫓거나 커서에 매달리기도 해요. 앉을 자리는 창의 위치만 보고 찾아요. 창 안의 내용은 보지 않아요.",
                        "마우스를 휙 돌리면 커지고 기울어요. 마구 흔들면 어지러워해요. 한 번 누르면 반가워하고, 두 번 누르면 AI 비서가 열려요. 잡아 끌 수도 있고, 오른쪽 클릭은 메뉴예요.",
                        "macOS는 시스템 커서 자체를 바꾸지 못하게 해서 따라다니는 친구로 만들었어요.")
            }
        }
    }

    // MARK: 대롱대롱 친구

    private var hangingSection: some View {
        Panel(tint: tint(.hanging, on: hanging.prefs.on)) {
            header("🎐", "대롱대롱 친구", .hanging, isOn: $hanging.prefs.on)
            tagline("메뉴바에 매달려 살랑살랑")
            if hanging.prefs.on {
                hangingOptions
                details("메뉴바 바로 아래 줄에 매달려 흔들려요. 잡아서 던지면 줄이 늘었다 튕기고, 누르면 풍경 소리가 나요. 끌어다 놓고 잠깐 멈췄다 놓으면 그 자리, 그 줄 길이로 다시 매달아요. 다른 화면으로 끌어 옮길 수도 있어요.")
            }
        }
    }

    @ViewBuilder private var hangingOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("몇 명") {
                Picker("몇 명", selection: $hanging.prefs.count) {
                    ForEach(1...HangPrefs.maxCount, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            }
            row("바람") {
                Picker("바람", selection: $hanging.prefs.wind) {
                    ForEach(WindLevel.allCases.filter { $0 != .local || HangingFriends.localWind != nil }, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if hanging.prefs.wind == .local && !weather.on {
                Text("날씨 창문을 켜 두면 그 도시 바람을 따라요. 지금은 산들바람이에요")
                    .font(f(10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 92 * k + 10)
            }
            row("풍경 소리") {
                HStack(spacing: 6) {
                    onOff("풍경 소리", $hanging.prefs.sound, .hanging)
                    Slider(value: $hanging.prefs.volume, in: 0...1).frame(width: 90).controlSize(.small).disabled(!hanging.prefs.sound)
                    Button("들어보기") { HangingFriends.preview(Int.random(in: 0..<HangPrefs.maxCount)) }
                        .controlSize(.small).disabled(!hanging.prefs.sound || !settings.friendSounds)
                }
            }
            row("항상 위") { onOff("다른 창보다 위에 두기", $hanging.prefs.onTop, .hanging) }
            row("줄 느낌") {
                Picker("줄 느낌", selection: $hanging.prefs.feel) {
                    ForEach(StringFeel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            }
            row("맨 위에서") {
                HStack(spacing: 6) {
                    onOff("화면 맨 위에서 매달기", $hanging.prefs.fromTop, .hanging)
                    Text("메뉴바 너머로 줄이 보여요").font(f(11)).foregroundStyle(.secondary)
                }
            }
            row("스치면 흔들기") { onOff("커서가 스치면 흔들기", $hanging.prefs.pokeOnHover, .hanging) }
        }
        ForEach(0..<min(hanging.prefs.count, hanging.prefs.slots.count), id: \.self) { i in
            HStack(spacing: 6) {
                slotNumber(i, .hanging)
                whoPicker(who($hanging.prefs.slots, i, copy: "slot"))
                Picker("장식", selection: $hanging.prefs.slots[i].charm) {
                    ForEach(Charm.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 90)
                Picker("줄", selection: $hanging.prefs.slots[i].rope) {
                    ForEach(Rope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 76)
            }
        }
    }

    /// A slot's number as a little tinted dot.
    private func slotNumber(_ i: Int, _ tool: DesktopTool) -> some View {
        Text(verbatim: "\(i + 1)").font(.system(size: 10 * k, weight: .bold, design: .rounded))
            .frame(width: 18 * k, height: 18 * k)
            .background(Circle().fill(palette.tint(tool)?.opacity(0.3) ?? Color.primary.opacity(0.1)))
    }

    private static let photoTag = "@photo"

    private func whoPicker(_ selection: Binding<String>) -> some View {
        Picker("누구", selection: selection) {
            Text("지금 캐릭터").tag("")
            ForEach(OriginalCatalog.all, id: \.id) { Text($0.displayName).tag($0.id) }
            Text("사진·스크린샷…").tag(Self.photoTag)
        }
        .labelsHidden()
    }

    /// A slot's friend as a picker tag: "" the menu bar character, an original's id, or a picture. `copy` names the App
    /// Store build's picture copies ("slot" 대롱대롱, "meadow" 풀밭), so the two never share a file.
    private func who(_ slots: Binding<[HangSlot]>, _ i: Int, copy: String) -> Binding<String> {
        Binding(get: {
            let s = slots.wrappedValue[i]
            return s.imagePath != nil ? Self.photoTag : s.character ?? ""
        }, set: { tag in
            if tag == Self.photoTag {
                if let path = Self.pickPicture(slot: i, name: copy) { slots.wrappedValue[i].imagePath = path }
            } else {
                Self.forgetCopies(slot: i, name: copy)
                slots.wrappedValue[i].imagePath = nil
                slots.wrappedValue[i].character = tag.isEmpty ? nil : tag
            }
        })
    }

    /// A picture from this Mac only. The App Store build keeps a copy in its container (the pick is readable until quit).
    private static func pickPicture(slot: Int, name: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("매달 사진이나 스크린샷을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return nil }
        #if MAS
        let fm = FileManager.default
        guard let dir = copiesDir else { return url.path }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("\(name)\(slot)." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()))
        forgetCopies(slot: slot, name: name)   // the old picture goes, whatever its extension
        return (try? fm.copyItem(at: url, to: copy)).map { copy.path } ?? url.path
        #else
        return url.path
        #endif
    }

    /// The App Store build's own copies of the pictures; nil elsewhere (there the slot keeps the user's file, never deleted).
    private static var copiesDir: URL? {
        #if MAS
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hanging", isDirectory: true)
        #else
        nil
        #endif
    }

    /// Deletes slot `slot`'s copied picture (any extension): a removed screenshot does not stay in the container.
    private static func forgetCopies(slot: Int, name: String) {
        let fm = FileManager.default
        guard let dir = copiesDir, let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.deletingPathExtension().lastPathComponent == "\(name)\(slot)" { try? fm.removeItem(at: f) }
    }

    // MARK: 풀밭 친구들

    private var meadowSection: some View {
        Panel(tint: tint(.meadow, on: meadow.prefs.on)) {
            header("🌱", "풀밭 친구들", .meadow, isOn: $meadow.prefs.on)
            tagline("독 위에서 통통 뛰놀아요")
            if meadow.prefs.on {
                VStack(alignment: .leading, spacing: 7) {
                    row("몇 명") {
                        Picker("몇 명", selection: $meadow.prefs.count) {
                            ForEach(1...MeadowPrefs.maxCount, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                    row("항상 위") { onOff("다른 창보다 위에 두기", $meadow.prefs.onTop, .meadow) }
                }
                ForEach(0..<min(meadow.prefs.count, meadow.prefs.slots.count), id: \.self) { i in
                    HStack(spacing: 6) {
                        slotNumber(i, .meadow)
                        whoPicker(who($meadow.prefs.slots, i, copy: "meadow"))
                    }
                }
                details("화면 아래쪽, 독 바로 위에 친구들이 모여 살아요. 제자리에서 통통 뛰고, 가끔 산책하거나 앉아 쉬어요. 누르면 그 친구 위에 퀵물어보기가 열리고, 잡아서 들었다 놓으면 툭 떨어져요. 창을 띄우면 그 뒤로 숨어요.")
            }
        }
    }

    // MARK: 바탕화면 러그

    private var rugSection: some View {
        Panel(tint: tint(.rug, on: rug.prefs.on)) {
            header("🧶", "바탕화면 러그", .rug, isOn: $rug.prefs.on)
            tagline("접고 구기는 작은 천 러그")
            if rug.prefs.on {
                row("그림") {
                    Picker("그림", selection: $rug.prefs.face) {
                        ForEach(RugFace.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                if rug.prefs.face == .character {
                    row("러그 색") {
                        HStack(spacing: 6) {
                            ForEach(FocusTheme.allCases, id: \.self) { t in
                                swatch(t, chosen: rug.prefs.color == t) { rug.prefs.color = t }
                            }
                            Text(rug.prefs.color.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                        }
                    }
                }
                row("부드러움") {
                    HStack(spacing: 8) {
                        Picker("부드러움", selection: $rug.prefs.softness) {
                            ForEach(RugSoftness.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                        Button("펼치기") { DesktopRug.shared.smooth() }.controlSize(.small)
                    }
                }
                details("바탕화면에 작은 천 러그를 깔아요. 그림을 '캐릭터'로 두면 지금 고른 친구가 러그 가운데에 크게 들어가요. 가장자리를 잡아 끌면 접혀 넘어가며 뒷면이 보이고, 가운데를 이리저리 문지르면 주름이 생겨 그대로 남아요. 두 번 누르거나 오른쪽 클릭의 '빳빳하게 펼치기'로 다시 펴요.")
            }
        }
    }

    // MARK: 집중 타이머

    private var focusSection: some View {
        Panel(tint: tint(.focus, on: true)) {
            HStack {
                badge("⏰", "집중 타이머", .focus)
                Spacer()
                Button(focus.running ? "그만하기" : "집중 시작") {
                    if focus.running { focus.stop() } else { focus.start() }
                }
                .controlSize(.small)
            }
            tagline("친구랑 같이 집중해요")
            VStack(alignment: .leading, spacing: 7) {
                row("위젯 색") {
                    HStack(spacing: 6) {
                        ForEach(FocusTheme.allCases, id: \.self) { t in swatch(t, chosen: focus.theme == t) { focus.theme = t } }
                        Text(focus.theme.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                }
                row("목표 시간") {
                    Picker("목표 시간", selection: $focus.goalMinutes) {
                        Text("끄기").tag(0)
                        ForEach([15, 25, 50], id: \.self) { Text("\($0)분").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("위젯 크기") {
                    Picker("위젯 크기", selection: $focus.size) {
                        ForEach(FocusSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("달성 소리") { onOff("목표 달성 소리", $focus.sound, .focus) }
                row("메뉴바 시간") { onOff("메뉴바에 시간 보이기", $focus.showInMenuBar, .focus) }
                row("시간 옆 이모지") { onOff("메뉴바 시간에 이모지 붙이기", $focus.menuEmoji, .focus).disabled(!focus.showInMenuBar) }
            }
            details("집중하는 동안 친구 머리 위에 시간이 올라가고, 친구는 책상에 앉아 공부해요. 오늘 할 일이 있으면 첫 번째 일을 '진행 중'으로 보여 주고, 체크하면 미리알림에서도 끝낸 일로 바꿔요. 메뉴바 메뉴나 AI 비서에게 '집중 시작'이라고 해도 돼요.")
        }
    }

    /// One 위젯 색 or 러그 색: the sticker's fill with its accent ring, ringed in ink when chosen (like 창틀 색).
    private func swatch(_ t: FocusTheme, chosen: Bool, pick: @escaping () -> Void) -> some View {
        let hex = t.hexes(dark: false)
        return Button(action: pick) {
            Circle().fill(WeatherArt.color(hex.fill))
                .overlay(Circle().strokeBorder(WeatherArt.color(hex.accent), lineWidth: chosen ? 2 : 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(WeatherArt.color(hex.ink), lineWidth: 1.5).opacity(chosen ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(t.label)
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: 퀵물어보기

    private var quickAskSection: some View {
        Panel(tint: tint(.quickAsk, on: true)) {
            badge("💬", "퀵물어보기", .quickAsk)
            tagline("친구를 누르면 바로 답해 줘요")
            Shrink(scale: 0.85) { FriendQuickAskView(model: quickSample).scaleEffect(0.85) }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                row("색 테마") {
                    HStack(spacing: 6) {
                        ForEach(QuickAskTheme.allCases, id: \.self) { t in quickSwatch(t) }
                        Text(store.quickAskTheme.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                }
                row("글자 크기") {
                    Picker("글자 크기", selection: $store.quickAskTextSize) {
                        ForEach(QuickAskTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("움직임") {
                    Picker("움직임", selection: $store.quickAskMotion) {
                        ForEach(QuickAskMotion.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("친구 얼굴") { onOff("친구 얼굴 보이기", $store.quickAskShowAvatar, .quickAsk) }
                row("응원 효과음") { onOff("응원·춤에 효과음", $store.quickAskSound, .quickAsk) }
            }
            details("친구를 한 번 누르면 머리 위에 말풍선이 떠요. AI 없이 바로 답해 줘요.")
        }
    }

    /// One 색 테마: the bubble's fill with its accent ring, ringed in ink when chosen (like 위젯 색).
    private func quickSwatch(_ t: QuickAskTheme) -> some View {
        let chosen = store.quickAskTheme == t, hex = t.hexes(dark: false)
        return Button { store.quickAskTheme = t } label: {
            Circle().fill(WeatherArt.color(hex.fill))
                .overlay(Circle().strokeBorder(WeatherArt.color(hex.accent), lineWidth: chosen ? 2 : 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(WeatherArt.color(hex.ink), lineWidth: 1.5).opacity(chosen ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(t.label)
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: 날씨 창문

    @ObservedObject private var weather: WeatherWindow = .shared
    @ObservedObject private var forecast: WeatherService = .shared

    private var weatherSection: some View {
        Panel(tint: tint(.weather, on: weather.on)) {
            header("⛅", "날씨 창문", .weather, isOn: $weather.on)
            tagline("그 도시 날씨 속 작은 창문")
            if weather.on {
                VStack(alignment: .leading, spacing: 7) {
                    row("도시") {
                        HStack {
                            Picker("도시", selection: Binding(get: { forecast.city.name },
                                                             set: { n in if let c = WeatherCity.presets.first(where: { $0.name == n }) { forecast.city = c } })) {
                                if !WeatherCity.presets.contains(forecast.city) { Text(forecast.city.name).tag(forecast.city.name) }
                                ForEach(WeatherCity.presets, id: \.name) { Text($0.name).tag($0.name) }
                            }
                            .labelsHidden().fixedSize()
                            Button("다른 도시 검색…") { WeatherWindow.askCity() }.controlSize(.small)
                        }
                    }
                    row("크기") {
                        Picker("크기", selection: $weather.sizeStep) {
                            ForEach(WeatherFrame.scales.indices, id: \.self) { Text(WeatherFrame.label($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    row("창틀 색") {
                        HStack(spacing: 6) {
                            ForEach(WeatherTheme.allCases, id: \.self) { t in themeSwatch(t) }
                            Text(weather.theme.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                        }
                    }
                    row("온도 보이기") { onOff("온도 보이기", $weather.showTemp, .weather) }
                    row("클릭하면 한마디") { onOff("클릭하면 한마디", $weather.chatter, .weather) }
                    row("계절 장식") { onOff("계절 장식", $weather.seasonal, .weather) }
                    row("항상 위") { onOff("항상 위에 두기", $weather.onTop, .weather) }
                }
                details("고른 도시의 지금 날씨 속에서 캐릭터가 지내는 작은 창문이에요. 클릭하면 깡총 뛰며 날씨에 맞게 반응하고, 빈 곳을 끌면 옮겨져요. 오른쪽 클릭으로 미리보기와 위치 초기화를 할 수 있어요. 켜 두면 아침에 우산이나 겉옷 이야기를 하루 한 번 해 줘요.")
                Text("날씨 정보: MET Norway (CC BY 4.0)").font(f(10)).foregroundStyle(.tertiary)
            }
        }
    }

    /// One 창틀 색: the frame's colour with its outline, ringed when chosen.
    private func themeSwatch(_ t: WeatherTheme) -> some View {
        let chosen = weather.theme == t
        return Button { weather.theme = t } label: {
            Circle().fill(WeatherArt.color(t.hexes.ring))
                .overlay(Circle().strokeBorder(chosen ? .white : WeatherArt.color(t.hexes.ink, 0.35), lineWidth: chosen ? 2 : 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(WeatherArt.color(t.hexes.ink), lineWidth: 1.5).opacity(chosen ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(t.label)
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: 꾸미기

    /// Every look-and-feel choice in one card: 색 테마, 글자 크기, 움직임, 효과음, 설명 다 펼치기 and 그림 스타일.
    private var decorSection: some View {
        Panel(tint: palette.accent) {
            HStack(spacing: 8) {
                Text(verbatim: "🎀").font(.system(size: 14 * k))
                    .frame(width: 26 * k, height: 26 * k)
                    .background(Circle().fill(palette.accent?.opacity(0.25) ?? Color.primary.opacity(0.08)))
                    .accessibilityHidden(true)
                Text("꾸미기").font(.system(size: 13 * k, weight: .bold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 7) {
                row("색 테마") {
                    HStack(spacing: 6) {
                        ForEach(AppPalette.allCases, id: \.self) { p in paletteDot(p) }
                        Text(palette.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                }
                row("글자 크기") {
                    Picker("글자 크기", selection: $settings.settingsTextLarge) {
                        Text("보통").tag(false)
                        Text("크게").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("움직임") {
                    Picker("움직임", selection: $settings.motionLevel) {
                        ForEach(MotionLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                row("효과음") {
                    HStack(spacing: 6) {
                        decorSwitch("효과음", $settings.friendSounds)
                        Button("들어보기") { HangingFriends.preview(Int.random(in: 0..<HangPrefs.maxCount)) }
                            .controlSize(.small).disabled(!settings.friendSounds)
                    }
                }
                row("설명 다 펼치기") { decorSwitch("설명 다 펼치기", $settings.expandDetails) }
                row("그림 스타일") { RenderStylePicker().labelsHidden() }
            }
            details("움직임 자동은 macOS의 동작 줄이기를 따라요. 잔잔하게는 늘 가만히, 통통은 늘 움직여요.",
                    "효과음을 끄면 풍경 소리, 응원 소리, 집중 알림이 모두 조용해져요.",
                    "그림 스타일은 메뉴바, 커서 친구, 대롱대롱 친구, 날씨 창문이 모두 같은 그림체로 바뀌어요.")
        }
    }

    /// One 색 테마 dot; the chosen one gets a white ring and a little shadow.
    private func paletteDot(_ p: AppPalette) -> some View {
        let chosen = palette == p
        return Button { settings.palette = p } label: {
            Circle().fill(p.accent ?? Color(white: 0.62))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2).opacity(chosen ? 1 : 0))
                .shadow(color: .black.opacity(chosen ? 0.3 : 0), radius: 2, y: 1)
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(p.label)
        .accessibilityLabel(p.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func decorSwitch(_ title: LocalizedStringKey, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.accent)
    }

    // MARK: Pieces

    private var palette: AppPalette { settings.palette }
    /// 글자 크기 크게: every size on this page grows by this.
    private var k: CGFloat { settings.settingsTextLarge ? 1.15 : 1 }
    private func f(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * k, weight: weight) }

    /// A card's colour; an off friend's card is half as strong, asleep.
    private func tint(_ tool: DesktopTool, on: Bool) -> Color? {
        palette.tint(tool).map { on ? $0 : $0.opacity(0.5) }
    }

    /// The emoji badge and the card's title.
    private func badge(_ emoji: String, _ title: LocalizedStringKey, _ tool: DesktopTool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: emoji).font(.system(size: 14 * k))
                .frame(width: 26 * k, height: 26 * k)
                .background(Circle().fill(palette.tint(tool)?.opacity(0.25) ?? Color.primary.opacity(0.08)))
                .scaleEffect(hop == tool && !DesktopKit.reduceMotion ? 1.25 : 1)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13 * k, weight: .bold, design: .rounded))
        }
    }

    /// Badge, title, the hello pill after switching on, and the friend's switch.
    private func header(_ emoji: String, _ title: LocalizedStringKey, _ tool: DesktopTool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            badge(emoji, title, tool)
            if hello == tool {
                Text("안녕! 나왔어요").font(.system(size: 11 * k, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill((palette.tint(tool) ?? .accentColor).opacity(0.3)))
                    .transition(.opacity)
            }
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn.wrappedValue }, set: { on in
                let was = isOn.wrappedValue
                isOn.wrappedValue = on
                if on && !was { cheer(tool) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.tint(tool))
            .accessibilityLabel(Text(title))
        }
    }

    /// A friend just came out: everyone waves, its badge hops and the card says hi for a moment.
    private func cheer(_ tool: DesktopTool) {
        DesktopKit.celebrate.send(.wave)
        let calm = DesktopKit.reduceMotion
        withAnimation(calm ? nil : .spring(response: 0.35, dampingFraction: 0.55)) { hop = tool; hello = tool }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(calm ? nil : .spring(response: 0.35, dampingFraction: 0.55)) { if hop == tool { hop = nil } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(calm ? nil : .easeOut(duration: 0.3)) { if hello == tool { hello = nil } }
        }
    }

    /// The card's one friendly line.
    private func tagline(_ text: LocalizedStringKey) -> some View {
        Text(text).font(f(12)).foregroundStyle(.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
    }

    /// The long explanations, behind 자세히 (open from the start with 설명 다 펼치기).
    private func details(_ lines: LocalizedStringKey...) -> some View {
        Details(lines: lines, k: k, open: settings.expandDetails).id(settings.expandDetails)
    }

    /// One labelled line: the same label column on every card.
    private func row<C: View>(_ label: LocalizedStringKey, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(f(12)).foregroundStyle(.secondary)
                .frame(width: 92 * k, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            control()
        }
    }

    /// A small on/off in the card's colour.
    private func onOff(_ title: LocalizedStringKey, _ isOn: Binding<Bool>, _ tool: DesktopTool) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.tint(tool))
    }
}

/// 자세히: a chevron and the card's long lines, folded until opened.
private struct Details: View {
    let lines: [LocalizedStringKey]
    let k: CGFloat
    @State var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(DesktopKit.reduceMotion ? nil : .easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9 * k, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("자세히").font(.system(size: 11 * k, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? L("펼침") : L("접힘"))
            if open {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(.system(size: 11 * k)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One 데스크톱 친구 card, for its colour (AppPalette.tint) and its hello.
enum DesktopTool: Int, CaseIterable {
    case cursor, hanging, meadow, rug, weather, focus, quickAsk
}

/// 꾸미기 > 색 테마 (AppSettings.palette). Raw values are saved; never rename one. 딸기우유 is the sticker book (a
/// pastel per card), the others wash every card in their own colour, 기본 keeps the plain grey groups.
enum AppPalette: String, CaseIterable {
    case strawberry, mint, lavender, lemon, sky, plain

    var label: String {
        switch self {
        case .strawberry: return L("딸기우유")
        case .mint: return L("민트")
        case .lavender: return L("라벤더")
        case .lemon: return L("레몬")
        case .sky: return L("하늘")
        case .plain: return L("기본")
        }
    }

    var accent: Color? {
        switch self {
        case .strawberry: return WeatherArt.color("#FF7EA8")
        case .mint: return WeatherArt.color("#3EC48F")
        case .lavender: return WeatherArt.color("#9D86EE")
        case .lemon: return WeatherArt.color("#EDBE2B")
        case .sky: return WeatherArt.color("#5AAEF5")
        case .plain: return nil
        }
    }

    func tint(_ tool: DesktopTool) -> Color? {
        switch self {
        case .strawberry: return WeatherArt.color(Self.stickers[tool.rawValue])
        case .plain: return nil
        default: return accent
        }
    }

    /// 딸기우유's card colours in DesktopTool order: peach, lavender, mint, pink, sky, lemon, coral.
    static let stickers = ["#FF9F6B", "#A88BF0", "#4FC98E", "#FF7EB3", "#5AAEF5", "#F2C230", "#FF8577"]
}


/// 그림 스타일 as one segmented row and what it does; 캐릭터 선택 and 데스크톱 친구 both show it.
struct RenderStylePicker: View {
    @ObservedObject var settings: AppSettings = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("그림 스타일", selection: $settings.renderStyle) {
                ForEach(RenderStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .font(.system(size: 11))
            Text(settings.renderStyle.note).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// Lays its one child out at full size but takes `scale` of the room: pair it with `.scaleEffect(scale)` on the child
/// (scaleEffect alone keeps the full-size frame). 설정's 퀵물어보기 preview.
struct Shrink: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}
