import SwiftUI

/// 설정 > 플러그인 > 옷 입히기: pick a character, put things on it, see it walk. Saved per character in
/// AppSettings.outfits; every place that draws that character wears it.
struct WardrobeSettings: View {
    @ObservedObject var settings: AppSettings = .shared
    @ObservedObject private var season = SeasonCenter.shared
    /// Wardrobe.key of the character being dressed; nil = the menu bar's.
    @State private var picked: String?
    @State private var nudging = false

    private var menuKey: String { Wardrobe.key(SpriteLook(settings)) }
    private var target: String { picked ?? menuKey }

    /// The menu bar character first, then the built-in ones (a pack's HD twin shares its dot one's outfit).
    private var choices: [(key: String, name: String)] {
        var out = [(menuKey, L("메뉴 막대 캐릭터") + " · " + settings.characterName)]
        if menuKey != "dog" { out.append(("dog", L("강아지"))) }
        for c in CatCatalog.all + OriginalCatalog.all where !c.id.hasSuffix(RenderStyle.hdSuffix) && c.id != menuKey {
            out.append((c.id, c.displayName))
        }
        return out
    }

    private var outfit: Binding<Outfit> {
        Binding(get: { settings.outfits[target] ?? Outfit() },
                set: { o in settings.outfits[target] = o.isEmpty ? nil : o })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("캐릭터", selection: Binding(get: { target }, set: { picked = $0 == menuKey ? nil : $0 })) {
                ForEach(choices, id: \.key) { Text(verbatim: $0.name).tag($0.key) }
            }
            .controlSize(.small)
            HStack {
                Spacer()
                AnimatedDog(cache: Self.preview(target, outfit.wrappedValue, settings), pose: .walk, cpu: 30)
                    .frame(height: 20 * Self.px)
                Spacer()
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            chips("모자", \.head, .head)
            chips("눈", \.eyes, .eyes)
            chips("목", \.neck, .neck)
            HStack(spacing: 6) {
                Text("셔츠").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                dot(nil, L("없음"))
                ForEach(offered(.shirt, worn: Wardrobe.items(.shirt).first { $0.hex == outfit.wrappedValue.shirt }?.id), id: \.id) {
                    dot($0.hex, $0.name)
                }
            }
            DisclosureGroup("위치 조정", isExpanded: $nudging) {
                VStack(alignment: .leading, spacing: 4) {
                    nudge("모자", "head")
                    nudge("눈", "eyes")
                    nudge("목", "neck")
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
            HStack {
                Text("모자·안경은 머리 위치를 찾아서 씌워요. 어긋나면 위치 조정으로 옮겨 주세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("다 벗기") { settings.outfits[target] = nil }
                    .controlSize(.small).disabled(outfit.wrappedValue.isEmpty)
            }
        }
    }

    private func chips(_ label: LocalizedStringKey, _ path: WritableKeyPath<Outfit, String?>, _ slot: Wardrobe.Slot) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    chip(L("없음"), on: outfit.wrappedValue[keyPath: path] == nil) { outfit.wrappedValue[keyPath: path] = nil }
                    ForEach(offered(slot, worn: outfit.wrappedValue[keyPath: path]), id: \.id) { it in
                        chip(it.name, on: outfit.wrappedValue[keyPath: path] == it.id) { outfit.wrappedValue[keyPath: path] = it.id }
                    }
                }
            }
        }
    }

    /// The slot's items: the usual ones, 시즌 prizes once owned, and whatever is worn now.
    private func offered(_ slot: Wardrobe.Slot, worn: String?) -> [Wardrobe.Item] {
        let owned = Set(season.state.owned)
        return Wardrobe.items(slot).filter { !$0.season || owned.contains($0.id) || $0.id == worn }
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func dot(_ hex: String?, _ name: String) -> some View {
        let on = outfit.wrappedValue.shirt == hex
        return Button { outfit.wrappedValue.shirt = hex } label: {
            Circle().fill(hex.map { Color(nsColor: Self.color($0)) } ?? Color.clear)
                .overlay(Circle().stroke(on ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: on ? 2 : 1))
                .overlay(hex == nil ? Image(systemName: "slash.circle").font(.system(size: 10)).foregroundStyle(.secondary) : nil)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text(verbatim: name))
    }

    private func nudge(_ label: LocalizedStringKey, _ slot: String) -> some View {
        let n = Binding<OutfitNudge>(
            get: { outfit.wrappedValue.nudges?[slot] ?? OutfitNudge(dx: 0, dy: 0) },
            set: { v in
                var o = outfit.wrappedValue
                var all = o.nudges ?? [:]
                all[slot] = v == OutfitNudge(dx: 0, dy: 0) ? nil : v
                o.nudges = all.isEmpty ? nil : all
                outfit.wrappedValue = o
            })
        let r = -Wardrobe.nudgeLimit...Wardrobe.nudgeLimit
        return HStack(spacing: 10) {
            Text(label).frame(width: 34, alignment: .leading).foregroundStyle(.secondary)
            Stepper("좌우 \(n.wrappedValue.dx)", value: Binding(get: { n.wrappedValue.dx }, set: { n.wrappedValue.dx = $0 }), in: r)
            Stepper("위아래 \(-n.wrappedValue.dy)", value: Binding(get: { -n.wrappedValue.dy }, set: { n.wrappedValue.dy = -$0 }), in: r)
        }
        .controlSize(.small)
    }

    // MARK: Preview

    private static let px: CGFloat = 4
    /// The last preview only: a chip click rebuilds it once.
    private static var kept: (key: String, outfit: Outfit, style: RenderStyle, cache: DogSpriteCache)?

    private static func preview(_ key: String, _ outfit: Outfit, _ settings: AppSettings) -> DogSpriteCache {
        if let k = kept, k.key == key, k.outfit == outfit, k.style == settings.renderStyle { return k.cache }
        var look = SpriteLook(settings)
        let cache: DogSpriteCache
        if key == Wardrobe.key(look) {
            look.outfit = outfit
            cache = DogSpriteCache(look, pixelSize: px)
        } else if let cat = CatCatalog.character(key) {
            cache = DogSpriteCache(CharacterColors.cat(cat, settings.catLooks[key]), pixelSize: px, outfit: .some(outfit))
        } else if let c = OriginalCatalog.character(RenderStyle.paired(key, RenderStyle.current, has: RenderStyle.hasOriginal)) {
            cache = DogSpriteCache(CharacterColors.apply(settings.characterColors[key], to: c), pixelSize: px, outfit: .some(outfit))
        } else {
            cache = DogSpriteCache(profile: settings.profile, pixelSize: px, outfit: outfit)
        }
        kept = (key, outfit, settings.renderStyle, cache)
        return cache
    }

    private static func color(_ hex: String) -> NSColor {
        let c = RGBColor(hex: hex)
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}
