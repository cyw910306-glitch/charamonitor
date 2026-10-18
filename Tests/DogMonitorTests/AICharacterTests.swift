import AppKit
import XCTest
@testable import DogMonitor

/// The white-background cutout and pixel-grid recovery AI drawings rely on.
final class AICharacterTests: XCTestCase {
    /// A big see-through-cornered photo, so flattening and downscaling show.
    private func photo(width: Int = 1000, height: Int = 800) -> CGImage {
        let ctx = DogRenderer.context(width: width, height: height)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 100, width: width - 200, height: height - 200))
        return ctx.makeImage()!
    }

    /// AI-like art: plain white, a dark 1 px outline around a body whose middle is white too (a white belly).
    private func art() -> CGImage {
        let ctx = DogRenderer.context(width: 300, height: 300)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.12, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 50, width: 100, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.7, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 104, y: 54, width: 92, height: 192))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 130, y: 90, width: 40, height: 60))
        return ctx.makeImage()!
    }

    func testWhiteBackgroundArtIsCutOutByFloodFill() throws {
        let cut = try XCTUnwrap(CustomSprite.checkedCutout(art(), useVision: false))
        XCTAssertFalse(cut.unclear)
        XCTAssertEqual(cut.image.width, 100)
        XCTAssertEqual(cut.image.height, 200)
        let b = Bitmap(cut.image)
        XCTAssertEqual(b.alpha(50, 70), 255, "white belly inside the outline is kept")
        XCTAssertEqual(b.alpha(0, 0), 255, "outline kept")
        XCTAssertGreaterThan(Int(b.px[(70 * b.width + 50) * 4]), 240)
    }

    // MARK: Pixel art from the AI

    /// The tan cat's walk frame cropped to its solid pixels (the see-through ones an AI never draws are dropped),
    /// 1 px per art pixel.
    private func handArt() throws -> Bitmap {
        let frame = try XCTUnwrap(OriginalCharacterSet2.named("original-tan-cat")).poseRGBA[DogPose.walk.rawValue][0]
        var full = Bitmap(DogRenderer.cgImage(frame))
        for i in stride(from: 3, to: full.px.count, by: 4) where full.px[i] < 255 { full.px[i] = 0 }
        let box = try XCTUnwrap(CustomSprite.opaqueBounds(full))
        let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
        var out = Bitmap(width: bw, height: bh)
        for y in 0..<bh { for x in 0..<bw { for k in 0..<4 {
            out.px[(y * bw + x) * 4 + k] = full.px[((y + box.minY) * full.width + x + box.minX) * 4 + k]
        } } }
        return out
    }

    /// `art` drawn like Gemini would: `cell` image px per art pixel (fractional cells round per pixel), on flat magenta.
    private func upscaled(_ art: Bitmap, cell: Double, size: Int = 1024) -> CGImage {
        let ctx = DogRenderer.context(width: size, height: size)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let ox = (Double(size) - Double(art.width) * cell) / 2 + 3, oy = (Double(size) - Double(art.height) * cell) / 2
        for y in 0..<art.height { for x in 0..<art.width where art.px[(y * art.width + x) * 4 + 3] == 255 {
            let i = (y * art.width + x) * 4
            ctx.setFillColor(CGColor(srgbRed: Double(art.px[i]) / 255, green: Double(art.px[i + 1]) / 255, blue: Double(art.px[i + 2]) / 255, alpha: 1))
            let x0 = (ox + Double(x) * cell).rounded(), x1 = (ox + Double(x + 1) * cell).rounded()
            let y0 = (oy + Double(y) * cell).rounded(), y1 = (oy + Double(y + 1) * cell).rounded()
            ctx.fill(CGRect(x: x0, y: Double(size) - y1, width: x1 - x0, height: y1 - y0))   // CG is bottom-up
        } }
        return ctx.makeImage()!
    }

    private func assertSame(_ a: Bitmap, _ b: Bitmap, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.width, b.width, file: file, line: line)
        XCTAssertEqual(a.height, b.height, file: file, line: line)
        guard a.width == b.width, a.height == b.height else { return }
        var off = 0
        for i in stride(from: 0, to: a.px.count, by: 4) {
            let oa = a.px[i + 3] >= 128, ob = b.px[i + 3] >= 128
            if oa != ob || oa && (0..<3).contains(where: { abs(Int(a.px[i + $0]) - Int(b.px[i + $0])) > 2 }) { off += 1 }
        }
        XCTAssertEqual(off, 0, "pixels that differ", file: file, line: line)
    }

    /// An 8x-and-up drawing of the hand-drawn cat comes back exactly: every one-pixel line (ears, whiskers, legs) kept.
    func testAIPixelArtComesBackOnItsOwnGrid() throws {
        let art = try handArt()
        for cell in [40.0, 31.4, 8.0] {
            let cut = try XCTUnwrap(CustomSprite.checkedCutout(upscaled(art, cell: cell), useVision: false, aiArt: true), "cell \(cell)")
            XCTAssertFalse(cut.unclear)
            XCTAssertTrue(CustomSprite.isPixelArt(cut.image), "cell \(cell)")
            assertSame(Bitmap(cut.image), art)
        }
    }

    /// Placed as 2x2 blocks on the even grid, bottom row on the canvas's last row, with no second outline and no head
    /// growing, so the 1x bar shows the cat's own pixels.
    func testPixelArtIsPlacedLosslesslyAtBothDensities() throws {
        let art = try handArt()
        let base = CustomSprite.base(art.cgImage, chibi: true)
        XCTAssertTrue(base.outlined)
        let box = try XCTUnwrap(CustomSprite.opaqueBounds(base))
        XCTAssertEqual(box.maxX - box.minX + 1, art.width * 2)
        XCTAssertEqual(box.maxY - box.minY + 1, art.height * 2)
        XCTAssertEqual(box.maxY, CustomSprite.h - 1)
        XCTAssertEqual(box.minX % 2, 0)
        var half = Bitmap(width: art.width, height: art.height)
        let one = Bitmap(DogRenderer.cgImage(CustomSprite.halved(base.cgReady)))
        for y in 0..<art.height { for x in 0..<art.width { for k in 0..<4 {
            half.px[(y * art.width + x) * 4 + k] = one.px[((y + box.minY / 2) * one.width + x + box.minX / 2) * 4 + k]
        } } }
        assertSame(half, art)
    }

    /// A white chest, even where the outline has a gap, stays: the key is the magenta background, never white.
    func testMagentaKeyKeepsAWhiteChest() throws {
        var art = Bitmap(width: 14, height: 12)
        for y in 0..<12 { for x in 0..<14 {
            let edge = x == 0 || y == 0 || x == 13 || y == 11
            let white = (3...8).contains(x) && y >= 5
            let c: [UInt8] = edge && !(white && y == 11) ? [60, 40, 30, 255] : white ? [255, 255, 255, 255] : [230, 190, 140, 255]
            for k in 0..<4 { art.px[(y * 14 + x) * 4 + k] = c[k] }
        } }
        let cut = try XCTUnwrap(CustomSprite.checkedCutout(upscaled(art, cell: 32, size: 600), useVision: false, aiArt: true))
        let back = Bitmap(cut.image)
        XCTAssertEqual(back.width, 14)
        XCTAssertEqual(back.alpha(5, 8), 255, "white chest kept")
        XCTAssertGreaterThan(Int(back.px[(8 * 14 + 5) * 4]), 240)
    }

    /// Not pixel art (a smooth shaded ball): no grid, so the photo path's 256 px cut-out.
    func testNoGridFallsBackToTheUsualCutout() throws {
        let ctx = DogRenderer.context(width: 600, height: 600)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        ctx.addEllipse(in: CGRect(x: 90, y: 120, width: 400, height: 330))
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.95, green: 0.85, blue: 0.7, alpha: 1), CGColor(srgbRed: 0.45, green: 0.3, blue: 0.2, alpha: 1)] as CFArray
        ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!,
                               startCenter: CGPoint(x: 250, y: 330), startRadius: 0, endCenter: CGPoint(x: 290, y: 285), endRadius: 230, options: [])
        let cut = try XCTUnwrap(CustomSprite.checkedCutout(ctx.makeImage()!, useVision: false, aiArt: true))
        XCTAssertFalse(CustomSprite.isPixelArt(cut.image))
        XCTAssertEqual(cut.image.width, 256)
    }

    /// The AI gets the subject and 12% around it, clipped to the photo.
    func testPhotoIsCroppedAroundTheSubject() {
        let p = photo(width: 1000, height: 800)
        let cropped = CustomSprite.crop(p, around: CGRect(x: 400, y: 300, width: 200, height: 100))
        XCTAssertEqual(cropped.width, 248)
        XCTAssertEqual(cropped.height, 124)
        XCTAssertEqual(CustomSprite.crop(p, around: CGRect(x: 0, y: 0, width: 1000, height: 800)).width, 1000)
    }

    /// A saved AI drawing is reopened at its own size, so it takes the pixel-art path again (no flag in the file).
    func testSavedPixelArtReloadsAsPixelArt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let art = try handArt()
        let store = CustomCharacterStore(root: root)
        let saved = try store.save(name: "AI", lightRim: false, inputs: [.rest: art.cgImage])
        let back = try XCTUnwrap(store.inputs(saved.id)[.rest])
        XCTAssertTrue(CustomSprite.isPixelArt(back))
        assertSame(Bitmap(back), art)
    }
}
