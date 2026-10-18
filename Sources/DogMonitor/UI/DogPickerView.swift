import AppKit
import SwiftUI

/// Top level of 캐릭터 선택.
enum PickerTab: String, CaseIterable {
    case animals = "동물", characters = "캐릭터"
    var title: String { self == .animals ? L("동물") : L("캐릭터") }
}
/// Which breed grid the 동물 tab shows.
enum PickerSpecies { case dog, cat }

/// "캐릭터 선택" page. 동물: 강아지 (breed presets, 젤리 first) or 고양이 (CatCatalog). 캐릭터: the original characters
/// and local packs (tap opens their preview page) and 나만의 캐릭터 (made from the user's pictures).
/// Picking a breed keeps the current name and photo. Every pick closes the popover.
struct DogPickerView: View {
    @ObservedObject var settings: AppSettings
    let sprites: SpriteHolder
    @ObservedObject var store: CustomCharacterStore = .shared
    let onCreate: () -> Void
    /// Opens a saved custom character in the editor (right-click 꾸미기 · 삭제).
    let onEdit: (UUID) -> Void
    /// Opens an original's preview page (picked there).
    var onPreview: (String) -> Void = { _ in }
    let onBack: () -> Void
    @State private var tab: PickerTab
    @State private var species: PickerSpecies

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    /// `tab` and `species` default to wherever the shown character lives (QA passes them to draw each state).
    init(settings: AppSettings, sprites: SpriteHolder, tab: PickerTab? = nil, species: PickerSpecies? = nil,
         onCreate: @escaping () -> Void, onEdit: @escaping (UUID) -> Void, onPreview: @escaping (String) -> Void = { _ in },
         onBack: @escaping () -> Void) {
        self.settings = settings
        self.sprites = sprites
        self.onCreate = onCreate
        self.onEdit = onEdit
        self.onPreview = onPreview
        self.onBack = onBack
        let shown = settings.shownCharacter
        _tab = State(initialValue: tab ?? (shown == .dog || shown == .cat ? .animals : .characters))
        _species = State(initialValue: species ?? (shown == .cat ? .cat : .dog))
    }

