import Foundation

/// One opaque sprite color.
public struct PixelColor: Equatable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(_ c: RGBColor) { self.init(r: c.r, g: c.g, b: c.b) }
    public init(hex: String) { self.init(RGBColor(hex: hex)) }
}

/// Every color a frame needs, derived once per profile, plus the rules that pick one per pixel.
/// Shade and highlight come from the coat itself so any picked color still reads as fur.
public struct DogPalette {
    public let base, shade, light, mid: PixelColor
    public let sec, secShade, secLight, secMid: PixelColor
    public let outline, line: PixelColor
    public let eye, glint, nose: PixelColor
    public let tongue, tongueDark, sweat, sweatDark, zz: PixelColor
    public let pattern: CoatPattern
    public let hangingEars: Bool   // floppy and long ears are a tone darker so they read against the head
    public let teddyEars: Bool     // teddy puffs stay coat colored: a light fluffy rim, an inner outline where they overlap the dog
    public let lightMuzzle: Bool   // fluffy dogs get a cream beard, the dark nose pops on it
    public let muzzle: PixelColor  // that beard; creamier on teddy faces so the short muzzle reads around the nose
    public let eyeRing: PixelColor?  // fur around the eye when the face is too dark for the eye to show

    public init(_ p: DogProfile) {
        base = PixelColor(p.baseColor)
        shade = Self.shaded(p.baseColor)
        light = Self.lit(p.baseColor)
        mid = Self.shaded(p.baseColor, by: 0.92)
        sec = PixelColor(p.secondaryColor)
        // shaded() keeps near-white grey, which reads as dirt; borrow warmth from the coat instead.
        secShade = Self.luminance(p.secondaryColor) > 0.6 ? Self.mix(sec, shade, 0.6) : Self.shaded(p.secondaryColor)
        secLight = Self.lit(p.secondaryColor)
        secMid = Self.shaded(p.secondaryColor, by: 0.92)
        nose = PixelColor(p.noseColor)
        pattern = p.pattern
        teddyEars = p.isTeddy
        hangingEars = (p.ears == .floppy || p.ears == .long) && !teddyEars
        lightMuzzle = p.fluffy
        muzzle = teddyEars ? Self.mix(light, PixelColor(hex: "#FFFFFF"), 0.5) : light
        let face = p.pattern.covers(.face) ? p.secondaryColor : p.baseColor
        if Self.luminance(face) >= 0.1 {
            eyeRing = nil
        } else {
            eyeRing = Self.luminance(p.baseColor) >= 0.1 ? base : Self.lit(face)
        }

        // Colored outline (a dark tone of the coat, not black) so the eye and nose stay the darkest pixels.
        // Very dark coats get a light outline instead, or the dog vanishes on a dark menu bar.
        var deep = HSB(p.baseColor)
        deep.s = min(1, deep.s * 1.15 + 0.15)
        deep.v = min(deep.v * 0.45, 0.4)
        line = deep.color
        if Self.luminance(p.baseColor) < 0.075 {
            var rim = HSB(p.baseColor)
            rim.s *= 0.35
            rim.v = 0.56
            outline = rim.color
        } else {
            outline = deep.color
        }

        eye = PixelColor(hex: "#1F1A1B")
        glint = PixelColor(hex: "#FFFFFF")
        tongue = PixelColor(hex: "#F27A92")
        tongueDark = PixelColor(hex: "#C74D69")
        sweat = PixelColor(hex: "#6CC6F7")
        sweatDark = PixelColor(hex: "#2C8BD6")
        zz = PixelColor(hex: "#7E9CCB")
    }

