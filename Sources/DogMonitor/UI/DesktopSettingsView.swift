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

/// "데스크톱 친구" in 설정: one panel per friend, changes show at once.
/// Sections in order: 커서 친구 / 대롱대롱 친구 / 풀밭 친구들 / 바탕화면 러그 / 날씨 창문 / 집중 타이머 / 그림 스타일.
struct DesktopSettingsView: View {
    @ObservedObject var store: MotionStore = .shared
    @ObservedObject var hanging: HangingStore = .shared
    @ObservedObject var meadow: MeadowStore = .shared
    @ObservedObject var rug: RugStore = .shared
    @ObservedObject var focus: FocusCenter = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("데스크톱 친구").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            cursorSection
            hangingSection
            meadowSection
            rugSection
            weatherSection
            focusSection
            styleSection
        }
    }

    // MARK: 커서 친구

    private var cursorSection: some View {
        Panel {
            HStack {
                Text("커서 친구").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("커서 친구", isOn: $store.cursorBuddy)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("커서를 움직이면 걸어서 따라오고, 커서가 멀리 가면 뛰어와요. 멈추면 곁에서 기다리다 가끔 혼자 놀고, 충전 중엔 밥을 먹어요. 한동안 손을 안 대면 낮잠을 자요. (macOS는 시스템 커서 자체를 바꾸지 못하게 해서 따라다니는 친구로 만들었어요)")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("크기").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("크기", selection: $store.buddySize) {
                        ForEach(BuddySize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                GridRow {
                    Text("빠르게 움직이면").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("빠르게 움직이면", selection: $store.buddyBoost) {
                        ForEach(BuddyBoost.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                }
                GridRow {
                    Text("혼자 놀기").font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("혼자 놀기", isOn: $store.buddyPlay).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Text("혼자 놀기를 켜 두면 가끔 맨 앞 창의 위쪽 끝에 올라가 앉고, 나비를 쫓거나 커서에 매달리기도 해요. 앉을 자리는 창의 위치만 보고 찾아요. 창 안의 내용은 보지 않아요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("마우스를 휙 돌리면 커지고 기울어요. 마구 흔들면 어지러워해요. 한 번 누르면 반가워하고, 두 번 누르면 AI 비서가 열려요. 잡아 끌 수도 있고, 오른쪽 클릭은 메뉴예요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 대롱대롱 친구

    private var hangingSection: some View {
        Panel {
            HStack {
                Text("대롱대롱 친구").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("대롱대롱 친구", isOn: $hanging.prefs.on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("메뉴바 바로 아래 줄에 매달려 흔들려요. 잡아서 던지면 줄이 늘었다 튕기고, 누르면 풍경 소리가 나요. 끌어다 놓고 잠깐 멈췄다 놓으면 그 자리, 그 줄 길이로 다시 매달아요. 다른 화면으로 끌어 옮길 수도 있어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hanging.prefs.on { hangingOptions }
        }
    }

    @ViewBuilder private var hangingOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                Text("몇 명").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("몇 명", selection: $hanging.prefs.count) {
                    ForEach(1...HangPrefs.maxCount, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 170, alignment: .leading)
            }
            GridRow {
                Text("바람").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("바람", selection: $hanging.prefs.wind) {
                    ForEach(WindLevel.allCases.filter { $0 != .local || HangingFriends.localWind != nil }, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 170, alignment: .leading)
            }
            if hanging.prefs.wind == .local && !weather.on {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("날씨 창문을 켜 두면 그 도시 바람을 따라요. 지금은 산들바람이에요")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Text("풍경 소리").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Toggle("풍경 소리", isOn: $hanging.prefs.sound).labelsHidden().controlSize(.small)
                    Slider(value: $hanging.prefs.volume, in: 0...1).frame(width: 90).disabled(!hanging.prefs.sound)
                    Button("들어보기") { HangingFriends.preview(Int.random(in: 0..<HangPrefs.maxCount)) }
                        .controlSize(.small).disabled(!hanging.prefs.sound)
                }
            }
            GridRow {
                Text("항상 위").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("다른 창보다 위에 두기", isOn: $hanging.prefs.onTop).controlSize(.small).font(.system(size: 11))
            }
            GridRow {
                Text("줄 느낌").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("줄 느낌", selection: $hanging.prefs.feel) {
                    ForEach(StringFeel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 170, alignment: .leading)
            }
            GridRow {
                Text("매다는 곳").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("화면 맨 위에서 매달기 (메뉴바 너머로 줄이 보여요)", isOn: $hanging.prefs.fromTop).controlSize(.small).font(.system(size: 11))
            }
            GridRow {
                Text("스치면").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("커서가 스치면 흔들기", isOn: $hanging.prefs.pokeOnHover).controlSize(.small).font(.system(size: 11))
            }
        }
        ForEach(0..<min(hanging.prefs.count, hanging.prefs.slots.count), id: \.self) { i in
            HStack(spacing: 6) {
                Text(verbatim: "\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
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
        Panel {
            HStack {
                Text("풀밭 친구들").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("풀밭 친구들", isOn: $meadow.prefs.on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("화면 아래쪽, 독 바로 위에 친구들이 모여 살아요. 제자리에서 통통 뛰고, 가끔 산책하거나 앉아 쉬어요. 누르면 그 친구 위에 퀵물어보기가 열리고, 잡아서 들었다 놓으면 툭 떨어져요. 창을 띄우면 그 뒤로 숨어요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if meadow.prefs.on {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    GridRow {
                        Text("몇 명").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("몇 명", selection: $meadow.prefs.count) {
                            ForEach(1...MeadowPrefs.maxCount, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200, alignment: .leading)
                    }
                    GridRow {
                        Text("항상 위").font(.system(size: 11)).foregroundStyle(.secondary)
                        Toggle("다른 창보다 위에 두기", isOn: $meadow.prefs.onTop).controlSize(.small).font(.system(size: 11))
                    }
                }
                ForEach(0..<min(meadow.prefs.count, meadow.prefs.slots.count), id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(i + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                        whoPicker(who($meadow.prefs.slots, i, copy: "meadow"))
                    }
                }
            }
        }
    }

    // MARK: 바탕화면 러그

    private var rugSection: some View {
        Panel {
            HStack {
                Text("바탕화면 러그").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("바탕화면 러그", isOn: $rug.prefs.on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("바탕화면에 작은 천 러그를 깔아요. 가장자리를 잡아 끌면 접혀 넘어가며 뒷면이 보이고, 가운데를 이리저리 문지르면 주름이 생겨 그대로 남아요. 두 번 누르거나 오른쪽 클릭의 '빳빳하게 펼치기'로 다시 펴요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rug.prefs.on {
                HStack(spacing: 8) {
                    Text("부드러움").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("부드러움", selection: $rug.prefs.softness) {
                        ForEach(RugSoftness.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 170)
                    Button("펼치기") { DesktopRug.shared.smooth() }.controlSize(.small)
                }
            }
        }
    }

    // MARK: 집중 타이머

    private var focusSection: some View {
        Panel {
            HStack {
                Text("집중 타이머").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(focus.running ? "그만하기" : "집중 시작") {
                    if focus.running { focus.stop() } else { focus.start() }
                }
                .controlSize(.small)
            }
            Text("집중하는 동안 친구 머리 위에 시간이 올라가고, 친구는 책상에 앉아 공부해요. 오늘 할 일이 있으면 첫 번째 일을 '진행 중'으로 보여 주고, 체크하면 미리알림에서도 끝낸 일로 바꿔요. 메뉴바 메뉴나 AI 비서에게 '집중 시작'이라고 해도 돼요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("메뉴바에 시간 보이기", isOn: $focus.showInMenuBar).font(.system(size: 11))
        }
    }

    // MARK: 날씨 창문

    @ObservedObject private var weather: WeatherWindow = .shared
    @ObservedObject private var forecast: WeatherService = .shared

    private var weatherSection: some View {
        Panel {
            HStack {
                Text("날씨 창문").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("날씨 창문", isOn: $weather.on).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("고른 도시의 지금 날씨 속에서 캐릭터가 지내는 작은 창문이에요. 빈 곳을 끌면 옮겨지고, 오른쪽 클릭으로 미리보기와 위치 초기화를 할 수 있어요. 켜 두면 아침에 우산이나 겉옷 이야기를 하루 한 번 해 줘요.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("도시").font(.system(size: 11)).foregroundStyle(.secondary)
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
                GridRow {
                    Text("크기").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("크기", selection: $weather.sizeStep) {
                        ForEach(WeatherFrame.scales.indices, id: \.self) { Text("\(Int(WeatherFrame.scales[$0] * 100))%").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Toggle("항상 위에 두기", isOn: $weather.onTop).font(.system(size: 11))
            Text("날씨 정보: MET Norway (CC BY 4.0)").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: 그림 스타일

    private var styleSection: some View {
        Panel {
            Text("그림 스타일").font(.system(size: 12, weight: .semibold))
            RenderStylePicker().labelsHidden()   // the panel title above already says 그림 스타일
            Text("메뉴바, 커서 친구, 대롱대롱 친구, 날씨 창문이 모두 같은 그림체로 바뀌어요")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
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
