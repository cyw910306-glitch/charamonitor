import AppKit

/// 옷 입히기: the items, where they sit on a frame, and the frames wearing them. Everything is drawn in code from
/// tiny pixel stamps (like AsciiArt): pixel characters get them at their own art resolution, smooth ones (HD packs,
/// 일러스트, 실사) get the same stamps smoothed. DogSpriteCache is the only caller, so every place that draws a
/// character dresses it. Pure parts tested in WardrobeTests.
enum Wardrobe {
    enum Slot: String, CaseIterable { case head, eyes, neck, shirt }

    struct Item {
        let id: String
        let slot: Slot
        let name: String
        /// Rows top to bottom; characters missing from `colors` stay see-through. Unused for a shirt.
        let art: [String]
        /// The stamp row that lands on the slot's anchor row.
        let pin: Int
        /// A shirt's "#RRGGBB".
        var hex: String? = nil
        /// A 시즌 뽑기판 prize: offered once owned (SeasonCenter), drawn whenever worn (a friend's too).
        var season = false
    }

    static let ink: [Character: PixelColor] = [
        "R": PixelColor(hex: "#E2384D"), "r": PixelColor(hex: "#A3243A"), "W": PixelColor(hex: "#FFFFFF"),
        "K": PixelColor(hex: "#2B2B2B"), "Y": PixelColor(hex: "#F2C230"), "y": PixelColor(hex: "#B88A00"),
        "P": PixelColor(hex: "#FF7EA8"), "G": PixelColor(hex: "#3EC48F"), "B": PixelColor(hex: "#5AAEF5"),
        "b": PixelColor(hex: "#2A72B0"), "L": PixelColor(hex: "#9D86EE"), "c": PixelColor(hex: "#CDEBFF"),
        "n": PixelColor(hex: "#8A5A3B"), "g": PixelColor(hex: "#2F7D5B"),
    ]