    var body: some View {
        PageScaffold(title: L("캐릭터 선택"), onBack: onBack) {
            VStack(spacing: 8) {
                current
                RenderStylePicker(settings: settings)
                Picker("", selection: $tab) {
                    ForEach(PickerTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 2)
                if tab == .animals { animals } else { characters }
                restoreRow
            }
        }
    }

    private func shows(_ id: String) -> Bool { !settings.hiddenCharacters.contains(id) }

    /// Built-in characters taken off the list in 꾸미기 come back from here.
    @ViewBuilder private var restoreRow: some View {
        let hidden = settings.hiddenCharacters.count
        if hidden > 0 {
            Button("지운 캐릭터 \(hidden)개 다시 보기") { settings.hiddenCharacters = [] }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    /// Right-click on a built-in tile: take it off the list (the one in use hands the menu bar back to the dog).
    private func removable(_ id: String) -> some View {
        Button("목록에서 지우기") {
            if !settings.hiddenCharacters.contains(id) { settings.hiddenCharacters.append(id) }
            // A pack pair's tile holds the dot id, but 일러스트 may have stored its "-hd" half.
            let original = settings.originalID.map { RenderStyle.listed($0, has: RenderStyle.hasOriginal) }
            if settings.character == .cat && settings.catID == id || settings.character == .original && original == id {
                settings.character = .dog
            }
        }
    }

    private var current: some View {
        let shown = settings.shownCharacter
        return HStack(spacing: 12) {
            AnimatedDog(cache: sprites.cache(for: settings), pose: .walk, cpu: 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.characterName)
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle(shown))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func subtitle(_ shown: SpriteCharacter) -> String {
        switch shown {
        case .custom: return L("내 그림으로 만든 캐릭터")
        case .cat: return L("고양이")
        case .original: return L("오리지널 캐릭터")
        case .dog:
            // The jelly preset's name is the default name too: show the species then, never "젤리 / 젤리".
            guard let preset = selectedID.flatMap({ id in DogProfile.presets.first { $0.id == id }?.name }) else { return L("직접 꾸민 캐릭터") }
            return preset == settings.characterName ? L("강아지") : preset
        }
    }

    // MARK: 동물

    @ViewBuilder private var animals: some View {
        let shown = settings.shownCharacter
        LazyVGrid(columns: columns, spacing: 8) {
            cell(PresetThumbs.dog(settings.profile), L("강아지"), selected: species == .dog) { species = .dog }
            cell(PresetThumbs.ready(CatCatalog.all.first ?? CatCatalog.placeholders[0]), L("고양이"), selected: species == .cat) { species = .cat }
        }
        if species == .dog {
            section(L("견종"))
            LazyVGrid(columns: columns, spacing: 8) {
                // A dog recoloured in 꾸미기 matches no preset; it stays reachable as the first tile.
                if selectedID == nil {
                    cell(PresetThumbs.dog(settings.profile), settings.dogName, selected: shown == .dog) { settings.character = .dog; Self.done() }
                }
                ForEach(DogProfile.presets) { preset in
                    cell(PresetThumbs.image(for: preset), preset.name, selected: shown == .dog && preset.id == selectedID) { apply(preset) }
                }
            }
        } else {
            section(L("묘종"))
            LazyVGrid(columns: columns, spacing: 8) {
                if CatCatalog.all.isEmpty {
                    ForEach(CatCatalog.placeholders, id: \.id) { placeholder($0) }
                } else {
                    ForEach(CatCatalog.all.filter { shows($0.id) }, id: \.id) { cat in
                        cell(PresetThumbs.ready(cat, cat: settings.catLooks[cat.id]), cat.displayName, selected: shown == .cat && settings.catID == cat.id) {
                            settings.useCat(cat.id)
                            Self.done()
                        }
                        .contextMenu { removable(cat.id) }
                    }
                }
            }
        }
    }

    // MARK: 캐릭터

    @ViewBuilder private var characters: some View {
        let shown = settings.shownCharacter
        section(L("캐릭터"))
        LazyVGrid(columns: columns, spacing: 8) {
            // A pack pair ("-hd") is one tile, drawn and opened as the half the 그림 스타일 shows.
            ForEach(OriginalCatalog.all.filter { shows($0.id) && RenderStyle.listed($0.id, has: RenderStyle.hasOriginal) == $0.id }, id: \.id) { c in
                let id = RenderStyle.paired(c.id, settings.renderStyle, has: RenderStyle.hasOriginal)
                cell(PresetThumbs.ready(OriginalCatalog.character(id) ?? c, colors: settings.characterColors[c.id]), c.displayName,
                     selected: shown == .original && settings.originalID.map { RenderStyle.listed($0, has: RenderStyle.hasOriginal) } == c.id) {
                    onPreview(id)
                }
                    .accessibilityHint("미리보기 열기")
                    .contextMenu { removable(c.id) }
            }
        }
        section(L("나만의 캐릭터"))
        if !store.characters.isEmpty {
            Text("고치거나 지우려면 캐릭터를 오른쪽 클릭하세요")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(store.characters) { c in
                cell(PresetThumbs.custom(c), c.displayName, selected: shown == .custom && settings.customCharacterID == c.id.uuidString) {
                    settings.useCustom(c.id)
                    Self.done()
                }
                .contextMenu { Button("꾸미기 · 삭제…") { onEdit(c.id) } }
            }
            createCell
        }
        packRow
    }

    /// Characters from the user's own image files (docs/PACKS.md): the folder they go in, read at the next launch.
    private var packRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("내 그림 파일로 캐릭터 팩을 만들 수도 있어요. 팩은 앱을 다시 켜면 읽어요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("팩 폴더 열기") {
                let root = CharacterPack.defaultRoot
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                External.open(root)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    /// A catalog slot whose art is not in this build yet: shown greyed, never picked.
    private func placeholder(_ c: PlaceholderCharacter) -> some View {
        cell(PresetThumbs.ready(c), c.displayName, note: L("준비 중"), selected: false) {}
            .disabled(true)
            .opacity(0.5)
    }

    /// At the limit the tile stays, greyed, and says how to free a slot.
    private var createCell: some View {
        let full = store.isFull
        return Button(action: onCreate) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: CGFloat(DogSpriteCache.canvasWidth * 2), height: CGFloat(DogSpriteCache.canvasHeight * 2))
                Text("새 캐릭터 만들기").font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.75)
                if full {
                    Text("최대 \(CustomCharacterStore.maxCount)개 · 하나를 지우면 새로 만들 수 있어요")
                        .font(.system(size: 9)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(full)
        .opacity(full ? 0.55 : 1)
        .accessibilityLabel(full ? "새 캐릭터 만들기, 최대 개수라 지금은 만들 수 없음" : "새 캐릭터 만들기")
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func cell(_ image: NSImage, _ title: String, note: String? = nil, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: image).interpolation(.none)
                    .frame(height: CGFloat(DogSpriteCache.canvasHeight * 2))
                Text(title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.75)
                if let note { Text(note).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A preset counts as selected when everything but the name matches.
    private var selectedID: String? {
        var look = settings.profile
        return DogProfile.presets.first { p in
            look.name = p.profile.name
            return look == p.profile
        }?.id
    }

    private func apply(_ preset: DogPreset) {
        var p = preset.profile
        p.name = settings.profile.name
        settings.profile = p
        settings.character = .dog
        Self.done()
    }

    /// A pick is final: close the popover shortly after, so the highlight shows and the menu bar updates in view.
    static func done() {
        PopoverMemory.shared.page = .main   // the choice is made: the next open starts on the dashboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: StatusItemController.closeRequest, object: nil)
        }
    }
}

/// Preview of an original character or pack: every pose and extra moment playing, then 이 캐릭터 쓰기.
struct CharacterPreviewView: View {
    @ObservedObject var settings: AppSettings
    let character: any AnimatedCharacter
    let onBack: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        let big = PreviewCache.cache(character, pixelSize: 4)
        let small = PreviewCache.cache(character, pixelSize: 2)
        PageScaffold(title: character.displayName, onBack: onBack, footer: AnyView(footer)) {
            VStack(spacing: 8) {
                FramesPlayer(frames: big.frames(for: .walk), size: big.imageSize, every: 0.16, smooth: big.smooth)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                if let blurb = character.previewBlurb {
                    Text(blurb).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("상황마다 다른 모션으로 움직여요").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(DogPose.allCases, id: \.self) { pose in
                        motion(small.frames(for: pose), small.imageSize, every: small.frameDuration(for: pose, cpu: Self.cpu(pose), extra: nil), smooth: small.smooth,
                               title: pose.label, note: Self.when(pose))
                    }
                    ForEach(ExtraMotion.allCases, id: \.self) { m in
                        if let f = small.frames(forExtra: m) {
                            motion(f, small.imageSize, every: small.frameDuration(for: .walk, cpu: 0, extra: m), smooth: small.smooth, title: m == .special ? character.specialTitle.map { "\($0)!" } ?? m.label : m.label, note: Self.when(m))
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        Button {
            settings.useOriginal(character.id)
            DogPickerView.done()
        } label: {
            Text("이 캐릭터 쓰기").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 12)
    }

    private func motion(_ frames: [NSImage], _ size: NSSize, every d: TimeInterval, smooth: Bool, title: String, note: String) -> some View {
        VStack(spacing: 3) {
            FramesPlayer(frames: frames, size: size, every: d, smooth: smooth)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private static func cpu(_ pose: DogPose) -> Double { [0, 0.1, 0.2, 0.37, 0.55, 0.75, 0.92][pose.rawValue] }

    private static func when(_ pose: DogPose) -> String {
        [L("CPU 5% 미만"), "CPU 5~15%", "CPU 15~30%", "CPU 30~45%", "CPU 45~65%", "CPU 65~85%", L("CPU 85% 이상")][pose.rawValue]
    }

    private static func when(_ m: ExtraMotion) -> String {
        switch m {
        case .hungry: return L("배터리 20% 이하")
        case .eat: return L("충전 중")
        case .special: return L("아주 바쁠 때")
        }
    }
}

/// Plays frames through AnimatedSpriteView (the layer swap the dashboard dog uses).
struct FramesPlayer: NSViewRepresentable {
    let frames: [NSImage]
    let size: NSSize
    let every: TimeInterval
    var smooth = false

    func makeNSView(context: Context) -> AnimatedSpriteView {
        let v = AnimatedSpriteView()
        v.setAccessibilityElement(false)
        v.play(frames, every: every, smooth: smooth)
        return v
    }

    func updateNSView(_ v: AnimatedSpriteView, context: Context) { v.play(frames, every: every, smooth: smooth) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedSpriteView, context: Context) -> CGSize? { size }
}

/// The preview page's caches, kept for the last character only.
private enum PreviewCache {
    private static var kept: [String: DogSpriteCache] = [:]

    static func cache(_ c: any AnimatedCharacter, pixelSize: CGFloat) -> DogSpriteCache {
        let look = CharacterColors.look(c)   // a recoloured copy is not the drawn one
        let key = "\(c.id)@\(pixelSize)" + look + RenderStyle.current.rawValue
        if let hit = kept[key] { return hit }
        // Only this character, in this look, stays kept (its small and big sizes); the rest are dropped.
        if !kept.keys.contains(where: { $0.hasPrefix(c.id + "@") && $0.hasSuffix(look + RenderStyle.current.rawValue) }) { kept = [:] }
        let fresh = DogSpriteCache(c, pixelSize: pixelSize)
        kept[key] = fresh
        return fresh
    }
}

/// Walk frame 0 of every preset, rendered once on first use and kept (they never change),
/// plus the current dog, re-rendered only when its look changes.
private enum PresetThumbs {
    private static var cache: [String: NSImage] = [:]
    private static var current: (look: DogProfile, image: NSImage)?
    private static var customs: [UUID: (frames: [[[UInt8]]], image: NSImage)] = [:]
    private static var readies: [String: NSImage] = [:]
    /// The 그림 스타일 these were drawn in; a change draws them all again.
    private static var style = RenderStyle.auto

    private static func sync() {
        guard style != RenderStyle.current else { return }
        style = RenderStyle.current
        (cache, current, customs, readies) = ([:], nil, [:], [:])
    }

    /// A catalog character (cat, original, placeholder): first walk frame at 2x.
    /// `colors` / `cat`: the 꾸미기 colours, so a recoloured character's tile matches the menu bar.
    static func ready(_ c: any AnimatedCharacter, colors: [String: RGBColor]? = nil, cat: CatProfile? = nil) -> NSImage {
        sync()
        let key = c.id + CharacterColors.signature(colors) + (cat.map { "|" + String(describing: $0) } ?? "")
        if let hit = readies[key] { return hit }
        var shown = CharacterColors.recolored(c, colors)
        if let cat, let base = c as? CatCharacter, cat != base.profile { shown = CatCharacter(id: c.id, profile: cat) }
        let img = shown.frames(for: .walk).first.map {
            DogSpriteCache.scaled(style.restyle($0, drawnSmooth: shown.smooth, density: shown.artDensity), by: 2, smooth: style.smooth(shown.smooth))
        }
            ?? NSImage(size: NSSize(width: DogSpriteCache.canvasWidth * 2, height: DogSpriteCache.canvasHeight * 2))
        readies[key] = img
        return img
    }

    static func custom(_ plain: CustomCharacter) -> NSImage {
        sync()
        if let hit = customs[plain.id], hit.frames == plain.frames { return hit.image }
        let c = plain.styled(style)
        let img = (c.real.map { DogSpriteCache(real: $0, pixelSize: 2) } ?? DogSpriteCache(profile: .defaultDog, custom: c.frames, pixelSize: 2)).frames(for: .walk)[0]
        customs[c.id] = (plain.frames, img)
        return img
    }

    static func image(for preset: DogPreset) -> NSImage {
        sync()
        if let hit = cache[preset.id] { return hit }
        let img = DogSpriteCache(profile: preset.profile, pixelSize: 2).frames(for: .walk)[0]
        cache[preset.id] = img
        return img
    }

    static func dog(_ profile: DogProfile) -> NSImage {
        sync()
        var look = profile
        look.name = ""
        if let current, current.look == look { return current.image }
        let img = DogSpriteCache(profile: look, pixelSize: 2).frames(for: .walk)[0]
        current = (look, img)
        return img
    }
}
