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
extension BarArt {
    static let size = NSSize(width: DogSpriteCache.canvasWidth, height: DogSpriteCache.canvasHeight)

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
}
