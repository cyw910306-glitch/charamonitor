import CoreGraphics
import Foundation

/// One character any app can draw, as plain RGBA frames: a built-in dog, cat or original, or a local pack.
/// The iPhone app and its widgets only talk to this type (the Mac draws through DogSpriteCache).
public struct CharaArt: Identifiable {
    public let id: String
    public let displayName: String
    public let kind: SpriteCharacter
    /// Pixels per frame: 34 x 20 for the built-ins, 34N x 20N for a pack of density N.
    public let width: Int, height: Int
    /// Illustration frames (an HD pack): drawn smoothed, never nearest-neighbour.
    public let smooth: Bool
    /// RGBA frames in DogPose order, and the extra moments this character has. Drawn on first use, so listing every
    /// built-in costs nothing.
    public var poses: [[[UInt8]]] { art.value.poses }
    public var extras: [ExtraMotion: [[UInt8]]] { art.value.extras }
    private let art: Drawn
    private let memo = Memo()
    /// Its own 말투, 울음소리 and pack.json "say" lines by frame key ("special"); nil, [] and [:] for the built-ins.
    public let voice: PersonaStyle?
    public let cries: [String]
    public let say: [String: [String]]
    /// Seconds per frame by pose name or extra raw value, in place of FrameTiming.
    public let frameSeconds: [String: TimeInterval]

    /// Who shows when nothing else is chosen: 젤리.
    public static let defaultID = "dog-jelly"

    /// Every built-in character in picker order: the dogs ("dog-<preset>"), the cats ("cat-<preset>"), the originals.
    public static let builtIn: [CharaArt] = {
        let dogs = DogProfile.presets.map { p in
            CharaArt(id: "dog-" + p.id, displayName: p.name, kind: .dog) { (DogRenderer.frames(p.profile), DogExtras.byMotion(p.profile)) }
        }
        let cats = CatProfile.presets.map { p in
            CharaArt(id: "cat-" + p.id, displayName: p.name, kind: .cat) { CatRenderer.render(p.profile) }
        }
        let originals = OriginalInfo.all.map { o in
            CharaArt(id: o.id, displayName: o.displayName, kind: .original) {
                let art = OriginalFrames(json: o.json)
                return (art.poseRGBA, art.extraRGBA)
            }
        }
        return dogs + cats + originals
    }()

    public static func builtIn(_ id: String?) -> CharaArt? { builtIn.first { $0.id == id } }

    /// Every valid pack folder (pack-<slug>) under `folder`; a bad one is skipped (PackArt.skipped says why).
    /// `keys`: only those frames and the walk (see PackArt.init); nil reads every frame.
    public static func packs(in folder: URL, keys: Set<String>? = nil) -> [CharaArt] {
        PackArt.loadAll(root: folder, keys: keys).map(CharaArt.init(pack:))
    }

    /// The frame keys of what plays (`frames(pose, extra:)`), to read a pack for it alone.
    public static func keys(_ pose: DogPose, extra: ExtraMotion? = nil) -> Set<String> {
        Set([FrameArt.key(pose)] + [extra?.rawValue].compactMap { $0 })
    }

    public init(pack: PackArt) {
        self.init(id: pack.id, displayName: pack.displayName, kind: .original, width: pack.pixelWidth, height: pack.pixelHeight,
                  smooth: pack.smooth, voice: pack.voice, cries: pack.cries, say: pack.sayLines, frameSeconds: pack.frameSeconds) {
            (pack.poseRGBA, pack.extraRGBA)
        }
    }

