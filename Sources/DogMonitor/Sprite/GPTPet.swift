import AppKit
import Compression
import ImageIO
import UniformTypeIdentifiers

/// ChatGPT / Codex 펫 in and out. A pet is a sprite sheet of 8 columns of 192 x 208 cells: v2 (the desktop standard)
/// is 1536 x 2288, 11 rows; v1 and the web upload are 1536 x 1872, 9 rows. Rows 0...8 are idle, running-right,
/// running-left, waving, jumping, failed, waiting, running (busy at work) and review; rows 9 and 10 are 16 still
/// look directions. Next to it, pet.json: id, displayName, description, spriteVersionNumber (2), spritesheetPath.
/// Desktop pets live in ${CODEX_HOME:-~/.codex}/pets/<id>/.
/// 가져오기 turns a sheet into an HD pack (PackArt, smooth, density 8) in CharacterPack.defaultRoot, so it is listed,
/// previewed, carried in 내 설정 and drawn exactly like any pack. 내보내기 draws one of our own characters as a v2 sheet.
enum GPTPet {
    static let columns = 8, cellWidth = 192, cellHeight = 208, v2Rows = 11, v1Rows = 9
    static let sheetWidth = columns * cellWidth, sheetHeight = v2Rows * cellHeight
    /// Frames each animation row plays (the cells after them are blank; idle's 7th is the still neutral look).
    static let rowFrames = [6, 8, 8, 4, 5, 8, 6, 6, 6]
    /// Seconds per frame by row: the hatch-pet timings averaged (idle 1100 ms over 6 frames, waving 700 over 4 ...).
    static let rowSeconds = [0.18, 0.13, 0.13, 0.17, 0.17, 0.15, 0.17, 0.14, 0.17]
    /// Untrusted files: the file (or a zip entry) and the decoded picture are capped before anything is decoded.
    static let maxFileBytes = 50 << 20, maxJSONBytes = 64 * 1024, maxSide = 6144, maxZipEntries = 200
    static let packDensity = 8

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static var notSheet: Failure {
        Failure(L("ChatGPT 펫 시트가 아니에요. 가로 8칸, 세로 11칸(1536x2288)이나 9칸(1536x1872)으로 나뉜 투명 PNG나 WebP 를 넣어 주세요."))
    }

    // MARK: Grid

    /// Rows and cell size of a sheet `width` x `height`: 8 columns, and 11 or 9 rows of cells shaped 192:208, at any scale.
    static func grid(width: Int, height: Int) -> (rows: Int, cellWidth: Double, cellHeight: Double)? {
        guard width >= columns, height > 0 else { return nil }
        let cw = Double(width) / Double(columns), ch = cw * Double(cellHeight) / Double(cellWidth)
        for rows in [v2Rows, v1Rows] where abs(Double(height) / Double(rows) - ch) <= 1 {
            return (rows, cw, Double(height) / Double(rows))
        }
        return nil
    }

