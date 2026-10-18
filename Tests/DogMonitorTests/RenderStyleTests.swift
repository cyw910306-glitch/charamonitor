import XCTest
@testable import DogMonitor

/// 그림 스타일 (RenderStyle) and 배경 다듬기 (CutoutEdit): the pure pieces.
final class RenderStyleTests: XCTestCase {
    private let X: [UInt8] = [10, 20, 30, 255], O: [UInt8] = [0, 0, 0, 0]

    private func px(_ rgba: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [UInt8] { Array(rgba[((y * w + x) * 4)..<((y * w + x) * 4 + 4)]) }

    // MARK: EPX

    func testEPXDoublesUntilIllustrationSize() {
        let frame = [UInt8](repeating: 0, count: 34 * 20 * 4)
        let one = RenderStyle.epx(frame, w: 34, h: 20)
        XCTAssertEqual([one.1, one.2], [68, 40])
        XCTAssertEqual(one.0.count, 68 * 40 * 4)
        let big = RenderStyle.smoothed(frame, w: 34, h: 20)
        XCTAssertEqual([big.1, big.2], [272, 160])
        XCTAssertEqual(RenderStyle.smoothed([UInt8](repeating: 0, count: 68 * 40 * 4), w: 68, h: 40).1, 272)   // a custom character: two steps
        XCTAssertTrue(big.0.allSatisfy { $0 == 0 })   // transparent stays transparent
    }

    func testEPXRoundsADiagonal() {
        // X .
        // . X
        let (out, w, _) = RenderStyle.epx(X + O + O + X, w: 2, h: 2)
        XCTAssertEqual(px(out, w, 0, 0), X)
        XCTAssertEqual(px(out, w, 1, 1), O)   // the X's inner corner opens
        XCTAssertEqual(px(out, w, 2, 1), X)   // the gap's corner fills along the diagonal
        XCTAssertEqual(px(out, w, 1, 2), X)
        XCTAssertEqual(px(out, w, 3, 0), O)   // the far corners of the gap stay clear
        XCTAssertEqual(px(out, w, 0, 3), O)
    }

    func testEPXKeepsASolidBlock() {
        let (out, _, _) = RenderStyle.epx(X + X + X + X, w: 2, h: 2)
        XCTAssertEqual(out, Array([[UInt8]](repeating: X, count: 16).joined()))
    }

    // MARK: Pixelate

    func testPixelateHardensAlphaAndPosterizes() {
        let out = RenderStyle.pixelate([200, 100, 0, 255,   60, 60, 60, 100,   64, 32, 0, 128])
        XCTAssertEqual(Array(out[0..<4]), [204, 102, 0, 255])   // six steps: 0, 51, 102, 153, 204, 255
        XCTAssertEqual(Array(out[4..<8]), [0, 0, 0, 0])         // under half alpha: gone
        XCTAssertEqual(Array(out[8..<12]), [102, 51, 0, 255])   // premultiplied 128: un-premultiplied first, then stepped
    }

    // MARK: Style and pairs

    func testSmoothnessPerStyle() {
        XCTAssertTrue(RenderStyle.auto.smooth(true))
        XCTAssertFalse(RenderStyle.auto.smooth(false))
        XCTAssertFalse(RenderStyle.pixel.smooth(true))
        XCTAssertTrue(RenderStyle.illustration.smooth(false))
    }

    func testPackPairsByHDSuffix() {
        let ids: Set = ["pack-a", "pack-a-hd", "pack-b", "pack-c-hd"]
        let has = { ids.contains($0) }
        XCTAssertEqual(RenderStyle.paired("pack-a", .illustration, has: has), "pack-a-hd")
        XCTAssertEqual(RenderStyle.paired("pack-a-hd", .pixel, has: has), "pack-a")
        XCTAssertEqual(RenderStyle.paired("pack-a-hd", .auto, has: has), "pack-a-hd")
        XCTAssertEqual(RenderStyle.paired("pack-b", .illustration, has: has), "pack-b")      // no HD half: EPX instead
        XCTAssertEqual(RenderStyle.paired("pack-c-hd", .pixel, has: has), "pack-c-hd")       // no dot half: pixelated instead
        XCTAssertEqual(RenderStyle.listed("pack-a-hd", has: has), "pack-a")
        XCTAssertEqual(RenderStyle.listed("pack-c-hd", has: has), "pack-c-hd")
    }

    func testSettingIsSaved() {
        let suite = "render-style-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: d).renderStyle, .auto)
        AppSettings(defaults: d).renderStyle = .illustration
        XCTAssertEqual(AppSettings(defaults: d).renderStyle, .illustration)
        d.set("watercolor", forKey: "renderStyle")
        XCTAssertEqual(AppSettings(defaults: d).renderStyle, .auto)
    }

    func testIllustrationCacheIsSmooth() {
        XCTAssertTrue(DogSpriteCache(profile: .defaultDog, style: .illustration).smooth)
        XCTAssertFalse(DogSpriteCache(profile: .defaultDog, style: .pixel).smooth)
    }

    // MARK: 배경 다듬기

    /// 4 x 1: background, background, a gap, subject in the background's colour.
    func testEraseSimilarStopsAtClearGaps() {
        let b = Bitmap(width: 4, height: 1, px: X + X + O + X)
        let out = CutoutEdit.eraseSimilar(b, x: 0, y: 0, tolerance: 0)!
        XCTAssertEqual(out.px, O + O + O + X)
        XCTAssertNil(CutoutEdit.eraseSimilar(b, x: 2, y: 0, tolerance: 50))   // clicked a clear pixel
        XCTAssertNil(CutoutEdit.eraseSimilar(b, x: 9, y: 0, tolerance: 50))   // outside
    }

    func testEraseSimilarHonoursTolerance() {
        let near: [UInt8] = [20, 25, 30, 255], far: [UInt8] = [200, 20, 30, 255]
        let b = Bitmap(width: 3, height: 1, px: X + near + far)
        XCTAssertEqual(CutoutEdit.eraseSimilar(b, x: 0, y: 0, tolerance: 5)!.px, O + near + far)
        XCTAssertEqual(CutoutEdit.eraseSimilar(b, x: 0, y: 0, tolerance: 10)!.px, O + O + far)
    }

    func testBrushClearsADiscAndIgnoresOutside() {
        var b = Bitmap(width: 5, height: 5, px: Array([[UInt8]](repeating: X, count: 25).joined()))
        CutoutEdit.brush(&b, x: 2, y: 2, radius: 1)
        XCTAssertEqual(b.alpha(2, 2), 0)
        XCTAssertEqual(b.alpha(1, 2), 0)
        XCTAssertEqual(b.alpha(1, 1), 255)   // the corner lies outside the disc
        CutoutEdit.brush(&b, x: -40, y: 90, radius: 3)   // far off: nothing, no crash
        XCTAssertTrue(CutoutEdit.hasSubject(b))
        XCTAssertFalse(CutoutEdit.hasSubject(Bitmap(width: 2, height: 2)))
    }

    func testUndoKeepsTheLastTen() {
        var undo = UndoStack<Int>(limit: 10)
        for i in 1...12 { undo.push(i) }
        XCTAssertEqual(undo.items, Array(3...12))
        XCTAssertEqual(undo.pop(), 12)
        XCTAssertFalse(undo.isEmpty)
    }
}