    /// Color of one cell from its own part and zone and its four neighbours' parts.
    /// Light from above: top edges get the highlight, the belly gets shade.
    public func color(_ c: ArtCell, above: ArtPart, below: ArtPart, left: ArtPart, right: ArtPart) -> PixelColor {
        switch c.ink {
        case .line, .lid: return line
        case .eye: return eye
        case .glint: return glint
        case .nose: return nose
        case .tongue: return tongue
        case .tongueDark: return tongueDark
        case .sweat: return sweat
        case .sweatDark: return sweatDark
        case .zz: return zz
        case .none: break
        }
        if c.part == .outline { return outline }
        let second = pattern.covers(c.zone)
        let open: (ArtPart) -> Bool = { $0 == .none || $0 == .outline || $0 == .fx }
        if c.part == .farEar && teddyEars {
            // Same coat as the head with a light rim: fluff past the far side of the crown, never a darker snout.
            if open(above) || open(right) { return second ? secLight : light }
            return second ? sec : base
        }
        if c.part == .farLeg || c.part == .farEar { return second ? secShade : shade }
        if c.part == .head && c.zone == .face, let eyeRing { return eyeRing }
        if c.part == .ear && teddyEars {
            // In front of the head: an inner line where they overlap. Behind and below, the fur there carries
            // the line (ArtGrid.drawEarLine), so the ear's own edge is a light fluffy rim.
            if above == .head || below == .head || !(open(right) || right == .ear) { return line }
            let fur: (ArtPart) -> Bool = { $0 == .body || $0 == .nearLeg || $0 == .farLeg || $0 == .tail }
            if open(above) || open(left) || fur(left) || fur(below) { return second ? secLight : light }
            return second ? sec : base
        }
        if c.part == .ear && hangingEars { return second ? secMid : mid }
        // Head fur just right of or below a hanging ear, where the ear casts a soft shadow.
        if hangingEars && c.part == .head && (left == .ear || above == .ear) { return second ? secShade : shade }
        if open(above) { return second ? secLight : light }
        // Belly shade, but a white chest stays warm white to its lower edge: shading it only turns it grey.
        if c.part == .body && (below == .none || below == .outline) && !(second && c.zone == .chest) {
            return second ? secShade : shade
        }
        if lightMuzzle && !second && (c.zone == .muzzle || c.zone == .chin) { return muzzle }
        return second ? sec : base
    }

    /// `t` of `a` plus the rest of `b`.
    public static func mix(_ a: PixelColor, _ b: PixelColor, _ t: Double) -> PixelColor {
        func ch(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * t + Double(y) * (1 - t)).rounded()) }
        return PixelColor(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b))
    }

    public static func shaded(_ c: RGBColor, by k: Double = 0.8) -> PixelColor {
        var x = HSB(c)
        // Richer shadows for colored fur; greys stay grey (their hue is meaningless).
        if x.s > 0.05 { x.s = min(1, x.s * (1 + (1 - k) * 0.4) + (1 - k) * 0.3) }
        x.v *= k
        return x.color
    }

    public static func lit(_ c: RGBColor) -> PixelColor {
        var x = HSB(c)
        if x.v < 0.35 {
            x.v += 0.14         // rim light: keeps dark fur edges visible on a dark bar
        } else {
            x.v = min(1, x.v * 1.08 + 0.05)
            x.s *= 0.8
        }
        return x.color
    }

    /// WCAG relative luminance, 0 (black) ... 1 (white).
    public static func luminance(_ c: RGBColor) -> Double {
        func lin(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

/// Hue, saturation, brightness in 0...1.
private struct HSB {
    public var h, s, v: Double

    public init(_ c: RGBColor) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var hue = 0.0
        if d > 0 {
            if mx == r { hue = (g - b) / d } else if mx == g { hue = (b - r) / d + 2 } else { hue = (r - g) / d + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        h = hue
        s = mx == 0 ? 0 : d / mx
        v = mx
    }

    public var color: PixelColor {
        let s = min(1, max(0, self.s)), v = min(1, max(0, self.v))
        let hh = (h - floor(h)) * 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let rgb: (Double, Double, Double)
        switch Int(hh) % 6 {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, (x * 255).rounded()))) }
        return PixelColor(r: byte(rgb.0), g: byte(rgb.1), b: byte(rgb.2))
    }
}

extension CoatPattern {
    /// Zones painted in the secondary color.
    public func covers(_ zone: ArtZone) -> Bool {
        switch self {
        case .solid: return false
        case .mask: return zone == .muzzle || zone == .face || zone == .chin
        case .saddle: return zone == .back || zone == .tail
        case .whiteChest: return zone == .chest || zone == .belly || zone == .chin
        case .socks: return zone == .paw
        case .spots: return zone == .spot || zone == .ear || zone == .face
        }
    }
}
