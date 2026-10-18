import Foundation

/// A character drawn as ASCII frames per pose on the 34x20 canvas ("." transparent), one character per
/// art pixel, colours from `palette`. This is frames.json, written by 내 Claude and kept in the character's folder.
struct FrameArt: Codable, Equatable {
    var palette: [String: String]     // single character to "#RRGGBB"
    var poses: [String: [[String]]]   // DogPose name to frames, each 20 rows of 34 characters

    static let width = DogSpriteCache.canvasWidth, height = DogSpriteCache.canvasHeight
    static let maxColors = 16
    static func key(_ pose: DogPose) -> String { String(describing: pose) }
    /// 2 to 8 frames per pose; sleeping may be one still frame.
    static func frameRange(_ pose: DogPose) -> ClosedRange<Int> { pose == .lying ? 1...8 : 2...8 }

    // MARK: Checking

    /// Reads frames.json strictly: the right poses, frame counts, sizes, palette characters and colours. Trivial slips
    /// are repaired (a row or two too many or few, rows a few characters off, unknown characters as transparent);
    /// anything else throws a short Korean reason.
    static func parse(_ data: Data) throws -> FrameArt {
        let text = String(decoding: data, as: UTF8.self)
        // Tolerates a ```json fence or a sentence around the object.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw invalid(L("frames.json을 읽지 못했어요"))
        }
        guard let rawPalette = object["palette"] as? [String: Any], let rawPoses = object["poses"] as? [String: Any] else {
            throw invalid(L("palette 또는 poses가 없어요"))
        }
        var palette: [String: String] = [:]
        for (key, value) in rawPalette where key != "." {
            guard key.count == 1, key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }), let hex = value as? String,
                  hex.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
                throw invalid(L("색 '\(key)'가 #RRGGBB 형식이 아니에요"))
            }
            palette[key] = hex.uppercased()
        }
        guard !palette.isEmpty else { throw invalid(L("색이 하나도 없어요")) }
        guard palette.count <= maxColors else { throw invalid(L("색이 \(palette.count)개예요 (\(maxColors)개까지)")) }
        guard palette.values.contains(where: { isDark(PixelColor(hex: $0)) }) else { throw invalid(L("테두리용 어두운 색이 없어요")) }

        var poses: [String: [[String]]] = [:]
        for pose in DogPose.allCases {
            let key = key(pose)
            guard let list = rawPoses[key] as? [Any], frameRange(pose).contains(list.count) else {
                throw invalid(L("'\(key)' 동작의 그림 수가 맞지 않아요"))
            }
            poses[key] = try list.map { try frame($0, palette: palette, pose: key) }
        }
        return FrameArt(palette: palette, poses: poses)
    }

    private static func frame(_ raw: Any, palette: [String: String], pose: String) throws -> [String] {
        var rows = (raw as? [Any])?.compactMap { $0 as? String } ?? (raw as? String)?.components(separatedBy: "\n") ?? []
        guard rows.count <= height * 2 else { throw invalid(L("'\(pose)' 그림이 \(height)줄 × \(width)칸이 아니에요")) }
        // A few rows off: drop empty rows (sky first, keeping the feet), then pad the sky.
        while rows.count > height, let first = rows.first, isEmpty(first, palette) { rows.removeFirst() }
        while rows.count > height, let last = rows.last, isEmpty(last, palette) { rows.removeLast() }
        guard (height - 3...height).contains(rows.count), rows.allSatisfy({ (width - 4...width + 4).contains($0.count) }) else {
            throw invalid(L("'\(pose)' 그림이 \(height)줄 × \(width)칸이 아니에요"))
        }
        rows = Array(repeating: String(repeating: ".", count: width), count: height - rows.count) + rows
        let clean = rows.map { row in
            String(row.map { palette[String($0)] != nil ? $0 : "." }).padding(toLength: width, withPad: ".", startingAt: 0)
        }
        guard clean.contains(where: { !isEmpty($0, palette) }) else { throw invalid(L("'\(pose)' 그림이 비어 있어요")) }
        return clean
    }

    private static func isEmpty(_ row: String, _ palette: [String: String]) -> Bool { !row.contains { palette[String($0)] != nil } }
    static func isDark(_ c: PixelColor) -> Bool { Int(c.r) * 299 + Int(c.g) * 587 + Int(c.b) * 114 < 100_000 }
    private static func invalid(_ why: String) -> AICharacterClient.Failure {
        AICharacterClient.Failure(message: L("Claude가 그린 그림이 규칙에 맞지 않아요 (\(why)). 다시 그려 주세요."))
    }

    // MARK: Drawing

    /// RGBA frames in DogPose order at 1 art px per point (AsciiArt).
    func nativeFrames(flipped: Bool = false) -> [[[UInt8]]] {
        var colors: [Character: PixelColor] = [:]
        for (key, hex) in palette { if let c = key.first { colors[c] = PixelColor(hex: hex) } }
        return DogPose.allCases.map { pose in
            (poses[Self.key(pose)] ?? []).map { rows in
                AsciiArt.rgba((flipped ? rows.map { String($0.reversed()) } : rows).joined(separator: "\n"), colors)
            }
        }
    }

    /// The same frames on the custom characters' 2x canvas (each art pixel a 2x2 block), so they save, show and
    /// preview like every other custom character at the same menu bar size.
    func frames(flipped: Bool = false) -> [[[UInt8]]] { nativeFrames(flipped: flipped).map { $0.map(Self.doubled) } }

    static func doubled(_ rgba: [UInt8]) -> [UInt8] {
        let w = width, d = CustomSprite.density, W = w * d
        var out = [UInt8](repeating: 0, count: rgba.count * d * d)
        for i in 0..<(w * height) {
            let x = i % w, y = i / w
            for dy in 0..<d { for dx in 0..<d {
                let o = ((y * d + dy) * W + x * d + dx) * 4
                out.replaceSubrange(o..<(o + 4), with: rgba[(i * 4)..<(i * 4 + 4)])
            } }
        }
        return out
    }

    /// Frames already on the 34x20 canvas (a preset dog) as FrameArt; nil past `maxColors`. For tests and QA.
    static func from(_ frames: [[[UInt8]]]) -> FrameArt? {
        let chars = Array("oabcdefghijklmnp")
        var palette: [[UInt8]: Character] = [:]
        var poses: [String: [[String]]] = [:]
        for (pose, list) in zip(DogPose.allCases, frames) {
            poses[key(pose)] = list.map { rgba in
                (0..<height).map { y in
                    String((0..<width).map { x -> Character in
                        let i = (y * width + x) * 4
                        guard rgba[i + 3] != 0 else { return "." }
                        let c = Array(rgba[i..<(i + 3)])
                        if let ch = palette[c] { return ch }
                        let ch = palette.count < chars.count ? chars[palette.count] : "?"
                        palette[c] = ch
                        return ch
                    })
                }
            }
        }
        guard palette.count <= maxColors else { return nil }
        return FrameArt(palette: Dictionary(uniqueKeysWithValues: palette.map { rgb, ch in
            (String(ch), String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2]))
        }), poses: poses)
    }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
