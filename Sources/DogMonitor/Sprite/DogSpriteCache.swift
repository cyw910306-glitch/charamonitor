import AppKit

/// All frames of one character (the dog of `profile`, a custom one, or a ready-made
/// AnimatedCharacter), rendered once. Swapping `frames(for:)[i]` is the only per-frame work.
/// StatusItemController and the dashboard only ever talk to this type.
final class DogSpriteCache {
    static let canvasWidth = 34
    static let canvasHeight = 20

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
    init(profile: DogProfile, custom: [[[UInt8]]]? = nil, pixelSize: CGFloat = 1, style: RenderStyle = .current) {
        let size = NSSize(width: CGFloat(Self.canvasWidth) * pixelSize, height: CGFloat(Self.canvasHeight) * pixelSize)
        imageSize = size
        // ponytail: no Mac display is 3x, so big dashboard sprites skip the 3x copy (about 10 MB saved).
        let scales: [CGFloat] = pixelSize <= 2 ? [1, 2, 3] : [1, 2]
        let rgba = custom ?? DogRenderer.frames(profile)
        let smooth = style == .illustration
        let draw = { (f: [UInt8]) -> NSImage in
            guard smooth else { return Self.image(DogRenderer.art(f), size: size, scales: scales, oneX: DogRenderer.art1x(f)) }
            let w = f.count == CustomSprite.w * CustomSprite.h * 4 ? CustomSprite.w : Self.canvasWidth
            return Self.scaled(RenderStyle.illustrated(f, w: w, h: f.count / 4 / w), by: pixelSize, smooth: true)
        }
        self.smooth = smooth
        framesByPose = rgba.map { $0.map(draw) }
        let extraRGBA = custom != nil ? nil : BuiltinExtras.dog?(profile)
        extras = (extraRGBA ?? [:]).filter { !$0.value.isEmpty }.mapValues { $0.map(draw) }
    }

    /// A ready-made character, scaled by `pixelSize` (a cat breed, an original), drawn in `style`.
    init(_ character: any AnimatedCharacter, pixelSize: CGFloat = 1, style: RenderStyle = .current) {
        let base = character.imageSize
        imageSize = NSSize(width: base.width * pixelSize, height: base.height * pixelSize)
        let smooth = style.smooth(character.smooth)
        let draw = { (f: NSImage) in
            Self.scaled(style.restyle(f, drawnSmooth: character.smooth, density: character.artDensity), by: pixelSize, smooth: smooth)
        }
        let walk = character.frames(for: .walk)
        framesByPose = DogPose.allCases.map { pose in
            let f = character.frames(for: pose)
            return (f.isEmpty ? walk : f).map(draw)
        }
        var extras: [ExtraMotion: [NSImage]] = [:]
        for m in ExtraMotion.allCases {
            if let f = character.frames(forExtra: m), !f.isEmpty { extras[m] = f.map(draw) }
            let more = character.extraVariants(m).dropFirst().filter { !$0.isEmpty }
            if extras[m] != nil, !more.isEmpty { takes[m] = more.map { $0.map(draw) } }
            if extras[m] != nil { takeLines[m] = (0...more.count).map { character.lines(forExtra: m, variant: $0) } }
        }
        self.extras = extras
        seconds = character.frameSeconds
        self.smooth = smooth
    }

    /// A 실사 photo character, drawn from its source at each backing scale (never upscaled from a bitmap).
    init(real: RealSprite, pixelSize: CGFloat = 1) {
        imageSize = NSSize(width: CGFloat(Self.canvasWidth) * pixelSize, height: CGFloat(Self.canvasHeight) * pixelSize)
        let scales: [CGFloat] = pixelSize <= 2 ? [1, 2, 3] : [1, 2]
        framesByPose = real.poseImages(pixelSize: pixelSize, scales: scales)
        var extras: [ExtraMotion: [NSImage]] = [:]
        for m in ExtraMotion.allCases {
            let f = real.extraImages(m, pixelSize: pixelSize, scales: scales)
            if !f.isEmpty { extras[m] = f }
        }
        self.extras = extras
    }

