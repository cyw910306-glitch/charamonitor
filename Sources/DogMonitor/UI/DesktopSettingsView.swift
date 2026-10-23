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
            DesktopToggle(title: L("폴더 친구"), isOn: { FolderStore.shared.prefs.on }, set: { FolderStore.shared.prefs.on = $0 }),
            DesktopToggle(title: L("바탕화면 러그"), isOn: { RugStore.shared.prefs.on }, set: { RugStore.shared.prefs.on = $0 }),
            DesktopToggle(title: L("복제 친구"), isOn: { CloneStore.shared.prefs.on }, set: { CloneStore.shared.prefs.on = $0 }),
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
/// Sections in order: 꾸미기 / 커서 친구 / 복제 친구 / 대롱대롱 친구 / 풀밭 친구들 / 폴더 친구 / 놀이 / 장난감 상자 / 맥과 같이 놀기 /
/// 바탕화면 러그 / 날씨 창문 / 집중 타이머 / 퀵물어보기 / 후원 친구 (the direct build).
struct DesktopSettingsView: View {
    @ObservedObject var store: MotionStore = .shared
    @ObservedObject var hanging: HangingStore = .shared
    @ObservedObject var meadow: MeadowStore = .shared
    @ObservedObject var folder: FolderStore = .shared
    @ObservedObject var folderIcons: FolderIcons = .shared
    @ObservedObject var rug: RugStore = .shared
    @ObservedObject var clones: CloneStore = .shared
    @ObservedObject var toys: ToyStore = .shared
    @ObservedObject var focus: FocusCenter = .shared
    @ObservedObject var settings: AppSettings = .shared
    @AppStorage(PlayMode.twoPlayerKey, store: AppDefaults.store) private var twoPlayer = false
    @AppStorage(StarRules.bestKey, store: AppDefaults.store) private var bestStars = 0
    @ObservedObject var games: ClickGames = .shared
    @AppStorage(GroupDance.key, store: AppDefaults.store) private var groupDance = false
    @StateObject private var quickSample = FriendQuickAsk.sample()
    /// 후원 선물 that are open show up in the pickers below.
    @ObservedObject var gifts: SponsorGifts = .shared
    #if !MAS
    @ObservedObject var sponsor: SponsorCenter = .shared
    /// QA renders only: just the 후원 친구 card.
    var sponsorOnly = false
    #endif
    /// The card that just said hi (a friend switched on) and whose badge is hopping.
    @State private var hello: DesktopTool?
    @State private var hop: DesktopTool?
    @State private var heroHop = false

