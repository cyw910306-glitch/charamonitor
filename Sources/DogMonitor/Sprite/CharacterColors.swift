import AppKit

/// A named part of a ready-made character that 꾸미기 can recolour: a base palette key first, then its shades.
struct ColorPart: Identifiable, Equatable {
    let id: String
    let label: String
    let keys: [String]
}

/// An original whose frames.json palette 꾸미기 can change.
protocol PaletteCharacter: AnimatedCharacter {
    var palette: [String: String] { get }
    func recolored(_ palette: [String: String]) -> any AnimatedCharacter
}

/// 꾸미기 for the originals and cats. A part takes the picked colour on its base key; each shade keeps its hue offset,
/// saturation and brightness relative to the base, so shading and outlines survive any colour.
enum CharacterColors {
    /// Palette keys per original, from tools/originals-set2/*.py PAL (checked against renders of each key).
    static let parts: [String: [ColorPart]] = [
        "original-tan-cat": [part("fur", L("털색"), "F", "f"), part("cap", L("모자색"), "T", "t"), part("hoodie", L("후드티색"), "L", "l"),
                             part("shorts", L("바지색"), "D"), part("board", L("보드색"), "V")],
    ]

    private static func part(_ id: String, _ label: String, _ keys: String...) -> ColorPart { ColorPart(id: id, label: label, keys: keys) }

    static func parts(for id: String?) -> [ColorPart] { id.flatMap { parts[$0] } ?? [] }

    /// The colour a part shows before any change: its base key's.
    static func drawn(_ part: ColorPart, in palette: [String: String]) -> RGBColor {
        RGBColor(hex: part.keys.first.flatMap { palette[$0] } ?? "#808080")
    }

    /// `base` with each part in `choice` recoloured; unknown part ids and keys are ignored.
    static func palette(_ base: [String: String], parts: [ColorPart], choice: [String: RGBColor]) -> [String: String] {
        var out = base
        for part in parts {
            guard let target = choice[part.id], let first = part.keys.first, let baseHex = base[first] else { continue }
            for key in part.keys { if let hex = base[key] { out[key] = shade(hex, base: baseHex, to: target).hex } }
        }
        return out
    }

    /// `color` moved the way `base` moves to `target`: same hue offset, same relative saturation and brightness.
    static func shade(_ color: String, base: String, to target: RGBColor) -> RGBColor {
        let (hc, sc, vc) = hsv(RGBColor(hex: color)), (hb, sb, vb) = hsv(RGBColor(hex: base)), (ht, st, vt) = hsv(target)
        var h = ht + (hc - hb)
        h -= floor(h)
        let s = sb > 0.04 ? st * sc / sb : st + (sc - sb)
        let v = vb > 0.02 ? vt * vc / vb : vt + (vc - vb)
        return rgb(h, min(1, max(0, s)), min(1, max(0, v)))
    }

    // MARK: One kept copy each, so the menu bar, cursor buddy and 꾸미기 share one render

    // ponytail: one entry per kind; the app shows one character at a time.
    private static var keptOriginal: (key: String, character: any AnimatedCharacter)?
    private static var keptCat: (id: String, profile: CatProfile, character: any AnimatedCharacter)?

    /// The original with its 꾸미기 colours, or itself when there are none.
    static func apply(_ choice: [String: RGBColor]?, to c: any AnimatedCharacter) -> any AnimatedCharacter {
        guard let choice, !choice.isEmpty, c is any PaletteCharacter else { return c }
        let key = c.id + signature(choice)
        if let kept = keptOriginal, kept.key == key { return kept.character }
        let made = recolored(c, choice)
        keptOriginal = (key, made)
        return made
    }

    /// A fresh recoloured copy, never kept (picker tiles, which show many at once).
    static func recolored(_ c: any AnimatedCharacter, _ choice: [String: RGBColor]?) -> any AnimatedCharacter {
        guard let choice, !choice.isEmpty, let p = c as? any PaletteCharacter else { return c }
        return p.recolored(palette(p.palette, parts: parts(for: c.id), choice: choice))
    }

    /// Stable text for a choice, for cache keys.
    static func signature(_ choice: [String: RGBColor]?) -> String {
        (choice ?? [:]).sorted { $0.key < $1.key }.map { "|\($0.key)=\($0.value.hex)" }.joined()
    }

    /// What a character looks like, for cache keys: its palette (originals) or profile (cats).
    static func look(_ c: any AnimatedCharacter) -> String {
        if let p = c as? any PaletteCharacter { return p.palette.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() }
        if let cat = c as? CatCharacter { return String(describing: cat.profile) }
        return ""
    }

    /// The cat drawn from its 꾸미기 profile, or itself when it has none.
    static func cat(_ c: any AnimatedCharacter, _ profile: CatProfile?) -> any AnimatedCharacter {
        guard let profile, let base = c as? CatCharacter, profile != base.profile else { return c }
        if let kept = keptCat, kept.id == c.id, kept.profile == profile { return kept.character }
        let made = CatCharacter(id: c.id, profile: profile)
        keptCat = (c.id, profile, made)
        return made
    }

    // MARK: Colour math

    private static func hsv(_ c: RGBColor) -> (Double, Double, Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> RGBColor {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        return RGBColor(r: byte(r), g: byte(g), b: byte(b))
    }
}