    static let items: [Item] = [
        Item(id: "beret", slot: .head, name: L("베레모"), art: ["...r...", ".RRRRR.", "RRRRRRR"], pin: 2),
        Item(id: "cap", slot: .head, name: L("야구모자"), art: [".BBBB...", "BBBBBB..", "BBBBBBbb"], pin: 2),
        Item(id: "crown", slot: .head, name: L("왕관"), art: ["Y..Y..Y", "YY.Y.YY", "YYYRYYY", "yyyyyyy"], pin: 3),
        Item(id: "party", slot: .head, name: L("고깔"), art: ["..W..", "..P..", ".PYP.", ".YPY.", "PPPPP"], pin: 4),
        Item(id: "beanie", slot: .head, name: L("비니"), art: ["...W...", ".GGGGG.", "GGGGGGG", "WWWWWWW"], pin: 3),
        Item(id: "ribbon", slot: .head, name: L("리본"), art: ["PP...PP", "PPPrPPP", "PP...PP"], pin: 2),
        Item(id: "flower", slot: .head, name: L("꽃"), art: [".PP.", "PYYP", ".PP.", "..G."], pin: 3),
        Item(id: "round", slot: .eyes, name: L("동그란 안경"), art: ["KKK.KKK", "KcKKKcK", "KKK.KKK"], pin: 1),
        Item(id: "sun", slot: .eyes, name: L("선글라스"), art: ["KKKKKKK", ".KK.KK."], pin: 0),
        Item(id: "heart", slot: .eyes, name: L("하트 안경"), art: ["R.R.R.R", "RRRKRRR", ".R...R."], pin: 1),
        Item(id: "scarf", slot: .neck, name: L("목도리"), art: ["RRWRRWR", "RWRRWRR", "....RR.", "....R.."], pin: 0),
        Item(id: "bowtie", slot: .neck, name: L("나비넥타이"), art: ["R...R", "RRrRR", "R...R"], pin: 1),
        Item(id: "shirt-strawberry", slot: .shirt, name: L("딸기"), art: [], pin: 0, hex: "#FF7EA8"),
        Item(id: "shirt-mint", slot: .shirt, name: L("민트"), art: [], pin: 0, hex: "#3EC48F"),
        Item(id: "shirt-lavender", slot: .shirt, name: L("라벤더"), art: [], pin: 0, hex: "#9D86EE"),
        Item(id: "shirt-lemon", slot: .shirt, name: L("레몬"), art: [], pin: 0, hex: "#EDBE2B"),
        Item(id: "shirt-sky", slot: .shirt, name: L("하늘"), art: [], pin: 0, hex: "#5AAEF5"),
        Item(id: "shirt-white", slot: .shirt, name: L("흰"), art: [], pin: 0, hex: "#FFFFFF"),
        Item(id: "shirt-black", slot: .shirt, name: L("검정"), art: [], pin: 0, hex: "#333333"),
        // 첫눈 시즌 (web/season.json)
        Item(id: "s-earmuffs", slot: .head, name: L("귀마개"), art: [".KKKKKKK.", "K.......K", "PP.....PP", "PP.....PP"], pin: 1, season: true),
        Item(id: "s-snowcap", slot: .head, name: L("눈송이 털모자"), art: ["...W...", "..BBB..", ".BWBWB.", "BBBBBBB", "WWWWWWW"], pin: 4, season: true),
        Item(id: "s-antlers", slot: .head, name: L("사슴뿔"), art: ["n.n...n.n", ".nn...nn.", "..n...n.."], pin: 2, season: true),
        Item(id: "s-starglasses", slot: .eyes, name: L("별 안경"), art: [".Y...Y.", "YYYKYYY", ".Y...Y."], pin: 1, season: true),
        Item(id: "s-checkscarf", slot: .neck, name: L("체크 목도리"), art: ["gWgWgWg", "WgWgWgW", "....gW.", "....Wg."], pin: 0, season: true),
        Item(id: "s-bell", slot: .neck, name: L("방울 목걸이"), art: ["R.....R", ".RRRRR.", "...Y...", "...y..."], pin: 1, season: true),
        Item(id: "s-shirt-snow", slot: .shirt, name: L("눈꽃"), art: [], pin: 0, hex: "#E4F1FF", season: true),
        Item(id: "s-shirt-pine", slot: .shirt, name: L("솔잎"), art: [], pin: 0, hex: "#2F7D5B", season: true),
        Item(id: "s-shirt-berry", slot: .shirt, name: L("산딸기"), art: [], pin: 0, hex: "#B8325A", season: true),
    ]

    static func item(_ id: String?) -> Item? { id.flatMap { id in items.first { $0.id == id } } }
    static func items(_ slot: Slot) -> [Item] { items.filter { $0.slot == slot } }

    /// Nudges go no further than this many art px each way.
    static let nudgeLimit = 8

    // MARK: Store

    /// The store key of a look: the ready character's id, "custom:<uuid>", or "dog".
    static func key(_ look: SpriteLook) -> String {
        switch look.character {
        case .cat, .original: return look.readyID.map(baseID) ?? "dog"
        case .custom: return look.custom.map { "custom:\($0.id.uuidString)" } ?? "dog"
        case .dog: return "dog"
        }
    }

    /// An HD pack's id stands for its dot pair: one outfit for both.
    static func baseID(_ id: String) -> String { id.hasSuffix(RenderStyle.hdSuffix) ? String(id.dropLast(RenderStyle.hdSuffix.count)) : id }

    /// What the user put on that character (by AnimatedCharacter id), when the plugin is open.
    static func outfit(for id: String, settings: AppSettings = .shared) -> Outfit? { worn(settings.outfits[baseID(id)]) }

    /// `outfit` when there is something to draw and 옷 입히기 is open, else nil (nothing is drawn).
    static func worn(_ outfit: Outfit?) -> Outfit? {
        guard let outfit, !outfit.isEmpty, PluginGate.isOpen(.wardrobe) else { return nil }
        return outfit
    }

    // MARK: Anchors (pure)

