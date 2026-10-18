import XCTest
@testable import DogMonitor

final class CatSpriteTests: XCTestCase {
    func testEveryPresetFitsTheCanvasWithEveryMotion() {
        XCTAssertEqual(CatProfile.presets.count, 12)
        XCTAssertEqual(Set(CatProfile.presets.map(\.id)).count, 12)
        let w = DogSpriteCache.canvasWidth, h = DogSpriteCache.canvasHeight
        for preset in CatProfile.presets {
            let rigs = DogPose.allCases.map { CatRig.rigs($0) } + [CatRig.rigs(.hungry)!, CatRig.rigs(.eat)!]
            let grids = CatRenderer.grids(preset.profile, rigs)
            let span = CatRenderer.union(grids)!
            XCTAssertLessThanOrEqual(span.maxX - span.minX + 1, w, "\(preset.id) too wide")
            for g in grids.joined() { XCTAssertGreaterThanOrEqual(g.bounds!.minY, 0) }
            let art = CatRenderer.render(preset.profile)
            XCTAssertEqual(art.poses.count, DogPose.allCases.count)
            for frames in art.poses { XCTAssertGreaterThanOrEqual(frames.count, 3); frames.forEach { XCTAssertEqual($0.count, w * h * 4) } }
            XCTAssertEqual(art.extras[.hungry]?.count, 4)
            XCTAssertEqual(art.extras[.eat]?.count, 4)
            XCTAssertNil(art.extras[.special])
            // Lit and outline pixels on the edges, so it reads on both bars.
            XCTAssertTrue(art.poses[DogPose.walk.rawValue][0].contains { $0 != 0 })
        }
    }

    func testCharacterAPI() throws {
        let cat = CatCharacter(CatProfile.presets[3], pixelSize: 1)
        XCTAssertEqual(cat.id, "cat-tuxedo")
        XCTAssertEqual(cat.displayName, "턱시도")
        XCTAssertEqual(cat.imageSize, NSSize(width: 34, height: 20))
        XCTAssertEqual(cat.frames(for: .sprint).count, 6)
        XCTAssertEqual(cat.frames(forExtra: .eat)?.count, 4)
        XCTAssertNil(cat.frames(forExtra: .special))
        // Crisp at the preview page's 8x: an on-demand image draws nearest-neighbour at any scale.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 272, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cat.frames(for: .walk)[0].draw(in: NSRect(x: 0, y: 0, width: 272, height: 160))
        NSGraphicsContext.restoreGraphicsState()
        let alphas = Set((0..<272).map { Int(((rep.colorAt(x: $0, y: 120)?.alphaComponent ?? 0) * 255).rounded()) })
        XCTAssertTrue(alphas.isSubset(of: [0, 255]), "no smoothing between art pixels")
        XCTAssertEqual(CatCharacter.presets.map(\.id).prefix(1), ["cat-korean-shorthair"])
        let data = try JSONEncoder().encode(CatProfile.defaultCat)
        XCTAssertEqual(try JSONDecoder().decode(CatProfile.self, from: data), CatProfile.defaultCat)
        for p in CatProfile.presets { XCTAssertFalse(p.name.contains("\u{2014}")) }
    }

    /// CAT_QA_DIR=/path swift test --filter CatSpriteTests writes an 8x sheet per preset (rows: 7 poses, hungry, eat)
    /// and 1x / 2x menu bar strips on light and dark bars.
    func testWriteQASheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["CAT_QA_DIR"] else { throw XCTSkip("CAT_QA_DIR not set") }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var all: [[[UInt8]]] = []
        for preset in CatProfile.presets {
            let art = CatRenderer.render(preset.profile)
            try png(SpritePreview.sheet(art.poses + [art.extras[.hungry]!, art.extras[.eat]!]), url.appendingPathComponent("sheet-\(preset.id).png"))
            all.append(art.poses[DogPose.walk.rawValue] + [art.poses[0][0], art.extras[.eat]![0], art.extras[.hungry]![2]])
        }
        for (name, bg) in [("light", (236, 236, 236)), ("dark", (42, 42, 42))] {
            for s in [1, 2] { try png(strip(all, bg: bg, scale: s), url.appendingPathComponent("menubar-\(name)@\(s)x.png")) }
        }
    }

    private func strip(_ rows: [[[UInt8]]], bg: (Int, Int, Int), scale s: Int) -> CGImage {
        let w = 34, h = 20, gap = 4, cols = rows.map(\.count).max()!
        let W = 8 + cols * (w + gap) * s, H = 8 + rows.count * (h + 4) * s
        let ctx = DogRenderer.context(width: W, height: H)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bg.0) / 255, green: CGFloat(bg.1) / 255, blue: CGFloat(bg.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none
        for (r, frames) in rows.enumerated() {
            for (c, f) in frames.enumerated() {
                ctx.draw(DogRenderer.cgImage(f), in: CGRect(x: 4 + c * (w + gap) * s, y: H - 4 - (r + 1) * (h + 4) * s, width: w * s, height: h * s))
            }
        }
        return ctx.makeImage()!
    }

    private func png(_ image: CGImage, _ url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
    }
}
