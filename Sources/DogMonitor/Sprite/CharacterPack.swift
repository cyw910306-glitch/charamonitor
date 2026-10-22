import AppKit

/// A local pack (PackArt in CharaCore: the format, the checks and the RGBA frames) as a menu bar character.
/// In the App Store build the folder is inside the app's sandbox container (defaultRoot resolves there).
/// Loaded once at launch into OriginalCatalog.all. Every PackArt property reads straight through (`pack.poseRGBA`).
@dynamicMemberLookup
final class CharacterPack: AnimatedCharacter {
    static let maxPNGBytes = PackArt.maxPNGBytes, maxLineLength = PackArt.maxLineLength
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Packs", isDirectory: true)
    }
    /// Why the last loadAll skipped packs, for 문제 보내기.
    static var skipped: [String] { PackArt.skipped }

    let art: PackArt
    private lazy var poseImages: [[NSImage]] = art.poseRGBA.map { $0.map(draw) }
    private lazy var extraImages: [ExtraMotion: [NSImage]] = art.extraRGBA.mapValues { $0.map(draw) }
    private lazy var takeImages: [ExtraMotion: [[NSImage]]] = art.takeRGBA.mapValues { $0.map { $0.map(draw) } }

    init(folder: URL) throws { art = try PackArt(folder: folder) }
    init(_ art: PackArt) { self.art = art }

    /// Every valid pack under `root`; a bad one is reported on stderr, kept in `skipped` and skipped.
    static func loadAll(root: URL = defaultRoot) -> [CharacterPack] { PackArt.loadAll(root: root).map(CharacterPack.init) }

    subscript<T>(dynamicMember key: KeyPath<PackArt, T>) -> T { art[keyPath: key] }

    var id: String { art.id }
    var displayName: String { art.displayName }
    var specialTitle: String? { art.specialTitle }
    var previewBlurb: String? { art.previewBlurb }
    var frameSeconds: [String: TimeInterval] { art.frameSeconds }
    var smooth: Bool { art.smooth }
    var artDensity: Int { art.artDensity }
    var voice: PersonaStyle? { art.voice }
    var cries: [String] { art.cries }
    var imageSize: NSSize { BarArt.size }
    func frames(for pose: DogPose) -> [NSImage] { poseImages[pose.rawValue] }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { extraImages[motion] }
    func extraVariants(_ motion: ExtraMotion) -> [[NSImage]] { extraImages[motion].map { [$0] + (takeImages[motion] ?? []) } ?? [] }
    func lines(forExtra motion: ExtraMotion, variant: Int) -> [String] { art.lines(forExtra: motion, variant: variant) }

    private func draw(_ rgba: [UInt8]) -> NSImage {
        art.smooth ? BarArt.smooth(DogRenderer.cgImage(rgba, width: art.pixelWidth, height: art.pixelHeight, interpolate: true))
            : BarArt.adaptive(rgba, outline: art.outline, width: art.pixelWidth, height: art.pixelHeight)
    }
}
