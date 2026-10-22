import AppKit
import SwiftUI

/// "설정" page: menu bar and login options, motions, desktop friends, help and the source code link.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Extra motions the shown character has (the 상황별 모션 pickers list only these).
    var available: Set<ExtraMotion> = Set(ExtraMotion.allCases)
    let onBack: () -> Void
    @ObservedObject private var refine = AutoRefine.shared
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var helpReport: String?
    @State private var guide = false

    var body: some View {
        PageScaffold(title: L("설정"), onBack: onBack) {
            VStack(spacing: 8) {
                Panel {
                    switchRow(L("메뉴바에 CPU % 표시"), $settings.showCPUPercent)
                    Divider()
                    switchRow(L("로그인 시 자동 실행"), loginBinding)
                    if let loginError {
                        Text(loginError).font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                MotionSettingsView(available: available)
                DesktopSettingsView()
                if let destination = refine.destination {   // only while some AI can draw on this Mac
                    Panel {
                        HStack {
                            Text("AI 자동 다듬기").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Toggle("AI 자동 다듬기", isOn: $settings.aiAutoRefine)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        Text("켜 두면 새 캐릭터에 사진을 넣을 때 비워 둔 모습(자는·뛰는 모습)을 AI가 그려요. 이때 사진이 \(destination)로 보내져요. 처음에는 꺼져 있어요.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Panel {
                    linkRow(L("내 설정 내보내기…"), "square.and.arrow.up") { SetupFlow.exportPicked() }
                    Divider()
                    linkRow(L("내 설정 가져오기…"), "square.and.arrow.down") { SetupFlow.importPicked() }
                    Divider()
                    linkRow(L("가져오기 전 백업 보기…"), "clock.arrow.circlepath") { SetupFlow.showBackups() }
                    Text("내 맥끼리 설정을 옮기는 파일이에요. 직접 넣은 캐릭터와 매단 사진도 담기니 다른 사람에게는 조심해서 건네 주세요. 가져오기 전 상태는 최근 3개까지 백업에 남고, 백업 파일을 열면 그때로 돌아가요.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Panel {
                    linkRow(L("사용법 다시 보기"), "questionmark.bubble") {
                        guide = true
                    }
                    Divider()
                    linkRow(L("문제 보내기"), "ladybug") { helpReport = Diagnostics.report() }
                    Divider()
                    linkRow(L("소스 코드 (GitHub)"), "chevron.left.forwardslash.chevron.right") { External.open(AppInfo.repoURL) }
                }
                #if !MAS   // the App Store updates the App Store build
                UpdateCard()
                #endif
                Text("캐릭모니터 \(AppInfo.version) · 무료 비영리 오픈 소스")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .overlay { if let helpReport { HelpSheet(report: helpReport) { self.helpReport = nil } } }
        .overlay {
            if guide {
                GuideSheet(onTour: {
                    guide = false
                    NotificationCenter.default.post(name: .jellyClosePopover, object: nil)   // the bubble shows under the icon
                    // Once the popover is gone: a bubble under the icon would sit behind it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Tour.start(asked: true) }
                }, onClose: { guide = false })
            }
        }
    }

    private func linkRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { loginOn }, set: { on in
            do {
                try LoginItem.setEnabled(on)
                loginError = nil
            } catch {
                loginError = L("설정하지 못했어요: \(error.localizedDescription)")
            }
            loginOn = LoginItem.isEnabled
        })
    }
}

/// 문제 보내기: the whole report on screen first; 복사 and 메일로 보내기 send only what is shown (the mail its first
/// Diagnostics.mailLimit characters). The mail app opens with it; nothing goes until the owner presses send there.
struct HelpSheet: View {
    let report: String
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 10) {
                Text("문제 보내기").font(.system(size: 13, weight: .semibold))
                Text("보내는 내용은 아래가 전부예요. 대화·메모·메일·일정 내용과 키는 넣지 않아요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(report).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                HStack {
                    Button(copied ? L("복사했어요") : L("복사")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }
                    Button("메일로 보내기") { if let url = Diagnostics.mailURL(report) { External.open(url) } }
                    Spacer()
                    Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}

enum AppInfo {
    /// A bare `swift build` binary has no Info.plist; it shows the version scripts/build_app.sh stamps instead.
    static let unbundledVersion = "2.8.5"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? unbundledVersion }
    /// Where the source lives (PolyForm Noncommercial 1.0.0).
    static let repoURL = URL(string: "https://github.com/cyw910306-glitch/charamonitor")!
    static let licenseURL = URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")!
    /// LICENSE's Required Notice, word for word (never localized).
    static let requiredNotice = "Required Notice: Copyright 2026 원창연 (https://github.com/cyw910306-glitch)"
}

/// "꾸미기" page for whoever is selected: the dog's photo, name, colours and look options, an original's part
/// colours or a cat's coat colours. Changes apply and save immediately. A built-in
/// character other than the dog can be taken off 캐릭터 선택 here (restorable there).
struct CustomizeView: View {
    @ObservedObject var settings: AppSettings
    let sprites: SpriteHolder
    /// Current busyness, so the preview behaves exactly like the sprite in the menu bar.
    var load: Double = 0
    let onBack: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        PageScaffold(title: L("꾸미기"), onBack: onBack) {
            VStack(spacing: 8) {
                if let c = settings.activeOriginal { originalOptions(c) }
                else if let c = settings.activeCat { catOptions(c) }
                else { dogOptions }
                if let id = removableID { removeRow(id) }
            }
        }
        .alert("\(settings.characterName) 캐릭터를 목록에서 지울까요?", isPresented: $confirmRemove) {
            Button("지우기", role: .destructive, action: remove)
            Button("취소", role: .cancel) {}
        } message: {
            Text("메뉴바는 강아지 캐릭터로 돌아가요. 캐릭터 선택 맨 아래 '지운 캐릭터 다시 보기'로 언제든 되돌릴 수 있어요.")
        }
    }

    /// The live character, moving like the one in the menu bar.
    private var livePreview: some View {
        AnimatedDog(cache: sprites.cache(for: settings), pose: DogPose.forCPU(load), cpu: load)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var dogOptions: some View {
        Group {
            preview
            Panel {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    row(L("이름")) {
                        TextField("이름", text: $settings.profile.name).textFieldStyle(.roundedBorder).labelsHidden()
                    }
                    row(L("색")) {
                        HStack(spacing: 12) {
                            ColorPicker("털색", selection: color(\.baseColor), supportsOpacity: false)
                            ColorPicker("코색", selection: color(\.noseColor), supportsOpacity: false)
                        }
                        .font(.system(size: 11))
                    }
                    row(L("귀")) { menu(\.ears) }
                    row(L("꼬리")) { menu(\.tail) }
                    row(L("주둥이")) {
                        Picker("주둥이", selection: $settings.profile.snout) {
                            ForEach(SnoutStyle.allCases, id: \.self) { Text($0.koLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    row(L("체형")) { menu(\.build) }
                    row(L("무늬")) {
                        HStack(spacing: 12) {
                            menu(\.pattern)
                            // 단색 coats have no pattern area, so the colour would do nothing.
                            ColorPicker("무늬색", selection: color(\.secondaryColor), supportsOpacity: false)
                                .font(.system(size: 11))
                                .disabled(settings.profile.pattern == .solid)
                        }
                    }
                    row(L("털 모양")) { Toggle("복슬복슬한 털", isOn: $settings.profile.fluffy) }
                }
            }
        }
    }

    private func originalOptions(_ c: any AnimatedCharacter) -> some View {
        let parts = CharacterColors.parts(for: c.id)
        let drawn = (OriginalCatalog.character(c.id) as? any PaletteCharacter)?.palette ?? [:]
        return Group {
            livePreview
            Panel {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    row(L("색")) {
                        VStack(alignment: .leading, spacing: 6) {   // three per row, like the dog's and cat's
                            ForEach(Array(stride(from: 0, to: parts.count, by: 3)), id: \.self) { i in
                                HStack(spacing: 12) {
                                    ForEach(parts[i..<min(i + 3, parts.count)]) { part in
                                        ColorPicker(part.label, selection: partColor(c.id, part, drawn), supportsOpacity: false)
                                    }
                                }
                            }
                        }
                        .font(.system(size: 11))
                    }
                    row("") {
                        Button("기본 색으로") { settings.characterColors[c.id] = nil }
                            .controlSize(.small)
                            .disabled(settings.characterColors[c.id] == nil)
                    }
                }
            }
        }
    }

    private func catOptions(_ c: any AnimatedCharacter) -> some View {
        let solid = (settings.catLooks[c.id] ?? breed(c.id))?.coat == .solid
        return Group {
            livePreview
            Panel {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    row(L("색")) {
                        HStack(spacing: 12) {
                            ColorPicker("털색", selection: catColor(c.id, \.baseColor), supportsOpacity: false)
                            // A 단색 coat has no stripes or patches for this colour.
                            ColorPicker("무늬색", selection: catColor(c.id, \.secondaryColor), supportsOpacity: false).disabled(solid)
                            ColorPicker("포인트색", selection: catColor(c.id, \.accentColor), supportsOpacity: false)
                        }
                        .font(.system(size: 11))
                    }
                    row("") {
                        HStack(spacing: 12) {
                            ColorPicker("눈색", selection: catColor(c.id, \.eyeColor), supportsOpacity: false)
                            ColorPicker("코색", selection: catColor(c.id, \.noseColor), supportsOpacity: false)
                        }
                        .font(.system(size: 11))
                    }
                    row("") {
                        Button("기본 색으로") { settings.catLooks[c.id] = nil }
                            .controlSize(.small)
                            .disabled(settings.catLooks[c.id] == nil)
                    }
                }
            }
        }
    }

    /// Built-in characters other than the dog: an original, a cat.
    private var removableID: String? { settings.activeOriginal?.id ?? settings.activeCat?.id }

    private func removeRow(_ id: String) -> some View {
        Panel {
            HStack {
                Text("기본 캐릭터라 완전히 지워지지는 않고, 캐릭터 목록에서만 빠져요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("목록에서 지우기…", role: .destructive) { confirmRemove = true }.controlSize(.small)
            }
        }
    }

    private func remove() {
        guard let id = removableID else { return }
        if !settings.hiddenCharacters.contains(id) { settings.hiddenCharacters.append(id) }
        settings.character = .dog
        onBack()
    }

    private func breed(_ id: String) -> CatProfile? { (CatCatalog.character(id) as? CatCharacter)?.profile }

    private func catColor(_ id: String, _ key: WritableKeyPath<CatProfile, RGBColor>) -> Binding<Color> {
        Binding(get: { Color((settings.catLooks[id] ?? breed(id))?[keyPath: key] ?? RGBColor(hex: "#808080")) },
                set: { guard var p = settings.catLooks[id] ?? breed(id) else { return }
                       p[keyPath: key] = RGBColor($0)
                       settings.catLooks[id] = p })
    }

    private func partColor(_ id: String, _ part: ColorPart, _ drawn: [String: String]) -> Binding<Color> {
        Binding(get: { Color(settings.characterColors[id]?[part.id] ?? CharacterColors.drawn(part, in: drawn)) },
                set: { settings.characterColors[id, default: [:]][part.id] = RGBColor($0) })
    }

    /// Live dog next to the photo, with the photo buttons underneath.
    private var preview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                DogPhoto(path: settings.photoPath)
                AnimatedDog(cache: sprites.cache(for: settings), pose: DogPose.forCPU(load), cpu: load)
            }
            HStack(spacing: 8) {
                Button(settings.photoPath == nil ? "사진 넣기…" : "사진 바꾸기…", action: choosePhoto)
                if settings.photoPath != nil {
                    Button("사진 빼기") { settings.photoPath = nil }
                } else if let jelly = AppSettings.bundledPhotoPath {
                    Button("기본 사진") { settings.photoPath = jelly }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        GridRow {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            control()
        }
    }

    private func menu<E: KoLabeled>(_ key: WritableKeyPath<DogProfile, E>) -> some View {
        Picker("", selection: Binding(get: { settings.profile[keyPath: key] },
                                      set: { settings.profile[keyPath: key] = $0 })) {
            ForEach(Array(E.allCases), id: \.self) { Text($0.koLabel).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func color(_ key: WritableKeyPath<DogProfile, RGBColor>) -> Binding<Color> {
        Binding(get: { Color(settings.profile[keyPath: key]) },
                set: { settings.profile[keyPath: key] = RGBColor($0) })
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("캐릭터 사진을 골라 주세요")
        NSApp.activate(ignoringOtherApps: true)
        guard PopoverLayer.runModal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        #if MAS   // the sandbox lets us read the pick only until quit: keep a copy in the app's own container
        settings.photoPath = (try? Self.keepPhoto(url))?.path ?? url.path
        #else
        settings.photoPath = url.path
        #endif
    }

    #if MAS
    /// Copies a picked photo to Application Support (the container), replacing the previous copy. Returns the copy.
    static func keepPhoto(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Photo", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("dog." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()))
        try fm.copyItem(at: url, to: copy)
        return copy
    }
    #endif
}

// MARK: Korean labels for the look options

protocol KoLabeled: CaseIterable, Hashable {
    var koLabel: String { get }
}

extension EarStyle: KoLabeled {
    var koLabel: String {
        switch self {
        case .pointy: return L("쫑긋 귀")
        case .floppy: return L("늘어진 귀")
        case .folded: return L("접힌 귀")
        case .long: return L("긴 귀")
        }
    }
}

extension TailStyle: KoLabeled {
    var koLabel: String {
        switch self {
        case .curly: return L("말린 꼬리")
        case .straight: return L("곧은 꼬리")
        case .short: return L("짧은 꼬리")
        case .fluffy: return L("복슬 꼬리")
        }
    }
}

extension SnoutStyle: KoLabeled {
    var koLabel: String {
        switch self {
        case .short: return L("짧게")
        case .medium: return L("보통")
        case .long: return L("길게")
        }
    }
}

extension BodyBuild: KoLabeled {
    var koLabel: String {
        switch self {
        case .small: return L("작은 체구")
        case .medium: return L("보통 체구")
        case .large: return L("큰 체구")
        case .long: return L("허리 긴 체형")
        }
    }
}

extension CoatPattern: KoLabeled {
    var koLabel: String {
        switch self {
        case .solid: return L("단색")
        case .mask: return L("얼굴 마스크")
        case .saddle: return L("등 안장 무늬")
        case .whiteChest: return L("흰 가슴")
        case .socks: return L("흰 양말")
        case .spots: return L("점박이")
        }
    }
}
