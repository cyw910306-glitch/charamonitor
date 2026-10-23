import AppKit

/// All frames of one character (the dog of `profile`, a custom one, or a ready-made
/// AnimatedCharacter), rendered once. Swapping `frames(for:)[i]` is the only per-frame work.
/// StatusItemController and the dashboard only ever talk to this type.
final class DogSpriteCache {
    static let canvasWidth = SpriteCanvas.width
    static let canvasHeight = SpriteCanvas.height

    let imageSize: NSSize
    private let framesByPose: [[NSImage]]   // indexed by DogPose.rawValue
    private let extras: [ExtraMotion: [NSImage]]
    /// A ready-made character's further takes of an extra (AnimatedCharacter.extraVariants after the first), and the
    /// lines of every take (AnimatedCharacter.lines).
    private var takes: [ExtraMotion: [[NSImage]]] = [:]
    private var takeLines: [ExtraMotion: [[String]]] = [:]
    /// The character's own seconds per frame (AnimatedCharacter.frameSeconds), by pose name or extra raw value.
    private var seconds: [String: TimeInterval] = [:]
    /// Illustration frames (an HD pack): players draw them with high-quality interpolation.
    private(set) var smooth = false

    /// `custom` (a custom character's frames) wins over the dog when given. `style` 일러스트 smooths the pixel art.
    /// `outfit` (옷 입히기) is drawn into the art before it is scaled or smoothed.
    init(profile: DogProfile, custom: [[[UInt8]]]? = nil, pixelSize: CGFloat = 1, style: RenderStyle = .current, outfit: Outfit? = nil) {
        let size = NSSize(width: CGFloat(Self.canvasWidth) * pixelSize, height: CGFloat(Self.canvasHeight) * pixelSize)
        imageSize = size
        // ponytail: no Mac display is 3x, so big dashboard sprites skip the 3x copy (about 10 MB saved).
        let scales: [CGFloat] = pixelSize <= 2 ? [1, 2, 3] : [1, 2]
        let worn = Wardrobe.worn(outfit)
        let rgba = Wardrobe.dress(custom ?? DogRenderer.frames(profile), outfit: worn)
        let smooth = style == .illustration
        let draw = { (f: [UInt8]) -> NSImage in
            guard smooth else { return Self.image(DogRenderer.art(f), size: size, scales: scales, oneX: DogRenderer.art1x(f)) }
            let w = f.count == CustomSprite.w * CustomSprite.h * 4 ? CustomSprite.w : Self.canvasWidth
            return Self.scaled(RenderStyle.illustrated(f, w: w, h: f.count / 4 / w), by: pixelSize, smooth: true)
        }
        self.smooth = smooth
        framesByPose = rgba.map { $0.map(draw) }
        let extraRGBA = custom != nil ? nil : BuiltinExtras.dog?(profile)
        extras = (extraRGBA ?? [:]).filter { !$0.value.isEmpty }.mapValues { Wardrobe.dress([$0], outfit: worn)[0].map(draw) }
    }

    /// A ready-made character, scaled by `pixelSize` (a cat breed, an original), drawn in `style`, wearing `outfit`
    /// (nil: what the user put on it in 옷 입히기; .some(nil): nothing).
    init(_ character: any AnimatedCharacter, pixelSize: CGFloat = 1, style: RenderStyle = .current, outfit: Outfit?? = nil) {
        let base = character.imageSize
        imageSize = NSSize(width: base.width * pixelSize, height: base.height * pixelSize)
        let smooth = style.smooth(character.smooth)
        let worn = Wardrobe.worn(outfit ?? Wardrobe.outfit(for: character.id))
        // Pixel frames are read back at their own art px (a pack's 2 per point, or the pixelated HD pair's 2).
        let density = character.smooth ? 2 : max(1, character.artDensity)
        let grid = smooth ? (w: Int(base.width) * 2, h: Int(base.height) * 2) : (w: Int(base.width) * density, h: Int(base.height) * density)
        let draw = { (set: [NSImage]) in
            Wardrobe.dress(set.map { style.restyle($0, drawnSmooth: character.smooth, density: character.artDensity) }, outfit: worn, grid: grid, smooth: smooth)
                .map { Self.scaled($0, by: pixelSize, smooth: smooth) }
        }
        let walk = character.frames(for: .walk)
        framesByPose = DogPose.allCases.map { pose in
            let f = character.frames(for: pose)
            return draw(f.isEmpty ? walk : f)
        }
        var extras: [ExtraMotion: [NSImage]] = [:]
        for m in ExtraMotion.allCases {
            if let f = character.frames(forExtra: m), !f.isEmpty { extras[m] = draw(f) }
            let more = character.extraVariants(m).dropFirst().filter { !$0.isEmpty }
            if extras[m] != nil, !more.isEmpty { takes[m] = more.map(draw) }
            if extras[m] != nil { takeLines[m] = (0...more.count).map { character.lines(forExtra: m, variant: $0) } }
        }
        self.extras = extras
        seconds = character.frameSeconds
        self.smooth = smooth
    }

