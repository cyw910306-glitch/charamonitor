import AppKit
import Combine

/// A saved custom character, with every frame already rendered.
struct CustomCharacter: Identifiable, Equatable {
    let id: UUID
    var name: String
    var lightRim: Bool
    var flipped: Bool
    /// 귀여운 비율: head grown, body smaller (CustomSprite.chibified).
    var chibi = true
    var created: Date
    var frames: [[[UInt8]]]   // DogPose order, premultiplied RGBA on the shared canvas
    /// Drawn by 내 Claude as ASCII frames (frames.json); nil for a character made from pictures.
    var art: FrameArt? = nil
    /// 실사 or 도트, size and outline of a photo character (`.legacy` for ones saved before 2.0).
    var look: PhotoLook = .legacy
    /// A 실사 character's renderer, drawing from the 1024 px cut-outs at any size and backing scale; nil for 도트 and 내 Claude.
    var real: RealSprite? = nil
    /// Its own 말투 (nil = the custom kind's) and 울음소리 sounds (Persona.cleanCries).
    var voice: PersonaStyle? = nil
    var cries: [String] = []
    var displayName: String { name.isEmpty ? Self.defaultName : name }
    static let defaultName = L("나만의 캐릭터")

    /// Frames from cut-outs: 실사 through RealSprite (unless every picture is already pixel art), else pixelated.
    static func render(_ inputs: [CustomSlot: CGImage], look: PhotoLook, chibi: Bool, lightRim: Bool, flipped: Bool)
        -> (frames: [[[UInt8]]], real: RealSprite?) {
        if look.style == .real, !inputs.isEmpty, !inputs.values.allSatisfy(CustomSprite.isPixelArt) {
            let real = RealSprite(sources: inputs, look: look, flipped: flipped, lightRim: lightRim)
            return (real.frames(), real)
        }
        let height = look.size.points * CustomSprite.density
        let bases = inputs.mapValues { CustomSprite.base($0, chibi: chibi, height: height) }
        return (CustomSprite.frames(bases, lightRim: lightRim, flip: flipped, ring: Int(look.outline.width * 2)), nil)
    }
}

/// character.json in each character's folder.
struct CustomCharacterMeta: Codable {
    var version = 1
    var id: UUID
    var name: String
    var lightRim: Bool
    var flipped: Bool
    var chibi: Bool?            // nil in files from before the option: on
    var created: Date
    var canvasWidth: Int
    var canvasHeight: Int
    var frameCounts: [Int]      // per DogPose, in order; rows of sheet.png
    var slots: [CustomSlot]     // input thumbnails saved next to it
    var kind: String?           // "frames": drawn from frames.json (FrameArt); nil: from the input pictures
    var look: PhotoLook?        // nil in files from before 2.0: PhotoLook.legacy (도트)
    var aiSlots: [CustomSlot]?  // inputs the AI drew (자동 다듬기), not the user; nil = none
    var persona: String?        // its own 말투 (PersonaStyle raw value); nil or unknown = the kind's
    var cries: [String]?        // its 울음소리 sounds, checked again on reading (Persona.cleanCries)
}

