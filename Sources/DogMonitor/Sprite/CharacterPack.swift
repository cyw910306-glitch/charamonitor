import AppKit

/// A character from a local pack folder: the user's own pictures as a character (format: docs/PACKS.md).
/// In the App Store build the folder is inside the app's sandbox container (defaultRoot resolves there).
/// <PacksRoot>/pack-<slug>/ holds pack.json and frames/<key>-<i>.png: RGBA art of `density` px per point on the
/// 34 x 20 pt canvas (34N x 20N px; default 2, one physical Retina pixel each), facing right. Pixel packs (default)
/// have hard alpha and draw nearest-neighbour; `"smooth": true` packs are illustrations: soft alpha, high-quality
/// interpolation everywhere, 1x/2x menu bar copies made ahead. Keys are the DogPose names (all seven required) and the
/// ExtraMotion raw values (optional), plus more takes of an extra as "special.2" ... "special.4" (in order).
/// Optional voice: "persona" (a PersonaStyle raw value; unknown is ignored), "cries" (울음소리 sounds) and "say"
/// (lines per extra key, said when a moment plays that take; shown in the bubble only, never put into a prompt).
/// Loaded once at launch into OriginalCatalog.all.
final class CharacterPack: AnimatedCharacter {
    /// PNG size cap at density 2; it grows with the pixel count (density² / 4).
    static let maxPNGBytes = 64 * 1024, maxJSONBytes = 16 * 1024, maxPacks = 32
    /// Takes per extra moment (the plain key and .2 ... .4); lines per key, and characters per line.
    static let maxTakes = 4, maxLines = 6, maxLineLength = 60
    /// Pixel art is 1 or 2 px per point (the bar shows no more); illustrations up to 8 (272 x 160), the biggest view's
    /// need (the 4x preview on a Retina screen).
    static let pixelDensities = 1...2, smoothDensities = 1...8
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Packs", isDirectory: true)
    }

    let id: String
    let displayName: String
    let specialTitle: String?
    let previewBlurb: String?
    let frameSeconds: [String: TimeInterval]
    /// RGBA frames, pixelWidth x pixelHeight, in DogPose order, and the extras the pack has.
    let poseRGBA: [[[UInt8]]]
    let extraRGBA: [ExtraMotion: [[UInt8]]]
    /// The further takes of each extra ("special.2" first), same shape as extraRGBA.
    let takeRGBA: [ExtraMotion: [[[UInt8]]]]
    let voice: PersonaStyle?
    let cries: [String]
    /// "say" lines by frame key ("special", "special.2").
    let sayLines: [String: [String]]
    let outline: PixelColor
    let density: Int
    let smooth: Bool
    var pixelWidth: Int { DogSpriteCache.canvasWidth * density }
    var pixelHeight: Int { DogSpriteCache.canvasHeight * density }
    var artDensity: Int { density }
    private lazy var poseImages: [[NSImage]] = poseRGBA.map { $0.map(draw) }
    private lazy var extraImages: [ExtraMotion: [NSImage]] = extraRGBA.mapValues { $0.map(draw) }
    private lazy var takeImages: [ExtraMotion: [[NSImage]]] = takeRGBA.mapValues { $0.map { $0.map(draw) } }

    var imageSize: NSSize { BarArt.size }
    func frames(for pose: DogPose) -> [NSImage] { poseImages[pose.rawValue] }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { extraImages[motion] }
    func extraVariants(_ motion: ExtraMotion) -> [[NSImage]] { extraImages[motion].map { [$0] + (takeImages[motion] ?? []) } ?? [] }
    func lines(forExtra motion: ExtraMotion, variant: Int) -> [String] { sayLines[Self.takeKey(motion, variant)] ?? [] }
    /// The frame key of take `index` (0 = the plain key, 1 = "special.2").
    static func takeKey(_ motion: ExtraMotion, _ index: Int) -> String { index == 0 ? motion.rawValue : "\(motion.rawValue).\(index + 1)" }
    private func draw(_ rgba: [UInt8]) -> NSImage {
        smooth ? BarArt.smooth(DogRenderer.cgImage(rgba, width: pixelWidth, height: pixelHeight, interpolate: true))
            : BarArt.adaptive(rgba, outline: outline, width: pixelWidth, height: pixelHeight)
    }

    struct Invalid: Error, CustomStringConvertible { let description: String }

    private struct Manifest: Decodable {
        let version: Int
        let id: String
        let name: String
        let special: String?
        let blurb: String?
        let frames: [String: Int]
        let seconds: [String: Double]?
        let density: Int?
        let smooth: Bool?
        let persona: String?
        let cries: [String]?
        let say: [String: [String]]?
    }

    /// Reads and checks `folder` strictly; throws on anything off. Nothing inside it may be a link.
    init(folder: URL) throws {
        func fail(_ why: String) -> Invalid { Invalid(description: "\(folder.lastPathComponent): \(why)") }
        try Self.check(folder, directory: true)
        let jsonURL = folder.appendingPathComponent("pack.json")
        try Self.check(jsonURL, maxBytes: Self.maxJSONBytes)
        guard let m = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: jsonURL)) else { throw fail("pack.json unreadable") }
        guard m.version == 1 else { throw fail("version \(m.version)") }
        guard m.id == folder.lastPathComponent, m.id.range(of: #"^pack-[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else {
            throw fail("id must be pack-<slug> and match the folder")
        }
        let smooth = m.smooth ?? false, density = m.density ?? 2
        guard (smooth ? Self.smoothDensities : Self.pixelDensities).contains(density) else {
            throw fail("density \(density): \(smooth ? "smooth 1...8" : "pixel art 1...2")")
        }
        let w = DogSpriteCache.canvasWidth * density, h = DogSpriteCache.canvasHeight * density
        let maxBytes = Self.maxPNGBytes * max(4, density * density) / 4
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw fail("name") }

        let poses = DogPose.allCases.map(FrameArt.key), extras = ExtraMotion.allCases.map(\.rawValue)
        let takes = ExtraMotion.allCases.flatMap { e in (1..<Self.maxTakes).map { Self.takeKey(e, $0) } }
        guard Set(m.frames.keys).isSubset(of: poses + extras + takes) else { throw fail("unknown frame key") }
        if let seconds = m.seconds {
            guard Set(seconds.keys).isSubset(of: poses + extras), seconds.values.allSatisfy({ (0.05...1.0).contains($0) }) else {
                throw fail("seconds: known keys, 0.05...1.0")
            }
        }
        let framesDir = folder.appendingPathComponent("frames", isDirectory: true)
        try Self.check(framesDir, directory: true)
        func load(_ key: String, _ range: ClosedRange<Int>) throws -> [[UInt8]] {
            guard let n = m.frames[key], range.contains(n) else { throw fail("'\(key)' needs \(range) frames") }
            return try (0..<n).map {
                try Self.png(framesDir.appendingPathComponent("\(key)-\($0).png"), width: w, height: h, soft: smooth, maxBytes: maxBytes)
            }
        }
        poseRGBA = try DogPose.allCases.map { try load(FrameArt.key($0), $0 == .lying ? 1...12 : 2...12) }
        var extraRGBA: [ExtraMotion: [[UInt8]]] = [:]
        var takeRGBA: [ExtraMotion: [[[UInt8]]]] = [:]
        for motion in ExtraMotion.allCases where m.frames[motion.rawValue] != nil {
            extraRGBA[motion] = try load(motion.rawValue, 2...16)
            for i in 1..<Self.maxTakes {
                let key = Self.takeKey(motion, i)
                guard m.frames[key] != nil else { break }
                takeRGBA[motion, default: []].append(try load(key, 2...16))
            }
        }
        // A take with no plain key, or after a gap ("special.3" without "special.2"), was not loaded.
        let loaded = Set(extraRGBA.keys.flatMap { e in (0...(takeRGBA[e]?.count ?? 0)).map { Self.takeKey(e, $0) } })
        guard Set(m.frames.keys).subtracting(poses).isSubset(of: loaded) else { throw fail("takes go special, special.2, special.3 in order") }
        self.extraRGBA = extraRGBA
        self.takeRGBA = takeRGBA
        let say = (m.say ?? [:]).mapValues { lines in
            Array(lines.map { Persona.oneLine($0, max: Self.maxLineLength) }.filter { !$0.isEmpty }.prefix(Self.maxLines))
        }
        guard Set(say.keys).isSubset(of: loaded) else { throw fail("say: keys of the extras this pack has") }
        sayLines = say.filter { !$0.value.isEmpty }
        voice = m.persona.flatMap(PersonaStyle.init).flatMap { $0 == .auto ? nil : $0 }   // unknown: ignored
        cries = Persona.cleanCries(m.cries)
        id = m.id
        displayName = name
        specialTitle = m.special.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        previewBlurb = m.blurb.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        frameSeconds = m.seconds ?? [:]
        self.density = density
        self.smooth = smooth
        outline = BarArt.outlineColor(poseRGBA[DogPose.walk.rawValue][0], width: w, height: h)
    }

    /// Why the last loadAll skipped packs, for 문제 보내기.
    private(set) static var skipped: [String] = []

    /// Every valid pack under `root`, by folder name; a bad one is reported on stderr, kept in `skipped` and skipped.
    static func loadAll(root: URL = defaultRoot) -> [CharacterPack] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("pack-") }.sorted()
        skipped = []
        return names.prefix(maxPacks).compactMap { name in
            do { return try CharacterPack(folder: root.appendingPathComponent(name, isDirectory: true)) } catch {
                fputs("캐릭터 팩 건너뜀: \(error)\n", stderr)
                skipped.append("\(name): \(error)")
                return nil
            }
        }
    }

    /// A real directory or a small regular file (lstat: a symbolic link is neither, so nothing leads out of the root).
    private static func check(_ url: URL, directory: Bool = false, maxBytes: Int = maxPNGBytes) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs?[.type] as? FileAttributeType
        if directory {
            guard type == .typeDirectory else { throw Invalid(description: "\(url.lastPathComponent): not a folder") }
        } else {
            guard type == .typeRegular, let size = attrs?[.size] as? Int, size <= maxBytes else {
                throw Invalid(description: "\(url.lastPathComponent): missing, a link, or over \(maxBytes) bytes")
            }
        }
    }

    /// One frame: exactly `width` x `height`, as RGBA. Pixel art gets alpha forced to 0 or 255 (it is meant to be
    /// hard-edged); `soft` keeps the illustration's own antialiased edge, premultiplied.
    private static func png(_ url: URL, width: Int, height: Int, soft: Bool, maxBytes: Int) throws -> [UInt8] {
        try check(url, maxBytes: maxBytes)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == width, image.height == height,
              let ctx = DogRenderer.context(width: width, height: height) else {
            throw Invalid(description: "\(url.lastPathComponent): not a \(width)x\(height) PNG")
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { throw Invalid(description: "\(url.lastPathComponent): unreadable") }
        let row = ctx.bytesPerRow, p = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * row + x * 4, o = (y * width + x) * 4, a = Int(p[i + 3])
                if soft {
                    for c in 0..<4 { out[o + c] = p[i + c] }
                    continue
                }
                guard a >= 128 else { continue }
                for c in 0..<3 { out[o + c] = UInt8(min(255, Int(p[i + c]) * 255 / a)) }   // un-premultiply
                out[o + 3] = 255
            }
        }
        guard out.contains(where: { $0 != 0 }) else { throw Invalid(description: "\(url.lastPathComponent): empty frame") }
        return out
    }
}
