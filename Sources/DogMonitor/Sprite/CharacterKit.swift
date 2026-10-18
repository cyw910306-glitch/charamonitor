import AppKit

// The contract ready-made character modules (cats, originals) build against. A module ships values conforming to
// AnimatedCharacter and lists them in CatCatalog.all or OriginalCatalog.all; nothing else needs wiring.

/// One ready-made character: every CPU pose plus optional extra moments, as finished images.
protocol AnimatedCharacter {
    /// Stable and saved in settings (AppSettings.catID / originalID). Never change a shipped id.
    var id: String { get }
    /// Korean name for tiles, the preview page and the dashboard header. No famous IP names.
    var displayName: String { get }
    /// Frames for a CPU pose in play order, each `imageSize` points. Never empty.
    /// Carry a bitmap rep of at least 2x for the Retina menu bar; reps up to 8x keep the 4x preview page sharp.
    func frames(for pose: DogPose) -> [NSImage]
    /// Frames for a battery or special moment, or nil when this character has none (the pose plays instead).
    func frames(forExtra motion: ExtraMotion) -> [NSImage]?
    /// Size in points at menu bar scale: 20 high fits the menu bar (the dog is 34 x 20).
    var imageSize: NSSize { get }
    /// Name of the `.special` move for the preview page (originals), nil for the generic label.
    var specialTitle: String? { get }
    /// One line under the hero image on the preview page, nil for none.
    var previewBlurb: String? { get }
    /// Seconds per frame in place of the app's timing, by DogPose name ("walk") or ExtraMotion raw value ("special").
    var frameSeconds: [String: TimeInterval] { get }
    /// Illustration frames (an HD pack): every size is drawn with high-quality interpolation, never nearest.
    var smooth: Bool { get }
    /// Art px per point of pixel frames (a pixel pack's 2), so 일러스트 smooths them at their own detail.
    var artDensity: Int { get }
    /// Its own 말투 (Persona.resolve, before the kind preset) and 울음소리 sounds; nil and [] use the kind's.
    var voice: PersonaStyle? { get }
    var cries: [String] { get }
    /// Every drawn take of an extra moment, the first being frames(forExtra:); the menu bar plays one per showing
    /// (never the same twice in a row). Empty when the character has none.
    func extraVariants(_ motion: ExtraMotion) -> [[NSImage]]
    /// The character's own lines for take `variant` of `motion`, said when a moment (SituationEngine.play) shows it.
    func lines(forExtra motion: ExtraMotion, variant: Int) -> [String]
}

extension AnimatedCharacter {
    var specialTitle: String? { nil }
    var previewBlurb: String? { nil }
    var frameSeconds: [String: TimeInterval] { [:] }
    var smooth: Bool { false }
    var artDensity: Int { 1 }
    var voice: PersonaStyle? { nil }
    var cries: [String] { [] }
    func extraVariants(_ motion: ExtraMotion) -> [[NSImage]] { frames(forExtra: motion).map { [$0] } ?? [] }
    func lines(forExtra motion: ExtraMotion, variant: Int) -> [String] { [] }
}

/// Moments outside the CPU poses.
enum ExtraMotion: String, CaseIterable, Codable {
    case hungry /*배터리 부족: 먹을 것 찾기*/, eat /*충전 중: 먹기*/, special /*특수 기술*/

    var label: String {
        switch self {
        case .hungry: return L("배고파서 먹을 걸 찾는 중")
        case .eat: return L("충전하며 냠냠")
        case .special: return L("특수 기술!")
        }
    }
    // When each one plays: SituationEngine (Metrics/SituationEngine.swift), driven by StatusItemController.
}

/// Cat breeds. Wiring is one line: `CatCatalog.all = <the cats module's list>` (or replace `[]` below).
enum CatCatalog {
    static var all: [any AnimatedCharacter] = CatCharacter.presets
    static func character(_ id: String?) -> (any AnimatedCharacter)? { all.first { $0.id == id } }
    /// Tiles shown while `all` is empty, greyed and not selectable.
    static let placeholders: [PlaceholderCharacter] = [
        PlaceholderCharacter(id: "cat-korean-shorthair", displayName: L("코리안 숏헤어"), look: "shiba"),
        PlaceholderCharacter(id: "cat-russian-blue", displayName: L("러시안 블루"), look: "husky"),
        PlaceholderCharacter(id: "cat-persian", displayName: L("페르시안"), look: "maltipoo"),
    ]
}

/// Original characters: the built-in ones, then the user's local packs (CharacterPack.loadAll, at launch).
/// Removed ids (the six set-1/set-2 characters dropped in 5.x) simply no longer resolve, so saved settings show the dog.
enum OriginalCatalog {
    static var all: [any AnimatedCharacter] = OriginalCharacterSet2.all
    static func character(_ id: String?) -> (any AnimatedCharacter)? { all.first { $0.id == id } }
}

/// Extra moments for the built-in dog, as RGBA frames on its 34 x 20 canvas (DogRenderer.frames shape).
/// A module that draws them sets the closure; nil means the pose plays.
enum BuiltinExtras {
    static var dog: ((DogProfile) -> [ExtraMotion: [[UInt8]]])? = DogExtras.byMotion
}

/// Stand-in tile until a catalog is wired: a preset dog's frames under a future name. Never selectable.
struct PlaceholderCharacter: AnimatedCharacter {
    let id: String
    let displayName: String
    /// DogPreset id whose frames stand in.
    let look: String