/// Custom characters on disk: <root>/<uuid>/ holds sheet.png (rows = poses, columns = frames, 1x),
/// character.json, and input-<slot>.png (the cut-out input, at most 1024 px; 256 before 2.0) that 실사 draws from and the
/// editor reopens. Never the originals.
/// A character 내 Claude drew also keeps its frames.json, which is what it is drawn from.
final class CustomCharacterStore: ObservableObject {
    static let maxCount = 5
    /// A var only so QA renders can point it at a scratch folder.
    static var shared = CustomCharacterStore(root: defaultRoot)
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Characters", isDirectory: true)
    }

    let root: URL
    @Published private(set) var characters: [CustomCharacter] = []

    init(root: URL) {
        self.root = root
        reload()
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        characters = dirs.compactMap(Self.read).sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }

    func character(_ id: String?) -> CustomCharacter? {
        guard let uuid = id.flatMap(UUID.init(uuidString:)) else { return nil }
        return characters.first { $0.id == uuid }
    }

    var isFull: Bool { characters.count >= Self.maxCount }

    /// Renders and writes the folder (new, or overwriting `id`). `inputs` are cut-outs from CustomSprite.cutout.
    @discardableResult
    func save(id: UUID = UUID(), name: String, lightRim: Bool, flipped: Bool = false, chibi: Bool = true, look: PhotoLook = PhotoLook(),
              inputs: [CustomSlot: CGImage], aiSlots: Set<CustomSlot> = [], art: FrameArt? = nil, created: Date = Date(),
              voice: PersonaStyle? = nil, cries: [String] = []) throws -> CustomCharacter {
        let voice = voice == .auto ? nil : voice, cries = Persona.cleanCries(cries)
        guard !inputs.isEmpty || art != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        // A photo cut-out as it is written (trimmed, 2 px margin, at most 1024 px), so a reload draws exactly what was saved.
        let inputs = inputs.mapValues { CustomSprite.isPixelArt($0) ? $0 : RealSprite.source($0) }
        let isNew = !characters.contains { $0.id == id }
        if isNew && isFull { throw CocoaError(.fileWriteOutOfSpace) }
        let photo = art == nil ? CustomCharacter.render(inputs, look: look, chibi: chibi, lightRim: lightRim, flipped: flipped) : nil
        let frames = art?.frames(flipped: flipped) ?? photo!.frames
        let dir = folder(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artURL = dir.appendingPathComponent("frames.json")
        if let art { try art.json.write(to: artURL, options: .atomic) } else { try? FileManager.default.removeItem(at: artURL) }
        try png(sheet(frames)).write(to: dir.appendingPathComponent("sheet.png"), options: .atomic)
        for slot in CustomSlot.allCases {
            let url = dir.appendingPathComponent("input-\(slot.rawValue).png")
            if let image = inputs[slot] {
                try png(image).write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let drawn = CustomSlot.allCases.filter { aiSlots.contains($0) && inputs[$0] != nil }
        let meta = CustomCharacterMeta(id: id, name: name, lightRim: lightRim, flipped: flipped, chibi: chibi, created: created,
                                       canvasWidth: CustomSprite.w, canvasHeight: CustomSprite.h, frameCounts: frames.map(\.count),
                                       slots: CustomSlot.allCases.filter { inputs[$0] != nil }, kind: art == nil ? nil : "frames",
                                       look: art == nil ? look : nil,
                                       aiSlots: art == nil && !drawn.isEmpty ? drawn : nil,
                                       persona: voice?.rawValue, cries: cries.isEmpty ? nil : cries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: dir.appendingPathComponent("character.json"), options: .atomic)
        reload()
        return CustomCharacter(id: id, name: name, lightRim: lightRim, flipped: flipped, chibi: chibi, created: created, frames: frames, art: art,
                               look: art == nil ? look : .legacy, real: photo?.real, voice: voice, cries: cries)
    }

    /// The saved cut-outs, for the editor.
    func inputs(_ id: UUID) -> [CustomSlot: CGImage] { Self.inputs(in: folder(id)) }

    /// Which of them the AI drew, so the editor redraws them when the user's own pictures change.
    func aiSlots(_ id: UUID) -> Set<CustomSlot> { Set(Self.meta(in: folder(id))?.aiSlots ?? []) }

    /// 자동 다듬기 that finished after its creator closed: puts `cuts` into the saved character's slots that have no
    /// picture of the user's, keeping everything else as it is saved now, and only while the user's pictures are still the
    /// ones the drawing came from (`basis`, each one's pixel size). So an edit saved meanwhile is never undone.
    // ponytail: compares the user's pictures by size only; swapping in a same-size picture elsewhere still takes the poses.
    @discardableResult
    func mergeAI(_ id: UUID, cuts: [CustomSlot: CGImage], basis: [CustomSlot: CGSize]) -> Bool {
        guard !cuts.isEmpty, let saved = characters.first(where: { $0.id == id }), saved.art == nil else { return false }
        var inputs = self.inputs(id)
        let drawn = aiSlots(id)
        let own = inputs.filter { !drawn.contains($0.key) }.mapValues { CGSize(width: $0.width, height: $0.height) }
        guard own == basis else { return false }
        let added = cuts.filter { own[$0.key] == nil }
        for (slot, cut) in added { inputs[slot] = cut }
        return (try? save(id: id, name: saved.name, lightRim: saved.lightRim, flipped: saved.flipped, chibi: saved.chibi,
                          look: saved.look, inputs: inputs, aiSlots: drawn.union(added.keys), created: saved.created,
                          voice: saved.voice, cries: saved.cries)) != nil
    }

    private static func inputs(in dir: URL) -> [CustomSlot: CGImage] {
        var out: [CustomSlot: CGImage] = [:]
        for slot in CustomSlot.allCases {
            let url = dir.appendingPathComponent("input-\(slot.rawValue).png")
            // Capped like a new picture: a replaced or damaged file must not decode at full size.
            if let img = CustomSprite.load(url: url, maxPixel: RealSprite.sourcePixels) { out[slot] = img }
        }
        return out
    }

    /// Removes only <root>/<uuid>: a real folder directly inside root, never a link.
    func delete(_ id: UUID) throws {
        let dir = folder(id)
        let values = try dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              dir.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: dir)
        reload()
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    // MARK: Files

    private static func meta(in dir: URL) -> CustomCharacterMeta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("character.json")),
              let meta = try? decoder.decode(CustomCharacterMeta.self, from: data),
              meta.id.uuidString == dir.lastPathComponent else { return nil }
        return meta
    }

    private static func read(_ dir: URL) -> CustomCharacter? {
        guard let meta = meta(in: dir), var c = drawn(dir, meta) else { return nil }
        c.voice = meta.persona.flatMap(PersonaStyle.init).flatMap { $0 == .auto ? nil : $0 }   // unknown: ignored
        c.cries = Persona.cleanCries(meta.cries)
        return c
    }

    private static func drawn(_ dir: URL, _ meta: CustomCharacterMeta) -> CustomCharacter? {
        // Drawn by 내 Claude: from its frames.json, checked again like a fresh drawing (the file may have been edited).
        if meta.kind == "frames" {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.json")), let art = try? FrameArt.parse(data) else { return nil }
            return CustomCharacter(id: meta.id, name: meta.name, lightRim: meta.lightRim, flipped: meta.flipped, chibi: meta.chibi ?? true,
                                   created: meta.created, frames: art.frames(flipped: meta.flipped), art: art)
        }
        let look = meta.look ?? .legacy
        // 실사 is always drawn from its cut-outs; one saved by an older version (1 art px per point) is pixelated again from them.
        if look.style == .real || meta.canvasWidth != CustomSprite.w || meta.canvasHeight != CustomSprite.h {
            let inputs = Self.inputs(in: dir)
            guard !inputs.isEmpty else { return nil }
            let chibi = meta.chibi ?? true
            let photo = CustomCharacter.render(inputs, look: look, chibi: chibi, lightRim: meta.lightRim, flipped: meta.flipped)
            return CustomCharacter(id: meta.id, name: meta.name, lightRim: meta.lightRim, flipped: meta.flipped, chibi: chibi,
                                   created: meta.created, frames: photo.frames, look: look, real: photo.real)
        }
        guard meta.frameCounts.count == DogPose.allCases.count, meta.frameCounts.allSatisfy({ $0 > 0 }),
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("sheet.png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = CustomSprite.w, h = CustomSprite.h
        // Exactly what save writes, checked before decoding, so an odd file is skipped instead of loaded.
        guard image.width == w * (meta.frameCounts.max() ?? 1), image.height == h * meta.frameCounts.count else { return nil }
        let sheet = Bitmap(image)
        let frames = meta.frameCounts.enumerated().map { row, count in
            (0..<count).map { col -> [UInt8] in
                var f = Bitmap(width: w, height: h)
                for y in 0..<h {
                    let from = ((row * h + y) * sheet.width + col * w) * 4
                    f.px.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: sheet.px[from..<(from + w * 4)])
                }
                return f.cgReady
            }
        }
        return CustomCharacter(id: meta.id, name: meta.name, lightRim: meta.lightRim, flipped: meta.flipped, chibi: meta.chibi ?? true,
                               created: meta.created, frames: frames, look: look)
    }

    /// Rows are poses, columns frames, 1 px per art pixel.
    static func sheetImage(_ frames: [[[UInt8]]]) -> CGImage {
        let w = CustomSprite.w, h = CustomSprite.h, cols = frames.map(\.count).max() ?? 1
        let ctx = DogRenderer.context(width: w * cols, height: h * frames.count)!
        ctx.interpolationQuality = .none
        for (row, poseFrames) in frames.enumerated() {
            for (col, f) in poseFrames.enumerated() {
                ctx.draw(DogRenderer.art(f), in: CGRect(x: col * w, y: (frames.count - 1 - row) * h, width: w, height: h))
            }
        }
        return ctx.makeImage()!
    }

    private func sheet(_ frames: [[[UInt8]]]) -> CGImage { Self.sheetImage(frames) }

    private func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
