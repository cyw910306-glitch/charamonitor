import AppKit

/// CatRenderer (CharaCore) as menu bar images.
extension CatRenderer {
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