    /// The drawn cells of rows 0...8 (blank ones skipped), cropped to one box that holds every one of them, so the
    /// character keeps its place and size from frame to frame. Top row first.
    static func cells(_ sheet: CGImage) throws -> [[CGImage]] {
        guard let g = grid(width: sheet.width, height: sheet.height) else { throw notSheet }
        let bitmap = Bitmap(sheet)
        typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)
        var drawn: [[(x: Int, y: Int)]] = []
        var union: Box?
        for row in 0..<min(g.rows, rowFrames.count) {
            var found: [(x: Int, y: Int)] = []
            for col in 0..<rowFrames[row] {
                let x = Int((Double(col) * g.cellWidth).rounded()), y = Int((Double(row) * g.cellHeight).rounded())
                let w = Int(g.cellWidth), h = Int(g.cellHeight)
                var box: Box?, count = 0
                for py in y..<min(y + h, bitmap.height) {
                    for px in x..<min(x + w, bitmap.width) where bitmap.alpha(px, py) > 16 {
                        count += 1
                        let b = box ?? (px - x, py - y, px - x, py - y)
                        box = (min(b.x0, px - x), min(b.y0, py - y), max(b.x1, px - x), max(b.y1, py - y))
                    }
                }
                guard let box, count >= 8 else { continue }   // blank, or a stray speck
                found.append((x, y))
                let u = union ?? box
                union = (min(u.x0, box.x0), min(u.y0, box.y0), max(u.x1, box.x1), max(u.y1, box.y1))
            }
            drawn.append(found)
        }
        guard let u = union else { throw Failure(L("시트에 그림이 하나도 없어요.")) }
        return drawn.map { row in
            row.compactMap { sheet.cropping(to: CGRect(x: $0.x + u.x0, y: $0.y + u.y0, width: u.x1 - u.x0 + 1, height: u.y1 - u.y0 + 1)) }
        }
    }

    // MARK: Import

    /// A pet as read from a file: its sheet and what pet.json says (nil without one).
    struct Source {
        var sheet: CGImage
        var id: String?
        var name: String?
    }

    /// The fields we use from pet.json; everything else in it is ignored.
    private struct Manifest: Decodable {
        let id: String?
        let displayName: String?
        let spritesheetPath: String?
    }

    /// A sheet (PNG, WebP), a pet folder (pet.json + its sheet) or a zip of either.
    static func read(_ url: URL) throws -> Source {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw Failure(L("바로가기(링크)는 읽지 않아요. 원래 파일을 넣어 주세요.")) }
        let stem = url.deletingPathExtension().lastPathComponent
        if values?.isDirectory == true {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return try source(files: Dictionary(names.map { ($0, $0) }, uniquingKeysWith: { a, _ in a }), folder: stem) {
                try file(url.appendingPathComponent($0))
            }
        }
        let data = try file(url)
        if url.pathExtension.lowercased() == "zip" {
            let entries = try ZipReader.entries(data)
            // Only names at the top or one folder down count; a pet folder zipped keeps its folder name.
            let byName = Dictionary(entries.filter { $0.name.split(separator: "/").count <= 2 && !$0.name.hasSuffix("/") && !$0.name.contains("._") }
                .map { ($0.name.split(separator: "/").last.map(String.init) ?? $0.name, $0) }, uniquingKeysWith: { a, _ in a })
            return try source(files: byName.mapValues(\.name), folder: stem) { name in
                guard let e = entries.first(where: { $0.name == name }) else { throw notSheet }
                return try ZipReader.read(e, in: data, maxBytes: maxFileBytes)
            }
        }
        return Source(sheet: try image(data), id: stem, name: nil)
    }

    /// `files`: plain name -> how to ask `load` for it.
    private static func source(files: [String: String], folder: String, load: (String) throws -> Data) throws -> Source {
        var manifest: Manifest?
        if let json = files["pet.json"] {
            let data = try load(json)
            guard data.count <= maxJSONBytes, let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
                throw Failure(L("pet.json 을 읽지 못했어요."))
            }
            manifest = m
        }
        // spritesheetPath is a plain file name next to pet.json; anything with a path in it is refused.
        let named = manifest?.spritesheetPath.flatMap { $0.contains("/") || $0.contains("\\") || $0.hasPrefix(".") ? nil : $0 }
        let pictures = files.keys.filter { ["png", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        guard let sheet = named.flatMap({ files[$0] }) ?? files["spritesheet.webp"] ?? files["spritesheet.png"]
                ?? (pictures.count == 1 ? files[pictures[0]] : nil) else {
            throw Failure(L("펫 폴더나 zip 안에서 스프라이트 시트(spritesheet.webp 나 .png)를 찾지 못했어요."))
        }
        return Source(sheet: try image(load(sheet)), id: manifest?.id ?? folder, name: manifest?.displayName)
    }

    /// A regular file of at most maxFileBytes (never a link).
    private static func file(_ url: URL) throws -> Data {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular else { throw Failure(L("파일을 읽지 못했어요.")) }
        guard (attrs?[.size] as? Int ?? .max) <= maxFileBytes else { throw Failure(L("파일이 너무 커요. 50MB 까지 넣을 수 있어요.")) }
        return try Data(contentsOf: url)
    }

    /// The picture, its size checked before it is decoded.
    static func image(_ data: Data) throws -> CGImage {
        // Only PNG or WebP: ImageIO would otherwise decode any format it knows (TIFF, PSD, ...) from a renamed file.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String?, [UTType.png.identifier, UTType.webP.identifier].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure(L("그림을 읽지 못했어요. PNG 나 WebP 파일인지 확인해 주세요."))
        }
        guard w <= maxSide, h <= maxSide, grid(width: w, height: h) != nil else { throw notSheet }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure(L("그림을 읽지 못했어요. PNG 나 WebP 파일인지 확인해 주세요.")) }
        return image
    }

    /// Our frame keys and the rows they play, in order of preference (a row left blank falls to the next).
    /// Negative: that row mirrored (running-left drawn the other way is running-right).
    static let poseRows: [(key: String, rows: [Int])] = [
        ("lying", [0, 1]),                                            // 대기 -> 쉬기
        ("slowWalk", [1, -2, 0]), ("walk", [1, -2, 0]), ("fastWalk", [1, -2, 0]), ("run", [1, -2, 0]),   // 달리기 -> 걷기 · 달리기
        ("sprint", [7, 1, -2, 0]),                                    // 작업 중 -> 바쁨
        ("exhausted", [5, 0]),                                        // 실패 -> 속상
        ("hungry", [6]),                                              // 기다림 -> 배고파 기다리기
    ]
    /// The special moment's takes, in this order, whichever the sheet has: 인사, 점프, 생각.
    static let specialRows = [3, 4, 8]
    static var specialNames: [Int: String] { [3: L("인사"), 4: L("점프"), 8: L("생각")] }

    /// The pack folder id for a pet id: pack-gpt-<slug>.
    static func packID(_ petID: String?) -> String {
        let slug = (petID ?? "").lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "pack-gpt-" + (slug.isEmpty ? "pet" : String(slug.prefix(30)))
    }

    /// Writes `source` as a pack under `root` (replacing an earlier import of the same pet) and loads it back.
    @discardableResult
    static func importPack(_ source: Source, root: URL) throws -> CharacterPack {
        let rows = try cells(source.sheet)
        let w = SpriteCanvas.width * packDensity, h = SpriteCanvas.height * packDensity
        func frames(_ list: [Int]) -> [CGImage]? {
            for r in list {
                guard let cells = rows.indices.contains(abs(r)) ? rows[abs(r)] : nil, !cells.isEmpty else { continue }
                return cells.map { place($0, width: w, height: h, mirrored: r < 0) }
            }
            return nil
        }
        var out: [String: [CGImage]] = [:]
        for (key, list) in poseRows { out[key] = frames(list) }
        for key in ["lying", "walk"] where out[key] == nil {   // only a jump or a wave drawn: it stands in
            out[key] = rows.first { !$0.isEmpty }.map { $0.map { place($0, width: w, height: h, mirrored: false) } }
        }
        for key in ["slowWalk", "fastWalk", "run", "sprint", "exhausted"] where out[key] == nil { out[key] = out["walk"] }
        let specials = specialRows.filter { rows.indices.contains($0) && !rows[$0].isEmpty }
        for (i, r) in specials.enumerated() { out[PackArt.takeKey(.special, i)] = frames([r]) }
        // A pose plays 2...12 frames (lying 1...12), an extra 2...16: a single frame is shown twice.
        for (key, list) in out { out[key] = Array((list.count == 1 && key != "lying" ? list + list : list).prefix(12)) }
        let id = packID(source.id)
        let name = String((source.name ?? source.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var seconds: [String: Double] = ["lying": rowSeconds[0], "sprint": rowSeconds[7], "exhausted": rowSeconds[5], "hungry": rowSeconds[6]]
        if let first = specials.first { seconds["special"] = rowSeconds[first] }
        var manifest: [String: Any] = [
            "version": 1, "id": id, "name": name.isEmpty ? L("ChatGPT 펫") : name, "density": packDensity, "smooth": true,
            "blurb": L("ChatGPT 펫 시트에서 가져왔어요"),
            "frames": out.mapValues(\.count),
            "seconds": seconds.filter { out[$0.key] != nil },
        ]
        if let first = specials.first { manifest["special"] = specialNames[first] }

        let dir = root.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("frames", isDirectory: true), withIntermediateDirectories: true)
        do {
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("pack.json"))
            for (key, list) in out {
                for (i, image) in list.enumerated() {
                    try png(image).write(to: dir.appendingPathComponent("frames/\(key)-\(i).png"))
                }
            }
            return try CharacterPack(folder: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// `cell` fitted into a `width` x `height` frame, feet on the bottom row, centred.
    private static func place(_ cell: CGImage, width: Int, height: Int, mirrored: Bool) -> CGImage {
        let ctx = DogRenderer.context(width: width, height: height)!
        let s = min(Double(width) / Double(cell.width), Double(height) / Double(cell.height))
        let w = Double(cell.width) * s, h = Double(cell.height) * s
        if mirrored { ctx.translateBy(x: CGFloat(width), y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.interpolationQuality = .high
        ctx.draw(cell, in: CGRect(x: (Double(width) - w) / 2, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    // MARK: Export

    /// One of our own characters that may leave as a pet: the dogs, the cats, the built-in originals and the user's own
    /// 나만의 캐릭터. Packs never do (personal packs and third-party characters stay on this Mac).
    struct Exportable: Identifiable {
        let id: String
        let name: String
        let smooth: Bool
        /// Its frames at `pixelSize` points per art point.
        let make: (CGFloat) -> DogSpriteCache
    }

    static func exportables(store: CustomCharacterStore = .shared) -> [Exportable] {
        let dogs = DogProfile.presets.map { p in
            Exportable(id: "dog-\(p.id)", name: p.name, smooth: false) { DogSpriteCache(profile: p.profile, pixelSize: $0, style: .auto, outfit: nil) }
        }
        let ready: [any AnimatedCharacter] = CatCatalog.all + OriginalCharacterSet2.all
        let others = ready.map { c in
            Exportable(id: c.id, name: c.displayName, smooth: c.smooth) { DogSpriteCache(c, pixelSize: $0, style: .auto, outfit: .some(nil)) }
        }
        let mine = store.characters.map { c in
            Exportable(id: "my-" + c.id.uuidString.prefix(8).lowercased(), name: c.displayName, smooth: c.real != nil) { k in
                c.real.map { DogSpriteCache(real: $0, pixelSize: k) } ?? DogSpriteCache(profile: .defaultDog, custom: c.frames, pixelSize: k, style: .auto)
            }
        }
        return dogs + others + mine
    }

    /// The 11 rows of a v2 sheet from our motions: each a list of (frame, mirrored).
    static func plan(_ c: DogSpriteCache) -> [[(NSImage, Bool)]] {
        func take(_ frames: [NSImage], _ n: Int, mirrored: Bool = false) -> [(NSImage, Bool)] {
            // More frames than the row has: spread over them; fewer: looped.
            (0..<n).map { (frames.count >= n ? frames[$0 * frames.count / n] : frames[$0 % frames.count], mirrored) }
        }
        let special = c.takeCount(.special) > 0 ? c.frames(for: .walk, extra: .special) : nil
        let jump = c.takeCount(.special) > 1 ? c.frames(for: .walk, extra: .special, variant: 1) : special
        let idle = c.frames(for: .lying)
        // Awake and standing, with no bubble over it (lying draws a "z", and a mirrored "z" reads as an "S").
        let rest = c.frames(for: .slowWalk)[0]
        let rows: [[(NSImage, Bool)]] = [
            take([rest], 6) + [(rest, false)],                        // idle, then the neutral look
            take(c.frames(for: .walk), 8),                            // running-right
            take(c.frames(for: .walk), 8, mirrored: true),            // running-left
            take(special ?? c.frames(for: .slowWalk), 4),             // waving
            take(jump ?? c.frames(for: .run), 5),                     // jumping
            take(c.frames(for: .exhausted), 8),                       // failed
            take(c.frames(forExtra: .hungry) ?? idle, 6),             // waiting
            take(c.frames(for: .sprint), 6),                          // running (busy)
            take(c.frames(forExtra: .eat) ?? c.frames(for: .slowWalk), 6),   // review
        ]
        // Looks 000...157.5 face up and right, 180...337.5 down and left (000 and 180 straight on).
        let looks = (0..<16).map { (rest, $0 > 8) }
        return rows + [Array(looks[0..<8]), Array(looks[8..<16])]
    }

    /// A v2 sheet (1536 x 2288, transparent): every frame through one box, scaled as large as a cell takes
    /// (pixel art by a whole number, so its pixels stay square), feet 6 px above the cell's bottom, centred.
    static func sheet(_ e: Exportable) -> CGImage {
        // The box every frame needs, in points, from a 4x draw.
        let probe = e.make(4), size = probe.imageSize
        var box: CGRect?
        for row in plan(probe) {
            for (image, _) in row {
                let ctx = DogRenderer.context(width: Int(size.width), height: Int(size.height))!
                draw(image, in: CGRect(origin: .zero, size: size), ctx, smooth: e.smooth)
                let b = Bitmap(ctx.makeImage()!)
                for y in 0..<b.height {
                    for x in 0..<b.width where b.alpha(x, y) > 16 {
                        let r = CGRect(x: x, y: b.height - 1 - y, width: 1, height: 1)   // bottom-up, like CG
                        box = box?.union(r) ?? r
                    }
                }
            }
        }
        let fit = (box ?? CGRect(origin: .zero, size: size)).applying(CGAffineTransform(scaleX: 0.25, y: 0.25))
        var k = min(Double(cellWidth - 8) / fit.width, Double(cellHeight - 12) / fit.height)
        if !e.smooth { k = max(1, k.rounded(.down)) }
        let cache = e.make(k), canvas = NSSize(width: Double(SpriteCanvas.width) * k, height: Double(SpriteCanvas.height) * k)
        let ctx = DogRenderer.context(width: sheetWidth, height: sheetHeight)!
        for (r, row) in plan(cache).enumerated() {
            for (c, (image, mirrored)) in row.enumerated() {
                let cellX = Double(c * cellWidth), cellY = Double(sheetHeight - (r + 1) * cellHeight)
                ctx.saveGState()
                if mirrored {   // about the cell's centre, where the box is centred
                    ctx.translateBy(x: cellX * 2 + Double(cellWidth), y: 0)
                    ctx.scaleBy(x: -1, y: 1)
                }
                let x = cellX + Double(cellWidth) / 2 - fit.midX * k, y = cellY + 6 - fit.minY * k
                draw(image, in: CGRect(x: x, y: y, width: canvas.width, height: canvas.height), ctx, smooth: e.smooth)
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()!
    }

    private static func draw(_ image: NSImage, in rect: CGRect, _ ctx: CGContext, smooth: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { image.draw(in: rect) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// <folder>/<id>/ with spritesheet.png and pet.json, ready for ChatGPT or Codex. Returns that folder.
    @discardableResult
    static func export(_ e: Exportable, to folder: URL) throws -> URL {
        let dir = folder.appendingPathComponent(e.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png(sheet(e)).write(to: dir.appendingPathComponent("spritesheet.png"), options: .atomic)
        let json: [String: Any] = ["id": e.id, "displayName": e.name, "description": L("캐릭모니터에서 온 \(e.name)"),
                                   "spriteVersionNumber": 2, "spritesheetPath": "spritesheet.png"]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("pet.json"), options: .atomic)
        return dir
    }

    #if !MAS   // the App Store build's sandbox has no ~/.codex
    /// Where Codex and the ChatGPT desktop app look for custom pets.
    static var codexPets: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("pets", isDirectory: true)
    }

    /// The pet folders on this Mac (each with a pet.json), by name.
    static func discovered(in root: URL = codexPets) -> [(url: URL, name: String)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pet.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(20)
            .map { url in
                let m = (try? Data(contentsOf: url.appendingPathComponent("pet.json"))).flatMap { $0.count <= maxJSONBytes ? $0 : nil }
                    .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
                return (url, String((m?.displayName ?? url.lastPathComponent).prefix(40)))
            }
    }
    #endif
}

/// Reads entries of a zip in memory, never writing them out: stored and deflated only, no zip64. A name that could
/// lead out of a folder (absolute, "..", a backslash) refuses the whole archive.
enum ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let offset: Int
    }

    static var bad: GPTPet.Failure { GPTPet.Failure(L("zip 파일을 읽지 못했어요.")) }

    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains(":")
            && !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func u16(_ d: Data, _ at: Int) throws -> Int {
        guard at >= 0, at + 2 <= d.count else { throw bad }
        return Int(d[d.startIndex + at]) | Int(d[d.startIndex + at + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) throws -> Int { try u16(d, at) | u16(d, at + 2) << 16 }

    static func entries(_ d: Data) throws -> [Entry] {
        // The end record: the last "PK\5\6" within the final 64 KB + 22 bytes.
        var end = -1
        for i in stride(from: d.count - 22, through: max(0, d.count - 65_557), by: -1) {
            if try u32(d, i) == 0x0605_4B50 { end = i; break }
        }
        guard end >= 0 else { throw bad }
        let count = try u16(d, end + 10)
        guard count <= GPTPet.maxZipEntries else { throw GPTPet.Failure(L("zip 안에 파일이 너무 많아요.")) }
        var at = try u32(d, end + 16), out: [Entry] = []
        for _ in 0..<count {
            guard try u32(d, at) == 0x0201_4B50 else { throw bad }
            let n = try u16(d, at + 28), extra = try u16(d, at + 30), comment = try u16(d, at + 32)
            guard at + 46 + n <= d.count, let name = String(data: d.subdata(in: (d.startIndex + at + 46)..<(d.startIndex + at + 46 + n)), encoding: .utf8) else { throw bad }
            guard isSafe(name) else { throw GPTPet.Failure(L("zip 안에 폴더 밖을 가리키는 경로가 있어서 열지 않았어요.")) }
            out.append(Entry(name: name, method: UInt16(try u16(d, at + 10)), compressedSize: try u32(d, at + 20),
                             size: try u32(d, at + 24), offset: try u32(d, at + 42)))
            at += 46 + n + extra + comment
        }
        return out
    }

    /// One entry's bytes, at most `maxBytes` unpacked.
    static func read(_ e: Entry, in d: Data, maxBytes: Int) throws -> Data {
        guard e.size <= maxBytes, e.compressedSize <= d.count, try u32(d, e.offset) == 0x0403_4B50 else { throw bad }
        let start = e.offset + 30 + (try u16(d, e.offset + 26)) + (try u16(d, e.offset + 28))
        guard start + e.compressedSize <= d.count else { throw bad }
        let packed = d.subdata(in: (d.startIndex + start)..<(d.startIndex + start + e.compressedSize))
        switch e.method {
        case 0:
            guard packed.count == e.size else { throw bad }
            return packed
        case 8:   // raw deflate, which COMPRESSION_ZLIB is
            guard e.size > 0 else { return Data() }
            var out = Data(count: e.size)
            let written = out.withUnsafeMutableBytes { dst in
                packed.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.size else { throw bad }
            return out
        default:
            throw bad
        }
    }
}