    /// What `settings` puts in the menu bar, in its 그림 스타일.
    convenience init(_ look: SpriteLook, pixelSize: CGFloat) {
        let custom = look.custom?.styled(look.style)
        if let real = custom?.real {
            self.init(real: real, pixelSize: pixelSize)
        } else if let ready = look.ready {
            self.init(ready, pixelSize: pixelSize, style: look.style)
        } else {
            self.init(profile: look.profile, custom: custom?.frames, pixelSize: pixelSize, style: look.style)
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

    /// Seconds per frame of an extra moment: searching is slow, eating brisk, special moves quick.
    static func extraFrameDuration(_ motion: ExtraMotion?) -> TimeInterval {
        switch motion {
        case .hungry: return 0.38
        case .eat: return 0.22
        case .special, nil: return 0.12
        }
    }

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

    /// Seconds per frame. Speeds up smoothly inside each pose's CPU band (DogPose.forCPU thresholds).
    static func frameDuration(for pose: DogPose, cpu: Double) -> TimeInterval {
        let band: (lo: Double, hi: Double, slow: Double, fast: Double)
        switch pose {
        case .lying: return 0.6
        case .slowWalk: band = (0.05, 0.15, 0.22, 0.18)
        case .walk: band = (0.15, 0.30, 0.16, 0.12)
        case .fastWalk: band = (0.30, 0.45, 0.12, 0.095)
        case .run: band = (0.45, 0.65, 0.09, 0.07)
        case .sprint: band = (0.65, 0.85, 0.07, 0.055)
        case .exhausted: band = (0.85, 1.0, 0.055, 0.045)
        }
        let c = cpu.isFinite ? cpu : 0
        let t = min(1, max(0, (c - band.lo) / (band.hi - band.lo)))
        return max(0.04, band.slow + (band.fast - band.slow) * t)
    }

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

/// Paints every pose of a profile and centres the dog on the shared canvas.
enum DogRenderer {
    private static let margin = 12

    /// RGBA bytes per frame, grouped by pose in DogPose order.
    static func frames(_ profile: DogProfile) -> [[[UInt8]]] {
        let w = DogSpriteCache.canvasWidth
        let grids = grids(profile)
        let span = union(grids)
        // One offset per profile, so switching poses never shifts the dog sideways.
        let x0 = span.map { $0.minX - (w - ($0.maxX - $0.minX + 1)) / 2 } ?? margin
        let palette = DogPalette(profile)
        return grids.map { $0.map { $0.rgba(palette, x0: x0, outWidth: w) } }
    }

    /// Every frame painted on a scratch canvas wide enough for any dog, grouped by pose in DogPose order.
    static func grids(_ profile: DogProfile) -> [[ArtGrid]] {
        let painter = DogPainter(profile)
        return DogPose.allCases.map { pose in
            pose.rigs.map { rig in
                var g = ArtGrid(width: DogSpriteCache.canvasWidth + margin * 2, height: DogSpriteCache.canvasHeight)
                painter.paint(rig, into: &g, originX: margin + 8)
                return g
            }
        }
    }

    /// Horizontal extent of the dog over all frames, or nil when nothing was painted.
    static func union(_ grids: [[ArtGrid]]) -> (minX: Int, maxX: Int)? {
        let boxes = grids.joined().compactMap(\.bounds)
        guard let lo = boxes.map(\.minX).min(), let hi = boxes.map(\.maxX).max() else { return nil }
        return (lo, hi)
    }

    /// `interpolate` off keeps pixel art blocky wherever it is drawn; illustrations (HD packs) turn it on.
    static func cgImage(_ rgba: [UInt8], width: Int = DogSpriteCache.canvasWidth, height: Int = DogSpriteCache.canvasHeight,
                        interpolate: Bool = false) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: interpolate, intent: .defaultIntent)!
    }

    /// Any character's frame as an image: the shared canvas, or a custom character's denser one.
    static func art(_ rgba: [UInt8]) -> CGImage {
        rgba.count == CustomSprite.w * CustomSprite.h * 4 ? cgImage(rgba, width: CustomSprite.w, height: CustomSprite.h) : cgImage(rgba)
    }

    /// Any character's frame at 1 art px per point.
    static func art1x(_ rgba: [UInt8]) -> CGImage {
        rgba.count == CustomSprite.w * CustomSprite.h * 4 ? cgImage(CustomSprite.halved(rgba)) : cgImage(rgba)
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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