    /// A 실사 photo character, drawn from its source at each backing scale (never upscaled from a bitmap), wearing
    /// `outfit` smoothed over it.
    init(real: RealSprite, pixelSize: CGFloat = 1, outfit: Outfit? = nil) {
        imageSize = NSSize(width: CGFloat(Self.canvasWidth) * pixelSize, height: CGFloat(Self.canvasHeight) * pixelSize)
        let scales: [CGFloat] = pixelSize <= 2 ? [1, 2, 3] : [1, 2]
        let worn = Wardrobe.worn(outfit), grid = (w: Self.canvasWidth * 2, h: Self.canvasHeight * 2)
        framesByPose = real.poseImages(pixelSize: pixelSize, scales: scales).map { Wardrobe.dress($0, outfit: worn, grid: grid, smooth: true) }
        var extras: [ExtraMotion: [NSImage]] = [:]
        for m in ExtraMotion.allCases {
            let f = real.extraImages(m, pixelSize: pixelSize, scales: scales)
            if !f.isEmpty { extras[m] = Wardrobe.dress(f, outfit: worn, grid: grid, smooth: true) }
        }
        self.extras = extras
    }

    /// What `settings` puts in the menu bar, in its 그림 스타일.
    convenience init(_ look: SpriteLook, pixelSize: CGFloat) {
        let custom = look.custom?.styled(look.style)
        if let real = custom?.real {
            self.init(real: real, pixelSize: pixelSize, outfit: look.outfit)
        } else if let ready = look.ready {
            self.init(ready, pixelSize: pixelSize, style: look.style, outfit: .some(look.outfit))
        } else {
            self.init(profile: look.profile, custom: custom?.frames, pixelSize: pixelSize, style: look.style, outfit: look.outfit)
        }
    }

    func frames(for pose: DogPose) -> [NSImage] { framesByPose[pose.rawValue] }

    /// The extra moments this character can play (SituationEngine's `available`).
    var availableExtras: Set<ExtraMotion> { Set(extras.keys) }

    /// nil when this character has no frames for `motion`; the caller keeps the pose.
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { extras[motion] }

    /// What to play now: the extra moment when this character has it (take `variant` when it has that many), else the pose.
    func frames(for pose: DogPose, extra: ExtraMotion?, variant: Int = 0) -> [NSImage] {
        guard let extra, let first = extras[extra] else { return frames(for: pose) }
        let more = takes[extra] ?? []
        return variant > 0 && variant <= more.count ? more[variant - 1] : first
    }

    /// How many takes of `motion` this character has drawn (0 = none).
    func takeCount(_ motion: ExtraMotion) -> Int { extras[motion] == nil ? 0 : 1 + (takes[motion]?.count ?? 0) }

    /// The character's own lines for take `variant` of `motion` (pack.json "say"), empty for most.
    func lines(forExtra motion: ExtraMotion, variant: Int) -> [String] {
        let all = takeLines[motion] ?? []
        return all.indices.contains(variant) ? all[variant] : []
    }

    /// Seconds per frame of an extra moment (FrameTiming, CharaCore).
    static func extraFrameDuration(_ motion: ExtraMotion?) -> TimeInterval { FrameTiming.extra(motion) }

    /// Seconds per frame of what plays now: the character's own timing when it sets one, else the app's.
    func frameDuration(for pose: DogPose, cpu: Double, extra: ExtraMotion?) -> TimeInterval {
        if let extra { return seconds[extra.rawValue] ?? Self.extraFrameDuration(extra) }
        return seconds[FrameArt.key(pose)] ?? Self.frameDuration(for: pose, cpu: cpu)
    }

    /// `image` drawn `k` times larger, rasterized lazily at whatever backing scale shows it. Detailed art scales
    /// smoothly from its best rep; pixel art that has to be magnified stays blocky. `smooth` art is never blocky.
    static func scaled(_ image: NSImage, by k: CGFloat, smooth: Bool = false) -> NSImage {
        guard k != 1 else { return image }
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        return NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current
            let devicePixels = rect.width * abs(ctx?.cgContext.ctm.a ?? 1)
            let rep = image.bestRepresentation(for: rect, context: ctx, hints: nil)
            ctx?.imageInterpolation = !smooth && CGFloat(rep?.pixelsWide ?? 0) < devicePixels ? .none : .high
            image.draw(in: rect)
            return true
        }
    }

    /// Seconds per frame of a pose (FrameTiming, CharaCore).
    static func frameDuration(for pose: DogPose, cpu: Double) -> TimeInterval { FrameTiming.pose(pose, cpu: cpu) }

    /// Nearest-neighbour copies for each backing scale, so the dog is crisp everywhere.
    /// `oneX`, when it matches a scale's pixel size exactly, is used there instead of scaling `cg` down.
    private static func image(_ cg: CGImage, size: NSSize, scales: [CGFloat], oneX: CGImage) -> NSImage {
        let image = NSImage(size: size)
        for scale in scales {
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
            guard let ctx = DogRenderer.context(width: w, height: h) else { continue }
            // Custom characters carry 2 art px per point: halved by hand on 1x, pixel-exact from 2x up.
            let source = cg.width > w && oneX.width <= w ? oneX : cg
            ctx.interpolationQuality = source.width > w ? .high : .none
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: scaled)
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }
}

