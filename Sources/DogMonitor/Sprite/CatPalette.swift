import Foundation

/// Every color a cat frame needs, derived once per profile, plus the per-pixel shading rule (light from above).
struct CatPalette {
    private let tones: [(c: PixelColor, shade: PixelColor, light: PixelColor, ruff: PixelColor)]   // indexed by CatTone
    let outline, line, pink, iris, nose: PixelColor
    static let propLine = PixelColor(hex: "#5B3A40")

    init(_ p: CatProfile) {
        tones = [p.baseColor, p.secondaryColor, p.accentColor].map { c in
            // Near-white fur shades warm grey, not dirty grey.
            let shade = DogPalette.luminance(c) > 0.6 ? DogPalette.mix(PixelColor(c), PixelColor(hex: "#B9AFA6"), 0.55) : DogPalette.shaded(c)
            // Ruff tufts: darker cream on pale fur, a lighter tone on darker fur.
            let ruff = DogPalette.luminance(c) > 0.6 ? DogPalette.mix(PixelColor(c), PixelColor(hex: "#C2AE96"), 0.65) : DogPalette.lit(c)
            return (PixelColor(c), shade, DogPalette.lit(c), ruff)
        }
        // Colored line (a dark tone of the coat), so the eyes stay the darkest pixels. Very dark coats get a
        // light grey rim instead, or the cat vanishes on a dark menu bar.
        line = DogPalette.luminance(p.baseColor) < 0.075 ? PixelColor(hex: "#0E0D10") : DogPalette.shaded(p.baseColor, by: 0.42)
        outline = DogPalette.luminance(p.baseColor) < 0.075 ? DogPalette.mix(PixelColor(p.baseColor), PixelColor(hex: "#A4A2AC"), 0.2)
            : (DogPalette.luminance(p.baseColor) > 0.6 ? PixelColor(hex: "#6E625C") : line)
        pink = DogPalette.mix(PixelColor(hex: "#F3A2B2"), PixelColor(p.baseColor), DogPalette.luminance(p.baseColor) < 0.075 ? 0.55 : 0.8)
        iris = PixelColor(p.eyeColor)
        nose = PixelColor(p.noseColor)
    }

    func color(_ g: CatGrid, _ x: Int, _ y: Int) -> PixelColor {
        let c = g[x, y]
        switch c.ink {
        case .line: return line
        case .pupil: return PixelColor(hex: "#1B1719")
        case .glint: return PixelColor(hex: "#FFFFFF")
        case .iris: return iris
        case .nose: return nose
        case .pink: return pink
        case .tongue: return PixelColor(hex: "#F27A92")
        case .tongueDark: return PixelColor(hex: "#C74D69")
        case .sweat: return PixelColor(hex: "#6CC6F7")
        case .sweatDark: return PixelColor(hex: "#2C8BD6")
        case .zz: return PixelColor(hex: "#7E9CCB")
        case .mark: return PixelColor(hex: "#F08A2C")
        case .bowl: return PixelColor(hex: "#E2606C")
        case .bowlDark: return PixelColor(hex: "#A93E4C")
        case .bowlLight: return PixelColor(hex: "#F6A9AE")
        case .food: return PixelColor(hex: "#B8743A")
        case .foodDark: return PixelColor(hex: "#7C4A20")
        case .silver: return PixelColor(hex: "#C9D3DF")
        case .ruff: return tones[Int(c.tone.rawValue)].ruff
        case .none: break
        }
        if c.part == .outline {
            let near = [g[x - 1, y], g[x + 1, y], g[x, y - 1], g[x, y + 1]].map(\.part)
            let cat = near.contains { $0 != .none && $0 != .outline && $0 != .fx && $0 != .prop }
            return !cat && near.contains(.prop) ? Self.propLine : outline
        }
        let t = tones[Int(c.tone.rawValue)]
        let open: (CatPart) -> Bool = { $0 == .none || $0 == .outline || $0 == .fx }
        if c.part == .farLeg || c.part == .farEar { return t.shade }
        if open(g[x, y - 1].part) { return t.light }
        if c.part == .body && open(g[x, y + 1].part) { return t.shade }
        return t.c
    }
}