    init(id: String, displayName: String, kind: SpriteCharacter, width: Int = SpriteCanvas.width, height: Int = SpriteCanvas.height,
         smooth: Bool = false, voice: PersonaStyle? = nil, cries: [String] = [], say: [String: [String]] = [:],
         frameSeconds: [String: TimeInterval] = [:], frames: @escaping () -> Frames) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.width = width
        self.height = height
        self.smooth = smooth
        art = Drawn(frames)
        self.voice = voice
        self.cries = cries
        self.say = say
        self.frameSeconds = frameSeconds
    }

    /// What plays: the extra moment when this character has it, else the pose (the walk when a pose has no frames).
    public func frames(_ pose: DogPose, extra: ExtraMotion? = nil) -> [[UInt8]] {
        if let extra, let f = extras[extra] { return f }
        let f = poses[pose.rawValue]
        return f.isEmpty ? poses[DogPose.walk.rawValue] : f
    }

    /// Seconds per frame of what plays: the character's own timing when it sets one, else FrameTiming.
    public func seconds(_ pose: DogPose, extra: ExtraMotion? = nil, cpu: Double = 0.2) -> TimeInterval {
        if let extra, extras[extra] != nil { return frameSeconds[extra.rawValue] ?? FrameTiming.extra(extra) }
        return frameSeconds[FrameArt.key(pose)] ?? FrameTiming.pose(pose, cpu: cpu)
    }

    /// The frames as images of 34 x 20 times `scale` pixels: pixel art stays blocky, illustrations scale smoothly.
    public func images(_ pose: DogPose, extra: ExtraMotion? = nil, scale: Int) -> [CGImage] {
        frames(pose, extra: extra).compactMap { image($0, scale: scale) }
    }

    /// `images(pose, extra:, scale:)`, made once and kept (the last few asked for), for a view that redraws many
    /// times a second.
    public func cachedImages(_ pose: DogPose, extra: ExtraMotion? = nil, scale: Int) -> [CGImage] {
        let key = "\(pose.rawValue) \(extra?.rawValue ?? "-") \(scale)"
        if let kept = memo.get(key) { return kept }
        let made = images(pose, extra: extra, scale: scale)
        memo.set(key, made)
        return made
    }

    /// One frame of this character (`width` x `height` RGBA) at 34 x 20 times `scale` pixels.
    public func image(_ rgba: [UInt8], scale: Int) -> CGImage? {
        let src = DogRenderer.cgImage(rgba, width: width, height: height, interpolate: smooth)
        let w = SpriteCanvas.width * max(1, scale), h = SpriteCanvas.height * max(1, scale)
        guard let ctx = DogRenderer.context(width: w, height: h) else { return nil }
        ctx.interpolationQuality = smooth || width > w ? .high : .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// How this character talks: `chosen` (the owner's pick) first, then its own 말투, then its kind's preset.
    public func persona(chosen: PersonaStyle = .auto) -> Persona {
        Persona.resolve(name: displayName, character: kind, id: id, chosen: chosen, own: voice, cries: cries)
    }

    /// Its own lines for take `variant` of `motion` (pack.json "say"), empty for most.
    public func lines(_ motion: ExtraMotion, variant: Int = 0) -> [String] { say[PackArt.takeKey(motion, variant)] ?? [] }

    public typealias Frames = (poses: [[[UInt8]]], extras: [ExtraMotion: [[UInt8]]])

    /// cachedImages' few sequences, from any thread.
    private final class Memo: @unchecked Sendable {
        private var kept: [String: [CGImage]] = [:]
        private let lock = NSLock()

        func get(_ key: String) -> [CGImage]? {
            lock.lock()
            defer { lock.unlock() }
            return kept[key]
        }

        func set(_ key: String, _ images: [CGImage]) {
            lock.lock()
            defer { lock.unlock() }
            if kept.count >= 4 { kept = [:] }   // a reaction and back, the focus dial's two poses
            kept[key] = images
        }
    }

    /// The frames, made once by the first caller (from any thread).
    private final class Drawn: @unchecked Sendable {
        private let make: () -> Frames
        private var made: Frames?
        private let lock = NSLock()

        init(_ make: @escaping () -> Frames) { self.make = make }

        var value: Frames {
            lock.lock()
            defer { lock.unlock() }
            if let made { return made }
            let f = make()
            made = (f.poses, f.extras.filter { !$0.value.isEmpty })
            return made!
        }
    }
}
