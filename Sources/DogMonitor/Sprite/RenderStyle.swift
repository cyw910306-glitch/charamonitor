import AppKit

/// 그림 스타일, one switch for every place a character is drawn (menu bar, picker, cursor buddy and the other desktop
/// friends): they all build a DogSpriteCache, which applies it once per frame when the cache is built.
/// 자동 draws each character as made; 도트 turns illustrations and photos into pixel art; 일러스트 smooths pixel art
/// (EPX) and shows photo characters as 실사. Local packs pair by id: "pack-x" (dot) and "pack-x-hd" (illustration).
enum RenderStyle: String, CaseIterable, Codable {
    case auto, pixel, illustration

    var label: String {
        switch self {
        case .auto: return L("자동")
        case .pixel: return L("도트")
        case .illustration: return L("일러스트")
        }
    }

    var note: String {
        switch self {
        case .auto: return L("캐릭터마다 그려진 그대로 보여 줘요")
        case .pixel: return L("모든 캐릭터를 또렷한 도트로 보여 줘요")
        case .illustration: return L("도트 그림은 매끈하게, 사진 캐릭터는 실사로 보여 줘요")
        }
    }

    /// What the app is set to now; caches built without an explicit style use it.
    static var current: RenderStyle { AppSettings.shared.renderStyle }

    /// Whether art drawn `smooth` (an illustration) ends up drawn smooth in this style.
    func smooth(_ drawnSmooth: Bool) -> Bool {
        switch self {
        case .auto: return drawnSmooth
        case .pixel: return false
        case .illustration: return true
        }
    }

    // MARK: Pack pairs

    static let hdSuffix = "-hd"

    /// The half of a pack pair this style shows ("pack-x-hd" for 일러스트, "pack-x" for 도트), or `id` when it has none.
    static func paired(_ id: String, _ style: RenderStyle, has: (String) -> Bool) -> String {
        switch style {
        case .illustration where !id.hasSuffix(hdSuffix) && has(id + hdSuffix): return id + hdSuffix
        case .pixel where id.hasSuffix(hdSuffix) && has(String(id.dropLast(hdSuffix.count))): return String(id.dropLast(hdSuffix.count))
        default: return id
        }
    }

    /// The half the picker lists: the dot one when both are there.
    static func listed(_ id: String, has: (String) -> Bool) -> String { paired(id, .pixel, has: has) }

    static func hasOriginal(_ id: String) -> Bool { OriginalCatalog.character(id) != nil }

    // MARK: Frames

    /// Size an EPX-smoothed frame grows to: 8 px per point, what the 4x preview needs on Retina.
    static let smoothWidth = DogSpriteCache.canvasWidth * 8
    /// Size of a pixelated illustration: 2 art px per point, like a custom character.
    static let pixelWidth = DogSpriteCache.canvasWidth * 2, pixelHeight = DogSpriteCache.canvasHeight * 2
    /// Colour steps per channel when an illustration becomes pixel art.
    static let posterLevels = 6

    /// EPX / Scale2x: every pixel becomes 2 x 2, and a corner takes its two matching neighbours' colour when they
    /// agree and the other two do not, so staircase diagonals come out smooth. Premultiplied RGBA, row by row; the
    /// edge repeats itself. Transparent pixels stay transparent unless a filled diagonal reaches into them.
    static func epx(_ rgba: [UInt8], w: Int, h: Int) -> ([UInt8], Int, Int) {
        func px(_ x: Int, _ y: Int) -> UInt32 {
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return UInt32(rgba[i]) << 24 | UInt32(rgba[i + 1]) << 16 | UInt32(rgba[i + 2]) << 8 | UInt32(rgba[i + 3])
        }
        let w2 = w * 2, h2 = h * 2
        var out = [UInt8](repeating: 0, count: w2 * h2 * 4)
        func put(_ x: Int, _ y: Int, _ v: UInt32) {
            let o = (y * w2 + x) * 4
            out[o] = UInt8(v >> 24); out[o + 1] = UInt8(v >> 16 & 0xFF); out[o + 2] = UInt8(v >> 8 & 0xFF); out[o + 3] = UInt8(v & 0xFF)
        }
        for y in 0..<h {
            for x in 0..<w {
                let p = px(x, y), a = px(x, y - 1), b = px(x + 1, y), c = px(x - 1, y), d = px(x, y + 1)
                put(x * 2, y * 2, c == a && c != d && a != b ? a : p)
                put(x * 2 + 1, y * 2, a == b && a != c && b != d ? b : p)
                put(x * 2, y * 2 + 1, d == c && d != b && c != a ? c : p)
                put(x * 2 + 1, y * 2 + 1, b == d && b != a && d != c ? d : p)
            }
        }
        return (out, w2, h2)
    }