    var imageSize: NSSize { NSSize(width: DogSpriteCache.canvasWidth, height: DogSpriteCache.canvasHeight) }
    func frames(for pose: DogPose) -> [NSImage] {
        let profile = DogProfile.presets.first { $0.id == look }?.profile ?? .defaultDog
        return DogSpriteCache(profile: profile, style: .auto).frames(for: pose)
    }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { nil }
}

/// Hand-drawn pixel frames as menu bar images, shared by the originals and local packs. Frames are RGBA rows of
/// `width` x `height` px drawn into the 34 x 20 pt canvas (34 x 20 for frames.json art, 68 x 40 for a pack).
enum BarArt {
    static let size = NSSize(width: DogSpriteCache.canvasWidth, height: DogSpriteCache.canvasHeight)

    /// Dark-bar outline tone: the art's own dark outline vanishes on a #2A2A2A bar.
    static let darkBarOutline: [UInt8] = [0x8C, 0x86, 0xA8]

    /// The outline colour: the commonest colour on the silhouette's edge (pixels touching transparency) of `frame`.
    /// Read from the art, since not every character keys its outline "o".
    static func outlineColor(_ frame: [UInt8], width w: Int = FrameArt.width, height h: Int = FrameArt.height) -> PixelColor {
        func clear(_ x: Int, _ y: Int) -> Bool { x < 0 || y < 0 || x >= w || y >= h || frame[(y * w + x) * 4 + 3] == 0 }
        var counts: [UInt32: Int] = [:]
        for y in 0..<h {
            for x in 0..<w where !clear(x, y) && (clear(x - 1, y) || clear(x + 1, y) || clear(x, y - 1) || clear(x, y + 1)) {
                let i = (y * w + x) * 4
                counts[UInt32(frame[i]) << 16 | UInt32(frame[i + 1]) << 8 | UInt32(frame[i + 2]), default: 0] += 1
            }
        }
        let k = counts.max { $0.value < $1.value }?.key ?? 0
        return PixelColor(r: UInt8(k >> 16 & 0xFF), g: UInt8(k >> 8 & 0xFF), b: UInt8(k & 0xFF))
    }

    /// `rgba` with every outline pixel that touches transparency lifted to `darkBarOutline`. Interior pixels of the
    /// same colour (eyes, mouth) stay dark.
    static func darkBarVariant(_ rgba: [UInt8], outline: PixelColor, width w: Int = FrameArt.width, height h: Int = FrameArt.height) -> [UInt8] {
        var out = rgba
        func clear(_ x: Int, _ y: Int) -> Bool { x < 0 || y < 0 || x >= w || y >= h || rgba[(y * w + x) * 4 + 3] == 0 }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard rgba[i + 3] != 0, rgba[i] == outline.r, rgba[i + 1] == outline.g, rgba[i + 2] == outline.b,
                      clear(x - 1, y) || clear(x + 1, y) || clear(x, y - 1) || clear(x, y + 1) else { continue }
                out[i] = darkBarOutline[0]; out[i + 1] = darkBarOutline[1]; out[i + 2] = darkBarOutline[2]
            }
        }
        return out
    }

    /// One frame that draws its light-bar art, or the lifted-outline copy when drawn in a dark appearance (the
    /// status button draws with the menu bar's appearance).
    static func adaptive(_ rgba: [UInt8], outline: PixelColor, width: Int = FrameArt.width, height: Int = FrameArt.height) -> NSImage {
        let light = image(rgba, width: width, height: height)
        let dark = image(darkBarVariant(rgba, outline: outline, width: width, height: height), width: width, height: height)
        return NSImage(size: light.size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
    }

    /// Nearest-neighbour copies at each backing scale the art does not undercut (34 px art: 1x, 2x; 68 px: 2x), plus
    /// 8x so the 4x preview page stays sharp on Retina.
    static func image(_ rgba: [UInt8], width: Int = FrameArt.width, height: Int = FrameArt.height) -> NSImage {
        let image = NSImage(size: size)
        let cg = DogRenderer.cgImage(rgba, width: width, height: height)
        let density = CGFloat(width) / size.width
        for scale in ([1, 2, 8] as [CGFloat]).filter({ $0 >= density }) {
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = DogRenderer.context(width: w, height: h) else { continue }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: scaled)
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    /// An illustration frame (premultiplied, shouldInterpolate on) as a menu bar image: high-quality 1x and 2x copies
    /// made ahead, so the bar never resamples, plus the frame itself for the big views. No outline lift: the art's own
    /// outline stays as drawn.
    static func smooth(_ cg: CGImage) -> NSImage {
        let image = NSImage(size: size)
        var reps = [1, 2].map { Int(size.width) * $0 }.filter { $0 < cg.width }.compactMap { w in
            downsample(cg, width: w, height: w * cg.height / cg.width)
        }
        reps.append(cg)
        for r in reps {
            let rep = NSBitmapImageRep(cgImage: r)
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    /// `cg` shrunk to `w` x `h` by halving steps, then one last step, each at high quality (no aliasing on big ratios).
    static func downsample(_ cg: CGImage, width w: Int, height h: Int) -> CGImage? {
        var src = cg
        while true {
            let half = src.width > w * 2
            let tw = half ? src.width / 2 : w, th = half ? src.height / 2 : h
            guard let ctx = DogRenderer.context(width: tw, height: th) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: tw, height: th))
            guard let next = ctx.makeImage() else { return nil }
            if !half { return next }
            src = next
        }
    }
}