    var body: some View {
        #if !MAS
        if sponsorOnly { sponsorSection } else { cards }
        #else
        cards
        #endif
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            decorSection
            PluginsSection()
            cursorSection
            clonesSection
            hangingSection
            meadowSection
            folderSection
            playSection
            toysSection
            macSection
            rugSection
            weatherSection
            focusSection
            quickAskSection
            #if !MAS
            sponsorSection
            #endif
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
                    row("누르면 소리") {
                        HStack(spacing: 6) {
                            onOff("누르면 소리", $store.buddyCry, .cursor)
                            Slider(value: $store.buddyCryVolume, in: 0...1).frame(width: 90).controlSize(.small).disabled(!store.buddyCry)
                            Button("들어 보기") { FriendCry.play(.normal, friend: "preview", preview: true) }
                                .controlSize(.small).disabled(!settings.friendSounds)
                        }
                    }
                }
                details("커서를 움직이면 걸어서 따라오고, 커서가 멀리 가면 뛰어와요. 멈추면 곁에서 기다리다 가끔 혼자 놀고, 충전 중엔 밥을 먹어요. 한동안 손을 안 대면 낮잠을 자요.",
                        "혼자 놀기를 켜 두면 가끔 맨 앞 창의 위쪽 끝에 올라가 앉고, 나비를 쫓거나 커서에 매달리기도 해요. 앉을 자리는 창의 위치만 보고 찾아요. 창 안의 내용은 보지 않아요.",
                        "마우스를 휙 돌리면 커지고 기울어요. 마구 흔들면 어지러워해요. 누를 때마다 여러 가지로 반응하고, 연달아 누르면 어질어질하다 삐쳐요. 꾸욱 누르고 있다 놓으면 폴짝 뛰고, 잡아서 휙 던지면 날아갔다 다시 돌아와요. ⌥ 누른 채 클릭하면 퀵물어보기, AI 비서와 메뉴는 오른쪽 클릭이에요.",
                        "누르면 소리를 켜면 누를 때마다 강아지는 멍, 고양이는 야옹, 다른 캐릭터는 저마다 다른 목소리로 울어요. 복제 친구, 풀밭 친구, 폴더 친구도 같이 울어요. 캐릭터 팩의 sounds 폴더나 내 캐릭터 꾸미기에서 넣은 소리 파일이 있으면 그 소리를 내요. 꾸미기의 효과음을 끄거나 말풍선을 잠시 끄면 조용해요.",
                        "macOS는 시스템 커서 자체를 바꾸지 못하게 해서 따라다니는 친구로 만들었어요.")
            }
        }
    }

    // MARK: 복제 친구

    private var clonesSection: some View {
        let n = clones.prefs.clones.count
        return Panel(tint: tint(.clones, on: clones.prefs.on)) {
            header("👯", "복제 친구", .clones, isOn: $clones.prefs.on)
            tagline("커서 친구를 복사해 바탕화면을 꾸며요")
            if clones.prefs.on {
                VStack(alignment: .leading, spacing: 7) {
                    row("몇 명") {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(n)/\(ClonePrefs.maxCount)").font(f(12)).monospacedDigit()
                            Button("하나 더") {
                                guard let r = NSScreen.screens.first?.visibleFrame else { return }
                                DesktopClones.shared.add(at: CGPoint(x: .random(in: r.minX + 80...r.maxX - 80), y: .random(in: r.minY...r.minY + r.height * 0.4)))
                            }
                            .controlSize(.small).disabled(n >= ClonePrefs.maxCount)
                            Button("모두 치우기") { clones.prefs.clones = [] }.controlSize(.small).disabled(n == 0)
                        }
                    }
                    row("움직이기") { onOff("움직이기", $clones.prefs.moves, .clones) }
                    row("어울리기") { onOff("어울리기", $clones.prefs.interacts, .clones) }
                    row("술래잡기") { onOff("술래잡기", $clones.prefs.tag, .clones).disabled(!clones.prefs.interacts || !clones.prefs.moves) }
                    row("기차놀이") { onOff("기차놀이", $clones.prefs.train, .clones).disabled(!clones.prefs.interacts || !clones.prefs.moves) }
                    row("단체 춤") { onOff("단체 춤", $groupDance, .clones) }
                }
                details("커서 친구를 오른쪽 클릭해서 '복제해서 바탕화면에 두기'를 누르면 똑같은 친구가 바탕화면에 생겨요. 8명까지 두고, 다시 켜도 그 자리에 있어요.",
                        "혼자 산책하고 앉고 낮잠도 자요. 어울리기를 켜 두면 서로 인사하거나 쫓아다니고, 커서를 쳐다보거나 달려오고, 러그가 있으면 올라가 앉아요.",
                        "누르면 반응하고, 잡아서 옮기거나 휙 던질 수 있어요. 움직이기를 끄면 놓은 자리 그대로 장식이 돼요. 오른쪽 클릭으로 한 명씩 치울 수 있어요.",
                        "친구들끼리 놀기도 해요. 술래잡기를 켜면 가끔 한 명이 술래가 되어 20초 동안 쫓아다니고, 기차놀이를 켜면 커서 친구 뒤에 줄줄이 붙어 따라가요. 둘 다 어울리기가 켜져 있어야 하고, 오른쪽 클릭 메뉴로 바로 시작할 수도 있어요.",
                        "단체 춤을 켜 두면 춤춰 줘·응원해 줘를 누르거나 집중을 잘 마쳤을 때처럼 축하할 일이 생기면 모든 친구가 10초 동안 같이 춤춰요.")
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
                    row("줄넘기") { onOff("줄넘기", $meadow.prefs.jumpRope, .meadow).disabled(meadow.prefs.count < 3) }
                    row("단체 춤") { onOff("단체 춤", $groupDance, .meadow) }
                }
                ForEach(0..<min(meadow.prefs.count, meadow.prefs.slots.count), id: \.self) { i in
                    HStack(spacing: 6) {
                        slotNumber(i, .meadow)
                        whoPicker(who($meadow.prefs.slots, i, copy: "meadow"))
                    }
                }
                details("화면 아래쪽, 독 바로 위에 친구들이 모여 살아요. 제자리에서 통통 뛰고, 가끔 산책하거나 앉아 쉬어요. 누르면 포즈를 바꾸며 말을 걸고 옆 친구도 돌아봐요. 여러 번 누르면 어지러워하다 삐지고, 커서로 문지르면 쓰다듬어져요. ⌥ 누른 채 클릭하면 퀵물어보기가 열리고, 잡아서 들었다 놓으면 툭 떨어져요. 창을 띄우면 그 뒤로 숨어요.",
                        "줄넘기를 켜 두면 세 명 이상일 때 가끔 양 끝 두 친구가 줄을 돌리고 나머지가 박자 맞춰 뛰어요. 열 번 연속 넘으면 다 같이 기뻐해요. 오른쪽 클릭 메뉴로 바로 시작할 수도 있어요.")
            }
        }
    }

    // MARK: 폴더 친구

    private var folderSection: some View {
        Panel(tint: tint(.folder, on: folder.prefs.on)) {
            header("📁", "폴더 친구", .folder, isOn: $folder.prefs.on)
            tagline("바탕화면 폴더와 Finder 창 위에 올라앉아요")
            #if !MAS
            folderIconRow
            #endif
            if folder.prefs.on {
                VStack(alignment: .leading, spacing: 7) {
                    row("크기") {
                        Picker("크기", selection: $folder.prefs.size) {
                            ForEach(BuddySize.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                    row("창마다") { onOff("창마다 한 명씩", $folder.prefs.everyWindow, .folder) }
                }
                details("지금 고른 캐릭터가 맨 앞 Finder 창의 위쪽 끝에 올라앉아요. 창 끝에 서서 콩콩 들썩이다가, 낮잠도 자고, 두리번거리고, 가끔 창 끝을 따라 걸어요. 창을 끌어 옮기면 꼭 붙어서 같이 가고, 창을 닫거나 내리면 폴짝 뛰어내려요.",
                        "창마다를 켜면 열린 Finder 창마다 한 명씩, 세 개 창까지 올라가요. 다른 창이 가리거나 창이 메뉴바에 붙어 자리가 없으면 잠깐 숨어요.",
                        "누르면 반응하고 말을 걸어요. ⌥ 누른 채 클릭하면 퀵물어보기, 오른쪽 클릭은 메뉴예요. 창의 위치와 크기만 보고, 창 이름이나 안의 내용은 보지 않아서 권한이 필요 없어요.")
            }
        }
    }

    // MARK: 놀이

    /// 놀이 모드: no switch of its own, a session starts from the button or a friend's menu.
    private var playSection: some View {
        Panel(tint: palette.tint(.play)) {
            HStack(spacing: 8) {
                badge("🎮", "놀이", .play)
                Spacer()
                Button("놀이 모드 시작") { PlayMode.shared.start() }.controlSize(.small)
            }
            tagline("친구를 키보드로 움직여 창 위를 폴짝폴짝 뛰어다녀요")
            row("둘이 놀기") { onOff("둘이 놀기", $twoPlayer, .play) }
            row("미니 게임") {
                Button("별 줍기") { StarGame.shared.start(duel: false) }.controlSize(.small)
                Button("2인 대결") { StarGame.shared.start(duel: true) }.controlSize(.small)
                if bestStars > 0 { Text("최고 기록 \(bestStars)개").font(f(12)).foregroundStyle(.secondary) }
            }
            details("← →로 걷고, Shift를 같이 누르면 뛰어요. ↑로 점프하고, 공중에서 한 번 더 누르면 2단 점프예요. ↓로 웅크리고, ↓ 누른 채 ↑를 누르면 창 아래로 내려가요. Esc를 누르면 끝나요.",
                    "화면 아래(독 위), 열린 창의 위쪽 끝, 바탕화면 러그 위에 올라설 수 있어요. 아래에서 뛰어오르면 창 끝을 지나 올라가요. 다른 곳을 클릭하거나 다른 앱으로 넘어가도 끝나요.",
                    "놀이 기술 플러그인이 열려 있으면: ↑를 꾹 누르면 하늘을 날아요(1.5초, 땅에 서면 다시 차요). ↑를 빠르게 두 번 누르면 높이 점프, ← 나 →를 빠르게 두 번 누르면 손을 뗄 때까지 대시예요.",
                    "둘이 놀기를 켜면 색이 다른 친구가 하나 더 나와요. A·D로 걷고 W로 점프, S로 웅크려요. W 꾹, W 두 번, A·D 두 번도 똑같이 돼요.",
                    "별 줍기는 60초 동안 창 위, 화면 아래, 공중에 뜬 별을 모아요. 🍪는 3점이고, 높이 뜬 별은 2단 점프로 닿아요. 2인 대결은 둘이 같이 모아서 많이 모은 쪽이 이겨요.",
                    "커서 친구나 복제 친구를 오른쪽 클릭해서 놀이 모드를 고를 수도 있어요. 키보드는 놀이하는 동안에만 받고, 창은 위치와 크기만 봐서 권한이 필요 없어요.")
            row("클릭 놀이") {
                HStack(spacing: 6) {
                    ForEach(ClickGames.Kind.allCases, id: \.self) { g in
                        Button(games.playing == g ? L("그만하기") : g.title) { games.toggle(g) }.controlSize(.small)
                    }
                }
            }
            details("숨바꼭질: 친구가 창 뒤나 독 뒤에 숨어서 머리만 빼꼼 내밀어요. 보이는 부분을 누르면 찾은 거예요. 15초가 지나면 힌트를 주고, 세 판을 해요.",
                    "공놀이: 공을 끌어서 던지면 친구가 달려가 물어 와요. 한 번 누르면 공을 톡 차올려요. 바탕화면 러그 위에 공이 멈추면 골이에요.",
                    "두더지잡기: 30초 동안 독 위로 튀어나오는 친구를 눌러요. 풀밭 친구들이 켜져 있으면 그 친구들이 나와요. 최고 점수를 기억해요.",
                    "게임 조각을 오른쪽 클릭해서 그만할 수 있어요. 마우스로만 놀아서 키보드를 받지 않아요.")
        }
    }

    // MARK: 장난감 상자

    /// A switch per toy (on: one is out, off: all of that kind go back in the box), 하나 더 up to 6 in all, 정리하기.
    private var toysSection: some View {
        let n = toys.prefs.toys.count
        return Panel(tint: tint(.toys, on: toys.prefs.on)) {
            header("🧸", "장난감 상자", .toys, isOn: Binding(get: { toys.prefs.on }, set: { on in
                var p = toys.prefs
                p.on = on
                if on, p.toys.isEmpty { p.add(.trampoline); p.add(.ball) }   // an empty box opens with two out
                toys.prefs = p
            }))
            tagline("바탕화면에 장난감을 꺼내 두면 친구들이 놀러 와요")
            if toys.prefs.on {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(ToyKind.allCases.filter { toys.prefs.has($0) || $0.isOffered }, id: \.self) { kind in
                        row(LocalizedStringKey(kind.label)) {
                            HStack(spacing: 8) {
                                onOff(LocalizedStringKey(kind.label), Binding(get: { toys.prefs.has(kind) }, set: { on in
                                    if on { toys.prefs.add(kind) } else { toys.prefs.toys.removeAll { $0.kind == kind } }
                                }), .toys)
                                .disabled(n >= ToyPrefs.maxCount && !toys.prefs.has(kind))
                                if toys.prefs.has(kind) {
                                    Button("하나 더") { toys.prefs.add(kind) }.controlSize(.small).disabled(n >= ToyPrefs.maxCount)
                                }
                            }
                        }
                    }
                    row("몇 개") {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(n)/\(ToyPrefs.maxCount)").font(f(12)).monospacedDigit()
                            Button("정리하기") { toys.prefs.toys = [] }.controlSize(.small).disabled(n == 0)
                        }
                    }
                }
                details("트램펄린, 공, 쿠션, 미끄럼틀을 바탕화면에 꺼내 둬요. 모두 합쳐 6개까지이고, 끌어서 옮기면 다시 켜도 그 자리에 있어요. 누르면 통통 튀거나 데굴데굴 굴러가고, 오른쪽 클릭으로 하나씩 치워요.",
                        "커서 친구와 복제 친구가 가끔 놀러 와서 트램펄린에서 뛰고, 공을 차고 쫓아가고, 쿠션에서 낮잠을 자고, 미끄럼틀을 타요. 복제 친구는 어울리기가 켜져 있을 때 놀러 와요.",
                        "놀이 모드에서는 장난감 위에도 올라설 수 있어요. 트램펄린은 아주 높이 튕겨 주고, 쿠션은 폭신하게 받아 주고, 미끄럼틀은 아래로 태워 줘요.")
            }
        }
    }

    // MARK: 맥과 같이 놀기

    /// MacReactions: three switches of their own, all off at first.
    private var macSection: some View {
        Panel(tint: tint(.mac, on: store.macDownloads || store.macTrash || store.macBusy)) {
            HStack(spacing: 8) {
                badge("💻", "맥과 같이 놀기", .mac)
                Spacer()
            }
            tagline("맥에서 생긴 일에 친구가 같이 반응해요")
            VStack(alignment: .leading, spacing: 7) {
                #if !MAS
                row("다운로드 배달") { onOff("다운로드 배달", $store.macDownloads, .mac) }
                row("휴지통") { onOff("휴지통", $store.macTrash, .mac) }
                #endif
                row("바쁜 맥") { onOff("바쁜 맥", $store.macBusy, .mac) }
            }
            #if MAS
            details("바쁜 맥: CPU가 20초 넘게 바쁘면 커서 친구가 땀을 흘리며 맨 앞 창 옆에서 영차영차 밀어요. 커서를 움직이면 따라오고, 맥이 한가해지면 그만해요. 복제 친구도 땀을 흘려요.")
            #else
            details("다운로드 배달: 다운로드 폴더에 파일이 다 받아지면 커서 친구가 그 파일 아이콘을 머리에 이고 화면 오른쪽 아래로 날라 줘요. 받는 중인 파일은 다 받아질 때까지 기다려요. 처음 켤 때 다운로드 폴더를 봐도 되는지 물어볼 수 있고, 허용하지 않으면 조용히 쉬어요.",
                    "휴지통: 휴지통을 비우면 커서 친구가 작은 쓰레기 봉투를 화면 밖으로 뻥 차 버려요. 휴지통 안은 보지 않고 몇 개 들었는지만 봐서 권한이 필요 없어요.",
                    "바쁜 맥: CPU가 20초 넘게 바쁘면 커서 친구가 땀을 흘리며 맨 앞 창 옆에서 영차영차 밀어요. 커서를 움직이면 따라오고, 맥이 한가해지면 그만해요.",
                    "복제 친구도 같이 폴짝 뛰고 땀을 흘려요.")
            #endif
        }
    }

    #if !MAS
    /// 폴더 아이콘: the character on the folders' own icons; works with the 폴더 친구 switch off too.
    private var folderIconRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("모양") {
                Picker("모양", selection: $folder.prefs.iconStyle) {
                    ForEach(FolderIconStyle.offered(current: folder.prefs.iconStyle), id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            row("폴더 아이콘") {
                HStack(spacing: 6) {
                    Button("바탕화면 폴더에 입히기") { FolderIcons.shared.dress(FolderIcons.desktopFolders()) }
                    Button("폴더 고르기…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                        p.prompt = L("입히기")
                        NSApp.activate(ignoringOtherApps: true)
                        if p.runModal() == .OK { FolderIcons.shared.dress(p.urls) }
                    }
                    if !folderIcons.dressed.isEmpty { Button("원래대로") { FolderIcons.shared.undress() } }
                }
                .controlSize(.small)
            }
            if folderIcons.dressed.isEmpty {
                details("폴더 친구를 켜면 바탕화면 폴더 아이콘 위에 지금 고른 캐릭터가 올라가요. 새로 만든 폴더에도 올라가고, 끄면 원래대로 돌아가요. 다른 폴더는 폴더 고르기로 입혀요.",
                        "직접 바꿔 둔 폴더 아이콘은 건드리지 않아요.")
            } else {
                details("폴더 \(folderIcons.dressed.count)개에 캐릭터가 올라가 있어요. 원래대로를 누르면 원래 폴더 아이콘으로 돌아가요.",
                        "직접 바꿔 둔 폴더 아이콘은 건드리지 않아요.")
            }
        }
    }
    #endif

    // MARK: 바탕화면 러그

    private var rugSection: some View {
        Panel(tint: tint(.rug, on: rug.prefs.on)) {
            header("🧶", "바탕화면 러그", .rug, isOn: $rug.prefs.on)
            tagline("접고 구기는 작은 천 러그")
            if rug.prefs.on {
                row("그림") {
                    Picker("그림", selection: $rug.prefs.face) {
                        ForEach(RugFace.offered(current: rug.prefs.face), id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                }
                row("러그 색") {
                    HStack(spacing: 6) {
                        ForEach(FocusTheme.offered(current: rug.prefs.color), id: \.self) { t in
                            swatch(t, chosen: rug.prefs.color == t) { rug.prefs.color = t }
                        }
                        Text(rug.prefs.color.label).font(f(11)).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                }
                row("크기") {
                    Picker("크기", selection: $rug.prefs.size) {
                        ForEach(RugSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
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
                details("바탕화면에 작은 천 러그를 깔아요. 그림을 '캐릭터'로 두면 지금 고른 친구가 러그 가운데에 크게 들어가고, 마름모·줄무늬·체크·물방울 무늬도 골라요. 러그 색은 어떤 그림에도 입혀지고, 크기는 네 단계로 바꿔요. 가장자리를 잡아 끌면 접혀 넘어가며 뒷면이 보이고, 가운데를 이리저리 문지르면 주름이 생겨 그대로 남아요. 두 번 누르거나 오른쪽 클릭의 '빳빳하게 펼치기'로 다시 펴요.")
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
                        ForEach(FocusTheme.offered(current: focus.theme), id: \.self) { t in swatch(t, chosen: focus.theme == t) { focus.theme = t } }
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
            tagline("머리 위 말풍선이 바로 답해 줘요")
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
            details("커서 친구·복제 친구·풀밭 친구·폴더 친구를 ⌥ 누른 채 클릭하면 말풍선이 떠요. 커서 친구, 풀밭 친구, 폴더 친구는 오른쪽 클릭 메뉴로도 돼요. AI 없이 바로 답해 줘요.")
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

    #if !MAS
    // MARK: 후원 친구

    /// On/off, how often, 오늘은 그만 and 지금 보기, the 후원 선물 grid, this Mac's counts and what is (not) sent.
    private var sponsorSection: some View {
        let s = sponsor.state, on = s.on
        let stopped = s.stoppedDay == SponsorRules.day(Date())
        return Panel(tint: tint(.sponsor, on: on)) {
            header("🎀", "후원 친구", .sponsor, isOn: $sponsor.state.on)
            tagline("가끔 친구가 천을 덮은 액자를 들고 와요. 열어 보면 제작자 서비스 소개가 나오고 꾸미기 선물이 열려요")
            VStack(alignment: .leading, spacing: 7) {
                row("얼마나 자주") {
                    Picker("얼마나 자주", selection: $sponsor.state.frequency) {
                        ForEach(SponsorFrequency.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).disabled(!on)
                }
                row("오늘") {
                    HStack(spacing: 6) {
                        Button(stopped ? "오늘은 쉬어요" : "오늘은 그만") { sponsor.stopToday() }.controlSize(.small).disabled(stopped || !on)
                        Button("지금 보기") { sponsor.showNow() }.controlSize(.small)
                    }
                }
            }
            giftGrid
            Text("후원 친구를 보면 하나씩 열려요 (\(gifts.openCount)/\(SponsorGift.allCases.count)) · 하루 2개까지")
                .font(f(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("기록") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("보여 준 \(s.stats.offers) · 열어 본 \(s.stats.opens) · 끝까지 본 \(s.stats.completes) · 눌러 본 \(s.stats.clicks)")
                        .font(f(11)).monospacedDigit()
                    Text("이 숫자는 이 맥에만 있어요").font(f(10)).foregroundStyle(.secondary)
                }
            }
            details("후원 친구는 제작자가 만든 다른 서비스를 소개해요. 기기 ID나 기록은 밖으로 나가지 않아요. 앱을 켤 때와 하루 한 번 이 사이트에서 서명된 소개 목록만 받아요. 버튼을 누를 때만 그 서비스가 열리고, 제작자의 그 서비스가 IP와 캐릭모니터에서 왔다는 표시(utm)를 받아요.",
                    "전체 화면, 집중 중, 놀이 중, 화면이 잠겼을 때, 2분 넘게 자리를 비웠을 때, 회의나 화면 공유·녹화 중에는 오지 않아요. 세 번 그냥 보내면 더 드물게 와요.")
        }
    }

    /// The gifts in their order, four to a row: open ones with where they are, locked ones as a grey silhouette.
    private var giftGrid: some View {
        let all = SponsorGift.allCases, accent = palette.tint(.sponsor) ?? Color.accentColor
        return VStack(spacing: 6) {
            ForEach(Array(stride(from: 0, to: all.count, by: 4)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(all[start..<min(start + 4, all.count)], id: \.self) { g in giftTile(g, accent: accent) }
                }
            }
        }
    }

    private func giftTile(_ g: SponsorGift, accent: Color) -> some View {
        let open = gifts.isOpen(g)
        return VStack(spacing: 2) {
            ZStack {
                Text(verbatim: g.emoji).font(.system(size: 18 * k))
                    .saturation(open ? 1 : 0).opacity(open ? 1 : 0.22)
                if !open { Text(verbatim: "?").font(.system(size: 13 * k, weight: .heavy, design: .rounded)).foregroundStyle(.secondary) }
            }
            Text(verbatim: open ? g.label : gifts.next == g ? L("다음 선물") : L("잠겨 있어요"))
                .font(.system(size: 10 * k, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(open ? Color.primary : Color.secondary)
            Text(verbatim: open ? g.place : " ").font(.system(size: 9 * k)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open ? accent.opacity(0.18) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(open ? accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(open ? "\(g.label), \(g.place)" : L("잠긴 선물"))
    }
    #endif

    // MARK: 날씨 창문

    @ObservedObject private var weather: WeatherWindow = .shared
    @ObservedObject private var forecast: WeatherService = .shared

    private var weatherSection: some View {
        Panel(tint: tint(.weather, on: weather.on)) {
            header("⛅", "날씨 창문", .weather, isOn: $weather.on)
            tagline("그 도시 날씨를 담은 작은 수정구슬")
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
                    row("받침 색") {
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
                details("고른 도시의 지금 날씨 속에서 캐릭터가 지내는 작은 수정구슬이에요. 클릭하면 깡총 뛰며 날씨에 맞게 반응하고, 구슬을 끌면 옮겨져요. 오른쪽 클릭으로 미리보기와 위치 초기화를 할 수 있어요. 켜 두면 아침에 우산이나 겉옷 이야기를 하루 한 번 해 줘요.")
                Text("날씨 정보: MET Norway (CC BY 4.0)").font(f(10)).foregroundStyle(.tertiary)
            }
        }
    }

    /// One 받침 색: the stand's colour with its outline, ringed when chosen.
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
    case cursor, hanging, meadow, rug, weather, focus, quickAsk, clones, folder, play, toys, mac, sponsor
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

    /// 딸기우유's card colours in DesktopTool order: peach, lavender, mint, pink, sky, lemon, coral, aqua, folder blue, grape,
    /// caramel, teal, bubblegum.
    static let stickers = ["#FF9F6B", "#A88BF0", "#4FC98E", "#FF7EB3", "#5AAEF5", "#F2C230", "#FF8577", "#5EC4DE", "#6FA8F0", "#B57BE0",
                           "#E0A458", "#3FB8A9", "#F5A3C7"]
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
