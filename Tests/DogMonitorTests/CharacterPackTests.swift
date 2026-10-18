import XCTest
@testable import DogMonitor

final class CharacterPackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A dark-outlined box standing on the bottom row, `w` x `h` px (laid out for 68 x 40, scaled to fit).
    private func png(_ w: Int = 68, _ h: Int = 40) -> Data {
        let ctx = DogRenderer.context(width: w, height: h)!
        ctx.scaleBy(x: CGFloat(w) / 68, y: CGFloat(h) / 40)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 0, width: 28, height: 24))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.7, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 22, y: 2, width: 24, height: 20))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    @discardableResult
    private func makePack(_ id: String = "pack-test", frames: [String: Int]? = nil, seconds: [String: Double]? = nil,
                          jsonID: String? = nil, size: (Int, Int) = (68, 40), extra: [String: Any] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let counts = frames ?? ["lying": 1, "slowWalk": 2, "walk": 4, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2, "special": 6]
        var json: [String: Any] = ["version": 1, "id": jsonID ?? id, "name": "테스트", "special": "필살기", "blurb": "한 줄", "frames": counts]
        if let seconds { json["seconds"] = seconds }
        json.merge(extra) { $1 }
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("pack.json"))
        for (key, n) in counts {
            for i in 0..<n { try png(size.0, size.1).write(to: framesDir.appendingPathComponent("\(key)-\(i).png")) }
        }
        return dir
    }

    func testValidPackLoads() throws {
        let dir = try makePack(seconds: ["walk": 0.2, "special": 0.08])
        let pack = try CharacterPack(folder: dir)
        XCTAssertEqual(pack.id, "pack-test")
        XCTAssertEqual(pack.displayName, "테스트")
        XCTAssertEqual(pack.specialTitle, "필살기")
        XCTAssertEqual(DogPose.allCases.map { pack.frames(for: $0).count }, [1, 2, 4, 2, 2, 2, 2])
        XCTAssertEqual(pack.frames(forExtra: .special)?.count, 6)
        XCTAssertNil(pack.frames(forExtra: .hungry))
        let image = try XCTUnwrap(pack.frames(for: .walk).first)
        XCTAssertEqual(image.size, NSSize(width: 34, height: 20))
        // Drawn at 2 px per point the light-bar art comes back pixel for pixel; a dark bar lifts the outline.
        let light = OriginalSet2Tests.pixels(image, .aqua, width: 68, height: 40)
        let dark = OriginalSet2Tests.pixels(image, .darkAqua, width: 68, height: 40)
        XCTAssertEqual(light.colorAt(x: 20, y: 39)!.alphaComponent, 1)
        XCTAssertEqual(light.colorAt(x: 19, y: 39)!.alphaComponent, 0)
        XCTAssertLessThan(light.colorAt(x: 20, y: 39)!.redComponent, 0.2)
        XCTAssertGreaterThan(dark.colorAt(x: 20, y: 39)!.redComponent, 0.4)
        XCTAssertEqual(light.colorAt(x: 30, y: 30), dark.colorAt(x: 30, y: 30))   // the body is untouched
        // The menu bar cache takes the pack's own timing, else the app's.
        let cache = DogSpriteCache(pack)
        XCTAssertEqual(cache.frameDuration(for: .walk, cpu: 0.2, extra: nil), 0.2)
        XCTAssertEqual(cache.frameDuration(for: .run, cpu: 0.5, extra: nil), DogSpriteCache.frameDuration(for: .run, cpu: 0.5))
        XCTAssertEqual(cache.frameDuration(for: .walk, cpu: 0.2, extra: .special), 0.08)
        XCTAssertEqual(cache.frameDuration(for: .walk, cpu: 0.2, extra: .eat), DogSpriteCache.extraFrameDuration(.eat))
        XCTAssertEqual(cache.availableExtras, [.special])
        XCTAssertEqual(CharacterPack.loadAll(root: root).map(\.id), ["pack-test"])
    }

    /// HD packs: `density` px per point, `smooth` illustrations drawn with interpolation and made-ahead bar copies.
    func testDensityAndSmooth() throws {
        let px = try CharacterPack(folder: try makePack("pack-px"))
        XCTAssertEqual(px.density, 2)
        XCTAssertFalse(px.smooth)
        XCTAssertFalse(DogSpriteCache(px).smooth)

        let hd = try CharacterPack(folder: try makePack("pack-hd", size: (272, 160), extra: ["density": 8, "smooth": true]))
        XCTAssertEqual(hd.density, 8)
        XCTAssertTrue(hd.smooth)
        let image = try XCTUnwrap(hd.frames(for: .walk).first)
        XCTAssertEqual(image.size, NSSize(width: 34, height: 20))   // never taller than the 20 pt bar slot
        XCTAssertEqual(image.representations.map(\.pixelsWide), [34, 68, 272])   // bar 1x and 2x made ahead, then the original
        XCTAssertTrue(DogSpriteCache(hd, pixelSize: 3).smooth)

        // Magnified 4x: a smooth pack blends across the box edge over several px; a pixel pack stays (nearly) a step.
        func blend(_ c: CharacterPack) -> Int {
            let big = DogSpriteCache.scaled(c.frames(for: .walk)[0], by: 4, smooth: c.smooth)
            let rep = OriginalSet2Tests.pixels(big, .aqua, width: 136, height: 80)
            return (34...46).filter { (0.05...0.95).contains(rep.colorAt(x: $0, y: 79)!.alphaComponent) }.count
        }
        let soft = try CharacterPack(folder: try makePack("pack-soft", size: (34, 20), extra: ["density": 1, "smooth": true]))
        XCTAssertGreaterThanOrEqual(blend(soft), 3)
        XCTAssertLessThanOrEqual(blend(px), 1)

        // Players: linear filtering and an exact-size high-quality bitmap for smooth frames, nearest otherwise.
        let view = SpriteView(frame: .zero)
        view.setFrames([image], smooth: true)
        XCTAssertEqual(view.layer?.magnificationFilter, .linear)
        view.setFrames([image])
        XCTAssertEqual(view.layer?.magnificationFilter, .nearest)
        XCTAssertEqual(SpriteView.bitmap(image, scale: 2)?.width, 68)

        // Frames must be exactly 34N x 20N, N within the kind's range.
        let bad: [(String, (Int, Int), [String: Any])] = [
            ("pack-hd-wrongsize", (68, 40), ["density": 8, "smooth": true]),
            ("pack-px-dense", (204, 120), ["density": 6]),
            ("pack-hd-over", (306, 180), ["density": 9, "smooth": true]),
            ("pack-zero", (68, 40), ["density": 0]),
        ]
        for (name, size, extra) in bad {
            XCTAssertThrowsError(try CharacterPack(folder: try makePack(name, size: size, extra: extra)), name)
        }
    }

    func testBadPacksAreRejected() throws {
        try makePack("pack-small", size: (34, 20))
        try makePack("pack-nopose", frames: ["lying": 1, "walk": 2])
        try makePack("pack-wrongid", jsonID: "pack-other")
        try makePack("pack-Bad_ID")
        try makePack("pack-fast", seconds: ["walk": 0.001])
        try makePack("pack-many", frames: ["lying": 13, "slowWalk": 2, "walk": 2, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2])
        for name in ["pack-small", "pack-nopose", "pack-wrongid", "pack-Bad_ID", "pack-fast", "pack-many"] {
            XCTAssertThrowsError(try CharacterPack(folder: root.appendingPathComponent(name)), name)
        }

        // Links never lead out of the root: a linked frame, a linked frames folder, a linked pack folder.
        let outside = try makePack("outside")
        let frameLink = try makePack("pack-framelink")
        let walk = frameLink.appendingPathComponent("frames/walk-0.png")
        try FileManager.default.removeItem(at: walk)
        try FileManager.default.createSymbolicLink(at: walk, withDestinationURL: outside.appendingPathComponent("frames/walk-0.png"))
        let dirLink = try makePack("pack-dirlink")
        try FileManager.default.removeItem(at: dirLink.appendingPathComponent("frames"))
        try FileManager.default.createSymbolicLink(at: dirLink.appendingPathComponent("frames"), withDestinationURL: outside.appendingPathComponent("frames"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("pack-linked"), withDestinationURL: outside)
        for name in ["pack-framelink", "pack-dirlink", "pack-linked"] {
            XCTAssertThrowsError(try CharacterPack(folder: root.appendingPathComponent(name)), name)
        }

        // An oversized file is refused before it is decoded.
        let big = try makePack("pack-big")
        try Data(count: CharacterPack.maxPNGBytes + 1).write(to: big.appendingPathComponent("frames/run-1.png"))
        XCTAssertThrowsError(try CharacterPack(folder: big))

        try makePack("pack-good")
        XCTAssertEqual(CharacterPack.loadAll(root: root).map(\.id), ["pack-good"])
        XCTAssertTrue(CharacterPack.loadAll(root: root.appendingPathComponent("missing")).isEmpty)
    }

    func testTakesLinesAndVoice() throws {
        var counts = ["lying": 1, "slowWalk": 2, "walk": 4, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2, "special": 6]
        counts["special.2"] = 3
        let pack = try CharacterPack(folder: try makePack("pack-takes", frames: counts, extra: [
            "persona": "cry", "cries": ["삐익", "", "너무너무너무긴소리"],
            "say": ["special.2": ["두 번째 기술!\n줄바꿈", ""], "special": [String(repeating: "가", count: 80)]]]))
        XCTAssertEqual(pack.extraVariants(.special).map(\.count), [6, 3])
        XCTAssertEqual(pack.extraVariants(.eat).count, 0)
        XCTAssertEqual(pack.lines(forExtra: .special, variant: 1), ["두 번째 기술! 줄바꿈"])
        XCTAssertEqual(pack.lines(forExtra: .special, variant: 0).first?.count, CharacterPack.maxLineLength)
        XCTAssertEqual(pack.voice, .cry)
        XCTAssertEqual(pack.cries, ["삐익"])
        let cache = DogSpriteCache(pack)
        XCTAssertEqual(cache.takeCount(.special), 2)
        XCTAssertEqual(cache.frames(for: .walk, extra: .special, variant: 1).count, 3)
        XCTAssertEqual(cache.frames(for: .walk, extra: .special, variant: 5).count, 6)   // no such take: the first
        XCTAssertEqual(cache.lines(forExtra: .special, variant: 1), ["두 번째 기술! 줄바꿈"])
        // An unknown 말투 is ignored; a take after a gap, a take without its plain key or a line for a missing take is refused.
        XCTAssertNil(try CharacterPack(folder: try makePack("pack-voice", extra: ["persona": "shouty"])).voice)
        var gap = counts; gap["special.2"] = nil; gap["special.3"] = 2
        var orphan = counts; orphan["eat.2"] = 2
        XCTAssertThrowsError(try CharacterPack(folder: try makePack("pack-gap", frames: gap)))
        XCTAssertThrowsError(try CharacterPack(folder: try makePack("pack-orphan", frames: orphan)))
        XCTAssertThrowsError(try CharacterPack(folder: try makePack("pack-say", extra: ["say": ["eat": ["냠"]]])))
    }
}
