import AppKit

/// --export-web-sprites <dir>: the built-in characters (every dog preset, every cat, the originals) for the web app
/// (web/app): one 1x PNG sheet per character (rows = poses then extras, columns = frames, 34 x 20 px each) and
/// index.json with names (ko and en, from Resources/en.lproj when run from the repo), 말투, cries, voice (FriendCry: dogs
/// bark, cats meow, originals chirp) and timings. Run from the repo root.
enum WebSprites {
    static func export(to dir: URL) throws {
        let en = (NSDictionary(contentsOfFile: "Resources/en.lproj/Localizable.strings") as? [String: String]) ?? [:]
        func both(_ ko: String) -> [String: String] { ["ko": ko, "en": en[ko] ?? ko] }
        var list: [[String: Any]] = []

        func add(_ id: String, kind: SpriteCharacter, name: String, voice: String, poses: [[[UInt8]]],
                 extras: [ExtraMotion: [[UInt8]]], special: String? = nil, blurb: String? = nil) throws {
            var rows: [(key: String, frames: [[UInt8]], seconds: Double)] = DogPose.allCases.map { pose in
                (FrameArt.key(pose), poses[pose.rawValue], seconds(pose))
            }
            for m in ExtraMotion.allCases { if let f = extras[m], !f.isEmpty { rows.append((m.rawValue, f, DogSpriteCache.extraFrameDuration(m))) } }
            let w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight
            let cols = rows.map(\.frames.count).max() ?? 1
            var px = [UInt8](repeating: 0, count: cols * w * rows.count * h * 4)
            for (r, row) in rows.enumerated() {
                for (c, f) in row.frames.enumerated() where f.count == w * h * 4 {
                    for y in 0..<h {
                        let dst = ((r * h + y) * cols * w + c * w) * 4
                        px.replaceSubrange(dst..<(dst + w * 4), with: f[(y * w * 4)..<((y + 1) * w * 4)])
                    }
                }
            }
            let file = "\(id).png"
            let image = DogRenderer.cgImage(px, width: cols * w, height: rows.count * h)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: dir.appendingPathComponent(file))
            let style = Persona.preset(character: kind, id: kind == .original ? id : nil)
            var entry: [String: Any] = [
                "id": id, "kind": kind.rawValue, "name": both(name), "sheet": file, "persona": style.rawValue, "voice": voice,
                "cries": Persona.cries(character: kind, id: id).map(both),
                "rows": rows.map { ["key": $0.key, "n": $0.frames.count, "s": $0.seconds] },
            ]
            if let special { entry["special"] = both(special) }
            if let blurb { entry["blurb"] = both(blurb) }
            list.append(entry)
        }

        for preset in DogProfile.presets {
            try add("dog-\(preset.id)", kind: .dog, name: preset.name, voice: "bark", poses: DogRenderer.frames(preset.profile),
                    extras: BuiltinExtras.dog?(preset.profile) ?? [:])
        }
        for preset in CatProfile.presets {
            let art = CatRenderer.render(preset.profile)
            try add("cat-\(preset.id)", kind: .cat, name: preset.name, voice: "meow", poses: art.poses, extras: art.extras)
        }
        for o in OriginalCharacterSet2.all {
            try add(o.id, kind: .original, name: o.displayName, voice: "chirp",
                    poses: o.poseRGBA, extras: o.extraRGBA, special: o.specialName, blurb: o.blurb)
        }
        let index: [String: Any] = ["version": 1, "frame": ["w": DogSpriteCache.canvasWidth, "h": DogSpriteCache.canvasHeight],
                                    "characters": list]
        let json = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try json.write(to: dir.appendingPathComponent("index.json"))
        print("캐릭터 \(list.count)개를 \(dir.path)에 썼어요")
    }

    /// The app's seconds per frame at the middle of each pose's CPU band.
    private static func seconds(_ pose: DogPose) -> Double {
        let mid: [DogPose: Double] = [.slowWalk: 0.1, .walk: 0.22, .fastWalk: 0.37, .run: 0.55, .sprint: 0.75, .exhausted: 0.92]
        return (DogSpriteCache.frameDuration(for: pose, cpu: mid[pose] ?? 0) * 1000).rounded() / 1000
    }
}
