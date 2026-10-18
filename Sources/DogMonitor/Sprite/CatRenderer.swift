import AppKit

/// Paints every pose and extra motion of a cat and centres it on the shared 34x20 canvas.
enum CatRenderer {
    private static let margin = 12

    /// RGBA frames on the shared canvas, poses in DogPose order (drop-in for DogSpriteCache's `custom:`).
    static func frames(_ profile: CatProfile) -> [[[UInt8]]] { render(profile).poses }

    /// RGBA frames of one extra motion, or nil when cats have none (special).
    static func frames(_ profile: CatProfile, extra motion: ExtraMotion) -> [[UInt8]]? { render(profile).extras[motion] }

    static func render(_ profile: CatProfile) -> (poses: [[[UInt8]]], extras: [ExtraMotion: [[UInt8]]]) {
        let w = DogSpriteCache.canvasWidth
        let poses = DogPose.allCases.map { CatRig.rigs($0) }
        let extras = ExtraMotion.allCases.compactMap { m in CatRig.rigs(m).map { (m, $0) } }
        let g = grids(profile, poses + extras.map(\.1))
        // One offset for everything, so switching poses or starting to eat never shifts the cat sideways.
        let span = union(g)
        let x0 = span.map { $0.minX - (w - ($0.maxX - $0.minX + 1)) / 2 } ?? margin
        let palette = CatPalette(profile)
        let rgba = g.map { $0.map { $0.rgba(palette, x0: x0, outWidth: w) } }
        var byMotion: [ExtraMotion: [[UInt8]]] = [:]
        for (i, e) in extras.enumerated() { byMotion[e.0] = rgba[poses.count + i] }
        return (Array(rgba.prefix(poses.count)), byMotion)
    }

    static func grids(_ profile: CatProfile, _ rigs: [[CatRig]]) -> [[CatGrid]] {
        let painter = CatPainter(profile)
        return rigs.map { list in
            list.map { rig in
                var g = CatGrid(width: DogSpriteCache.canvasWidth + margin * 2, height: DogSpriteCache.canvasHeight)
                painter.paint(rig, into: &g, originX: margin + 8)
                return g
            }
        }
    }

    static func union(_ grids: [[CatGrid]]) -> (minX: Int, maxX: Int)? {
        let boxes = grids.joined().compactMap(\.bounds)
        guard let lo = boxes.map(\.minX).min(), let hi = boxes.map(\.maxX).max() else { return nil }
        return (lo, hi)
    }

    /// One canvas frame at `pixelSize` points per art pixel. Drawn nearest-neighbour on demand, so it is crisp at
    /// any backing scale (menu bar 2x, the 4x preview page) without keeping big bitmaps around.
    static func image(_ rgba: [UInt8], pixelSize: CGFloat = 1) -> NSImage {
        let cg = DogRenderer.cgImage(rgba)
        let size = NSSize(width: CGFloat(cg.width) * pixelSize, height: CGFloat(cg.height) * pixelSize)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: rect)
            return true
        }
    }
}

/// A cat as an AnimatedCharacter. Frames are rendered on first use, so listing every breed costs nothing.
final class CatCharacter: AnimatedCharacter {
    let id: String
    let displayName: String
    let profile: CatProfile
    let imageSize: NSSize
    private let pixelSize: CGFloat
    private lazy var art: (poses: [[NSImage]], extras: [ExtraMotion: [NSImage]]) = {
        let a = CatRenderer.render(profile)
        return (a.poses.map { $0.map { CatRenderer.image($0, pixelSize: pixelSize) } },
                a.extras.mapValues { $0.map { CatRenderer.image($0, pixelSize: pixelSize) } })
    }()

    init(id: String, profile: CatProfile, pixelSize: CGFloat = 1) {
        self.id = id
        self.profile = profile
        self.pixelSize = pixelSize
        displayName = profile.name
        imageSize = NSSize(width: CGFloat(DogSpriteCache.canvasWidth) * pixelSize, height: CGFloat(DogSpriteCache.canvasHeight) * pixelSize)
    }

    convenience init(_ preset: CatPreset, pixelSize: CGFloat = 1) { self.init(id: "cat-" + preset.id, profile: preset.profile, pixelSize: pixelSize) }

    func frames(for pose: DogPose) -> [NSImage] { art.poses[pose.rawValue] }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { art.extras[motion] }

    /// Every preset, in picker order. Wiring: `CatCatalog.all = CatCharacter.presets`.
    static let presets: [CatCharacter] = CatProfile.presets.map { CatCharacter($0) }

    /// Seconds per frame for the extra motions (poses use DogSpriteCache.frameDuration).
    static func frameDuration(forExtra motion: ExtraMotion) -> TimeInterval { motion == .eat ? 0.22 : 0.4 }
}