    /// EPX until the frame is at least `smoothWidth` wide (34 -> 272 in three steps, a custom character's 68 in two).
    static func smoothed(_ rgba: [UInt8], w: Int, h: Int) -> ([UInt8], Int, Int) {
        var r = (rgba, w, h)
        while r.1 < smoothWidth, r.1 > 0 { r = epx(r.0, w: r.1, h: r.2) }
        return r
    }

    /// An illustration's premultiplied pixels as hard pixel art: under half alpha goes, the rest turns opaque and
    /// each channel drops to `posterLevels` steps.
    static func pixelate(_ rgba: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count)
        let top = posterLevels - 1
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let a = Int(rgba[i + 3])
            guard a >= 128 else { continue }
            for c in 0..<3 {
                let v = min(255, Int(rgba[i + c]) * 255 / a)   // un-premultiply
                out[i + c] = UInt8((v * top + 127) / 255 * 255 / top)
            }
            out[i + 3] = 255
        }
        return out
    }

    /// `image` drawn into `width` x `height` px in one appearance (adaptive frames pick their dark-bar copy by it).
    static func raster(_ image: NSImage, width w: Int, height h: Int, smooth: Bool, dark: Bool = false) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return data
    }

    /// A pixel frame (`w` x `h` art px on the 34 x 20 pt canvas) smoothed into an illustration-style menu bar image.
    static func illustrated(_ rgba: [UInt8], w: Int, h: Int) -> NSImage {
        let (big, bw, bh) = smoothed(rgba, w: w, h: h)
        return BarArt.smooth(DogRenderer.cgImage(big, width: bw, height: bh, interpolate: true))
    }

    /// Any frame in this style: smoothed or pixelated when it is drawn the other way, else as it is.
    /// `density`: art px per point of a pixel frame (2 for a pixel pack, 1 for the rest).
    func restyle(_ image: NSImage, drawnSmooth: Bool, density: Int = 1) -> NSImage {
        switch self {
        case .illustration where !drawnSmooth:
            let w = DogSpriteCache.canvasWidth * density, h = DogSpriteCache.canvasHeight * density
            let light = Self.raster(image, width: w, height: h, smooth: false), dark = Self.raster(image, width: w, height: h, smooth: false, dark: true)
            let lit = Self.illustrated(light, w: w, h: h)
            guard dark != light else { return lit }
            let dim = Self.illustrated(dark, w: w, h: h)
            return NSImage(size: lit.size, flipped: false) { rect in
                (NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dim : lit).draw(in: rect)
                return true
            }
        case .pixel where drawnSmooth:
            let rgba = Self.raster(image, width: Self.pixelWidth, height: Self.pixelHeight, smooth: true)
            return BarArt.image(Self.pixelate(rgba), width: Self.pixelWidth, height: Self.pixelHeight)
        default:
            return image
        }
    }
}

extension CustomCharacter {
    /// This photo character the way `style` draws it (일러스트: 실사, 도트: pixelated), redrawn from its saved cut-outs;
    /// itself when it already is, is drawn by 내 Claude, or its cut-outs are gone. The stored choice never changes.
    func styled(_ style: RenderStyle, store: CustomCharacterStore = .shared) -> CustomCharacter {
        let want: PhotoLook.Style
        switch style {
        case .auto: return self
        case .pixel: want = .pixel
        case .illustration: want = .real
        }
        guard art == nil, (real == nil ? PhotoLook.Style.pixel : .real) != want else { return self }
        if let kept = Self.kept, kept.style == style, kept.source == self { return kept.result }
        let inputs = store.inputs(id)
        guard !inputs.isEmpty else { return self }
        var out = self
        out.look.style = want
        let drawn = CustomCharacter.render(inputs, look: out.look, chibi: chibi, lightRim: lightRim, flipped: flipped)
        out.frames = drawn.frames
        out.real = drawn.real
        Self.kept = (self, style, out)
        return out
    }

    /// The last redraw: the menu bar, the cursor buddy and the picker all ask for the same one.
    private static var kept: (source: CustomCharacter, style: RenderStyle, result: CustomCharacter)?
}