    /// Where a frame's head is, in art px from the top left.
    struct Anchor: Equatable {
        /// Middle column of the head, its topmost opaque row, the head's width.
        var x: Int, top: Int, width: Int
        /// Height of the frame's opaque box.
        var height: Int

        var eyesY: Int { top + Int((0.30 * 0.42 * Double(height)).rounded()) }
        var neckY: Int { top + Int((0.45 * Double(height)).rounded()) }
        var band: Range<Int> { neckY..<(neckY + max(1, Int((0.30 * Double(height)).rounded()))) }
    }

    /// From the opaque pixels (alpha > 0): the top row, the box height, and the widest run of opaque columns in the
    /// top 12% of the box (so a tail tip up there does not pull the hat off the head). nil for an empty frame.
    static func anchor(_ rgba: [UInt8], w: Int, h: Int) -> Anchor? {
        func opaque(_ x: Int, _ y: Int) -> Bool { rgba[(y * w + x) * 4 + 3] > 0 }
        let rows = (0..<h).filter { y in (0..<w).contains { opaque($0, y) } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        let height = bottom - top + 1
        let band = top..<min(h, top + max(1, Int((0.12 * Double(height)).rounded(.up))))
        let cols = (0..<w).filter { x in band.contains { opaque(x, $0) } }
        var runs: [ClosedRange<Int>] = []
        for x in cols {
            if let last = runs.last, x - last.upperBound <= 2 { runs[runs.count - 1] = last.lowerBound...x } else { runs.append(x...x) }
        }
        guard let head = runs.max(by: { $0.count < $1.count }) else { return nil }
        return Anchor(x: (head.lowerBound + head.upperBound + 1) / 2, top: top, width: head.count, height: height)
    }

    /// One pose's anchors held within `slack` art px of its first frame (no jitter while it walks); the first frame's
    /// size for all. Empty frames take the first one's.
    static func steady(_ anchors: [Anchor?], slack: Int = 2) -> [Anchor?] {
        guard let first = anchors.compactMap({ $0 }).first else { return anchors }
        return anchors.map { a in
            guard let a else { return first }
            return Anchor(x: min(max(a.x, first.x - slack), first.x + slack), top: min(max(a.top, first.top - slack), first.top + slack),
                          width: first.width, height: first.height)
        }
    }

    // MARK: Drawing (pure)

    /// What `outfit` adds to a `w` x `h` frame (premultiplied RGBA, see-through elsewhere): the shirt tint over the
    /// body band (85%, leaving the darkest outline), then the stamps. `unit` is art px per canvas px (2 on a denser
    /// frame), so stamps and nudges keep their size on every character.
    static func overlay(_ rgba: [UInt8], w: Int, h: Int, outfit: Outfit, anchor a: Anchor, unit: Int = 1) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        if let hex = outfit.shirt {
            let c = RGBColor(hex: hex)
            for y in a.band where y >= 0 && y < h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    guard rgba[i + 3] >= 250 else { continue }
                    let luma = (0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2])) / 255
                    guard luma >= 0.2 else { continue }
                    out[i] = UInt8(Double(c.r) * 0.85); out[i + 1] = UInt8(Double(c.g) * 0.85); out[i + 2] = UInt8(Double(c.b) * 0.85)
                    out[i + 3] = UInt8(255 * 0.85)
                }
            }
        }
        let slots: [(Slot, String?, Int)] = [(.neck, outfit.neck, a.neckY), (.eyes, outfit.eyes, a.eyesY), (.head, outfit.head, a.top)]
        for (slot, id, y) in slots {
            guard let it = item(id), it.slot == slot, let sw = it.art.map(\.count).max(), sw > 0 else { continue }
            let s = min(max(1, Int((Double(a.width) / Double(sw)).rounded())), max(1, unit))
            let n = outfit.nudges?[slot.rawValue]
            let clamp = { (v: Int?) in min(max(v ?? 0, -nudgeLimit), nudgeLimit) * max(1, unit) }
            let left = a.x - sw * s / 2 + clamp(n?.dx), top = y - it.pin * s + clamp(n?.dy)
            for (r, row) in it.art.enumerated() {
                for (col, ch) in row.enumerated() {
                    guard let c = ink[ch] else { continue }
                    for dy in 0..<s {
                        for dx in 0..<s {
                            let x = left + col * s + dx, yy = top + r * s + dy
                            guard x >= 0, x < w, yy >= 0, yy < h else { continue }
                            let i = (yy * w + x) * 4
                            out[i] = c.r; out[i + 1] = c.g; out[i + 2] = c.b; out[i + 3] = 255
                        }
                    }
                }
            }
        }
        return out
    }

    /// `over` laid on `under` (both premultiplied RGBA of one size).
    static func composite(_ under: [UInt8], _ over: [UInt8]) -> [UInt8] {
        var out = under
        for i in stride(from: 0, to: min(under.count, over.count) - 3, by: 4) where over[i + 3] > 0 {
            let k = 255 - Int(over[i + 3])
            for c in 0..<4 { out[i + c] = UInt8(min(255, Int(over[i + c]) + Int(under[i + c]) * k / 255)) }
        }
        return out
    }

    /// Pixel frames (each pose's rgba, `w` wide) wearing `outfit`, at their own resolution; as they are when nil.
    static func dress(_ poses: [[[UInt8]]], outfit: Outfit?) -> [[[UInt8]]] {
        guard let outfit, !outfit.isEmpty else { return poses }
        return poses.map { frames in
            let sizes = frames.map(size)
            let anchors = steady(zip(frames, sizes).map { anchor($0, w: $1.w, h: $1.h) })
            return zip(frames, zip(sizes, anchors)).map { f, sa in
                guard let a = sa.1 else { return f }
                return composite(f, overlay(f, w: sa.0.w, h: sa.0.h, outfit: outfit, anchor: a, unit: sa.0.w / SpriteCanvas.width))
            }
        }
    }

    /// The shared canvas or a custom character's denser one, by byte count.
    private static func size(_ rgba: [UInt8]) -> (w: Int, h: Int) {
        rgba.count == CustomSprite.w * CustomSprite.h * 4 ? (CustomSprite.w, CustomSprite.h) : (SpriteCanvas.width, SpriteCanvas.height)
    }

    // MARK: Images

    /// One pose's (or extra's) images wearing `outfit`: each frame read back at `grid` art px (its own pixels for pixel
    /// art), the stamps laid over it, crisp for pixel art and smoothed for `smooth` art. As they are when nil.
    static func dress(_ frames: [NSImage], outfit: Outfit?, grid: (w: Int, h: Int), smooth: Bool) -> [NSImage] {
        guard let outfit, !outfit.isEmpty, grid.w > 0, grid.h > 0 else { return frames }
        let rasters = frames.map { RenderStyle.raster($0, width: grid.w, height: grid.h, smooth: smooth) }
        let anchors = steady(rasters.map { anchor($0, w: grid.w, h: grid.h) })
        let unit = grid.w / SpriteCanvas.width
        return frames.indices.map { i in
            guard let a = anchors[i] else { return frames[i] }
            let over = overlay(rasters[i], w: grid.w, h: grid.h, outfit: outfit, anchor: a, unit: unit)
            let art: CGImage
            if smooth {
                let (big, bw, bh) = RenderStyle.smoothed(over, w: grid.w, h: grid.h)
                art = DogRenderer.cgImage(big, width: bw, height: bh, interpolate: true)
            } else {
                art = DogRenderer.cgImage(over, width: grid.w, height: grid.h)
            }
            let base = frames[i]
            return NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                guard let ctx = NSGraphicsContext.current else { return true }
                ctx.imageInterpolation = smooth ? .high : .none
                ctx.cgContext.interpolationQuality = smooth ? .high : .none
                ctx.cgContext.draw(art, in: rect)
                return true
            }
        }
    }
}