/// The Mac's frame images on top of CharaCore's DogRenderer.
extension DogRenderer {
    /// Any character's frame as an image: the shared canvas, or a custom character's denser one.
    static func art(_ rgba: [UInt8]) -> CGImage {
        rgba.count == CustomSprite.w * CustomSprite.h * 4 ? cgImage(rgba, width: CustomSprite.w, height: CustomSprite.h) : cgImage(rgba)
    }

    /// Any character's frame at 1 art px per point.
    static func art1x(_ rgba: [UInt8]) -> CGImage {
        rgba.count == CustomSprite.w * CustomSprite.h * 4 ? cgImage(CustomSprite.halved(rgba)) : cgImage(rgba)
    }
}

/// Everything that decides the menu bar frames. Names are blanked, so renaming never re-renders.
struct SpriteLook: Equatable {
    var profile: DogProfile
    var character: SpriteCharacter
    var custom: CustomCharacter?
    /// The cat or original shown, by id (nil for the others), with its 꾸미기 colours.
    var readyID: String?
    var colors: [String: RGBColor]?
    var cat: CatProfile?
    var style: RenderStyle
    /// 옷 입히기 drawn over every frame (stream 3 fills it from the store; a friend's comes with their look).
    var outfit: Outfit?

    init(_ settings: AppSettings) {
        style = settings.renderStyle
        profile = settings.profile
        profile.name = ""
        custom = settings.activeCustom
        custom?.name = ""
        character = settings.shownCharacter
        readyID = character == .cat ? settings.catID : character == .original ? settings.originalID : nil
        colors = character == .original ? readyID.flatMap { settings.characterColors[$0] } : nil
        cat = character == .cat ? readyID.flatMap { settings.catLooks[$0] } : nil
        outfit = Wardrobe.worn(settings.outfits[Wardrobe.key(self)])
    }

    /// The catalog character this look shows, if it is one.
    var ready: (any AnimatedCharacter)? {
        switch character {
        case .cat: return CatCatalog.character(readyID).map { CharacterColors.cat($0, cat) }
        case .original:
            let id = readyID.map { RenderStyle.paired($0, style, has: RenderStyle.hasOriginal) }   // a pack's -hd pair
            return OriginalCatalog.character(id).map { CharacterColors.apply(colors, to: $0) }
        default: return nil
        }
    }
}

extension SpriteLook {
    /// A paired friend's look: their built-in character with its 꾸미기, or the plain dog when this Mac lacks it.
    init(friend f: FriendLook) {
        self.init(AppSettings.shared)
        custom = nil
        profile = f.profile ?? .defaultDog
        profile.name = ""
        character = f.character == .custom ? .dog : f.character
        readyID = character == .dog ? nil : f.id
        colors = character == .original ? f.colors : nil
        cat = character == .cat ? f.cat : nil
        outfit = f.outfit
        if character != .dog, ready == nil { character = .dog; readyID = nil; colors = nil; cat = nil }
    }
}

/// DogExtras (CharaCore) as menu bar images.
extension DogExtras {
    /// NSImages at `pixelSize` points per art pixel, crisp at 1x, 2x (and 3x for small sizes). `special` is empty.
    static func frames(profile: DogProfile, pixelSize: CGFloat = 1, motion: ExtraMotion) -> [NSImage] {
        rgba(profile, motion).map { ExtraImages.image($0, pixelSize: pixelSize) }
    }
}

extension ExtraImages {
    /// Nearest-neighbour copies per backing scale, like DogSpriteCache does for the normal poses.
    static func image(_ rgba: [UInt8], pixelSize: CGFloat) -> NSImage {
        let size = NSSize(width: CGFloat(SpriteCanvas.width) * pixelSize, height: CGFloat(SpriteCanvas.height) * pixelSize)
        let cg = DogRenderer.cgImage(rgba)
        let image = NSImage(size: size)
        for scale in (pixelSize <= 2 ? [1, 2, 3] : [1, 2]) as [CGFloat] {
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
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
}
