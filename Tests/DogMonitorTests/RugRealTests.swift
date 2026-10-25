import AppKit
import SceneKit
import XCTest
import simd
@testable import DogMonitor

/// 러그 질감 리얼 (RugTuft), the split mesh, the textures' cache key and 내 이미지 (RugPhoto).
final class RugRealTests: XCTestCase {
    private let walls = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testNoiseIsDeterministicAndInRange() {
        XCTAssertEqual(RugTuft.hash(3, 9), RugTuft.hash(3, 9))
        XCTAssertNotEqual(RugTuft.hash(3, 9), RugTuft.hash(3, 9, 1))
        XCTAssertNotEqual(RugTuft.hash(3, 9), RugTuft.hash(9, 3))
        var lo: Float = 1, hi: Float = 0
        for i in 0..<400 {
            let v = RugTuft.value(Float(i) * 0.37, Float(i % 23) * 1.3)
            lo = min(lo, v); hi = max(hi, v)
        }
        XCTAssertGreaterThanOrEqual(lo, 0); XCTAssertLessThanOrEqual(hi, 1); XCTAssertGreaterThan(hi - lo, 0.5)
        XCTAssertEqual(RugTuft.value(2, 5), RugTuft.hash(2, 5), accuracy: 1e-6)   // on the grid it is the hash itself
    }

    func testShadeLightsTheSideFacingTheLight() {
        XCTAssertEqual(RugTuft.shade(SIMD3(0, 0, 1)), 1, accuracy: 1e-6)
        let toward = RugTuft.shade(simd_normalize(SIMD3<Float>(-0.4, 0.4, 1))), away = RugTuft.shade(simd_normalize(SIMD3<Float>(0.4, -0.4, 1)))
        XCTAssertGreaterThan(toward, 1)
        XCTAssertLessThan(away, 1)
        XCTAssertLessThan(RugTuft.shade(SIMD3(0, 0, -1)), away)
        XCTAssertGreaterThan(RugTuft.shade(SIMD3(0, 0, -1)), 0.3)   // never black: the ambient
    }

    func testDistanceGrowsInward() {
        var on = [Bool](repeating: false, count: 20 * 20)
        for y in 2...17 { for x in 2...17 { on[y * 20 + x] = true } }
        let d = RugTuft.distance(on, 20, 20)
        XCTAssertEqual(d[0], 0)
        XCTAssertEqual(d[2 * 20 + 10], 1)
        XCTAssertEqual(d[10 * 20 + 10], 8, accuracy: 0.01)
        XCTAssertLessThan(d[2 * 20 + 2], d[3 * 20 + 3])
    }

    /// A block cut out round a drawn block: the yarn outline hugging the drawing, cream fur out to the cut, the
    /// picture in the middle, hairs past the cut, a pale back, soft shadows, the same pixels every time.
    func testRealFacesLayersAndIsDeterministic() throws {
        var block = [Bool](repeating: false, count: 64 * 44)
        for y in 10...33 { for x in 14...49 { block[y * 64 + x] = true } }
        let mask = RugMask(silhouette: block, cols: 64, rows: 44, grow: RugArt.realGrow, thin: 2)
        let w = 512, h = 352
        let pic = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pic.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); pic.fill(CGRect(x: 112, y: 80, width: 288, height: 192))
        let picture = try XCTUnwrap(pic.makeImage())
        let a = try XCTUnwrap(RugTuft.faces(picture, mask: mask, rim: true, soft: 0))
        let b = try XCTUnwrap(RugTuft.faces(picture, mask: mask, rim: true, soft: 0))
        let pa = try XCTUnwrap(RugTuft.rgba(a.front)), pb = try XCTUnwrap(RugTuft.rgba(b.front))
        XCTAssertEqual(pa, pb, "the same rug every time")
        let (inside, depth) = RugTuft.cut(mask, w, h)
        func px(_ i: Int) -> SIMD3<Float> { SIMD3(Float(pa[i * 4]), Float(pa[i * 4 + 1]), Float(pa[i * 4 + 2])) / 255 }
        func mean(_ v: [SIMD3<Float>]) -> SIMD3<Float> { v.reduce(.zero, +) / Float(max(1, v.count)) }
        // Along the middle row, from the cut's left edge inward: fur, then the yarn right against the drawing, then blue.
        let row = 176
        let edge = try XCTUnwrap((0..<w).first { inside[row * w + $0] && depth[row * w + $0] > 3 })
        let fur = (edge...(edge + 6)).map { px(row * w + $0) }
        let yarn = (100...108).map { px(row * w + $0) }, art = (140...380).map { px(row * w + $0) }
        XCTAssertGreaterThan(mean(fur).x, 0.75, "cream fur")
        XCTAssertLessThan(simd_reduce_max(mean(yarn)), 0.4, "dark yarn right at the drawing's edge")
        XCTAssertGreaterThan(mean(art).z, mean(art).x + 0.4, "the picture's blue")
        XCTAssertGreaterThan(Float(112 - edge), RugTuft.line + 4, "the fur shows outside the line")
        // Not a flat fill: the pile varies, softly.
        let lums = art.map { $0.x + $0.y + $0.z }, avg = lums.reduce(0, +) / Float(lums.count)
        let sd = (lums.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Float(lums.count)).squareRoot()
        XCTAssertGreaterThan(sd, 0.02); XCTAssertLessThan(sd, 0.25)
        // The fur strays past the 0.5 contour in places, and pulls back in others.
        var out = 0, back = 0
        for y in 0..<h { for x in 0..<w {
            let v = mask.value(u: (Double(x) + 0.5) / Double(w), v: 1 - (Double(y) + 0.5) / Double(h))
            if inside[y * w + x], v < 0.5 { out += 1 }
            if !inside[y * w + x], v >= 0.5 { back += 1 }
        } }
        XCTAssertGreaterThan(out, 50); XCTAssertGreaterThan(back, 50)
        XCTAssertEqual(pa[3], 0, "the corner is see-through")
        // The back: pale, with the blue showing faintly through.
        let under = try XCTUnwrap(RugTuft.rgba(a.back))
        XCTAssertEqual(under[3], 0)
        let mid = (176 * w + 256) * 4
        XCTAssertGreaterThan(under[mid], 150, "a pale lining")
        XCTAssertGreaterThan(Int(under[mid + 2]), Int(under[mid]), "the design faint through it")
        // The shadows: padded, opaque under the middle, fading past the edge, the wide one reaching further.
        XCTAssertEqual(a.contact.width, w + 2 * RugTuft.pad); XCTAssertEqual(a.wide.height, h + 2 * RugTuft.pad)
        let c = try XCTUnwrap(RugTuft.rgba(a.contact)), wd = try XCTUnwrap(RugTuft.rgba(a.wide)), pw = a.contact.width, p = RugTuft.pad
        XCTAssertGreaterThan(c[((176 + p) * pw + 256 + p) * 4 + 3], 240)
        XCTAssertEqual(c[3], 0); XCTAssertEqual(wd[3], 0)
        let past = ((176 + p) * pw + p + edge - 10) * 4 + 3
        XCTAssertGreaterThan(wd[past], c[past], "the wide shadow spreads further")
    }

    func testRealFacesForEveryKindAndTheRectangle() throws {
        let art = try XCTUnwrap(RugArt.art(DogSpriteCache(profile: .defaultDog, pixelSize: 8, style: .illustration)))
        let mask = try XCTUnwrap(RugArt.mask(art, grow: RugArt.realGrow))
        let shaped = RugArt.real(.character, color: .mint, character: art, mask: mask)
        XCTAssertEqual(shaped.front.size, RugArt.size)
        XCTAssertNotNil(shaped.contact); XCTAssertNotNil(shaped.wide)
        let cg = try XCTUnwrap(shaped.front.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, Int(RugArt.size.width) * 2, "drawn for Retina")
        XCTAssertEqual(try XCTUnwrap(RugTuft.rgba(cg))[3], 0)
        // The rectangle: opaque, with a bound edge (cream fur outside, dark yarn inside it).
        let rect = try XCTUnwrap(RugArt.real(.stripes, color: .sky, character: nil, mask: nil).front.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let px = try XCTUnwrap(RugTuft.rgba(rect)), mid = rect.height / 2
        XCTAssertEqual(px[(mid * rect.width + rect.width / 2) * 4 + 3], 255)
        func lum(_ x: Int) -> Int { let i = (mid * rect.width + x) * 4; return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        XCTAssertGreaterThan(lum(8), 600, "fur at the edge")
        XCTAssertLessThan(lum(22), 250, "the yarn line inside it")
    }

    /// 기본 (every rug from before 리얼): the faces are exactly the old ones, no shadows, no discard on the rectangle,
    /// the back still glowing its own colour, and the old light.
    func testPlainIsAsBefore() throws {
        let art = RugArt.art(DogSpriteCache(profile: .defaultDog, style: .pixel))
        let plain = RugArt.plain(.character, color: .strawberry, character: art, mask: nil)
        XCTAssertNil(plain.contact)
        let old = try XCTUnwrap(RugArt.front(.character, color: .strawberry, character: art).cgImage(forProposedRect: nil, context: nil, hints: nil))
        let now = try XCTUnwrap(plain.front.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(RugTuft.rgba(old), RugTuft.rgba(now))
        let m = (0..<4).map { _ in SCNMaterial() }
        let node = SCNNode(), shadow = SCNNode()
        let (scene, _) = DesktopRug.scene(size: CGSize(width: 400, height: 300), node: node, shadow: shadow, materials: m)
        DesktopRug.dress(m, plain, real: false, cut: false)
        XCTAssertNil(m[0].shaderModifiers); XCTAssertNil(m[1].shaderModifiers)
        XCTAssertTrue(m[1].emission.contents as AnyObject === plain.back)
        XCTAssertEqual(scene.rootNode.childNode(withName: "fill", recursively: false)?.light?.intensity, 450)
        DesktopRug.dress(m, plain, real: false, cut: true)
        XCTAssertNotNil(m[0].shaderModifiers?[.fragment], "a cut-out discards its see-through part")
        DesktopRug.light(scene, real: true)
        XCTAssertLessThan(try XCTUnwrap(scene.rootNode.childNode(withName: "fill", recursively: false)?.light?.intensity), 300)
    }

    func testPileLightIsSoftWithBrightTips() {
        XCTAssertLessThan(RugTuft.pileLight(0, id: 0.5), RugTuft.pileLight(0.5, id: 0.5))
        XCTAssertGreaterThan(RugTuft.pileLight(1, id: 0.5) - RugTuft.pileLight(0.9, id: 0.5), 0.02, "a bright tip")
        XCTAssertLessThan(RugTuft.pileLight(1, id: 1) - RugTuft.pileLight(0, id: 0), 0.35, "velvety, not embossed")
        var tips = 0
        for y in 0..<70 { for x in 0..<70 where RugTuft.tuftAt(Float(x), Float(y)).height > 0.9 { tips += 1 } }
        XCTAssertGreaterThan(tips, 20); XCTAssertLessThan(tips, 70 * 70 / 4)
        XCTAssertEqual(RugTuft.tuftAt(13.5, 7.25).id, RugTuft.tuftAt(13.5, 7.25).id)
    }

    // MARK: Settings and cache

    func testFinishFollowsTheShapeUntilPicked() throws {
        var p = RugPrefs()
        XCTAssertEqual(p.look, .plain)
        p.shape = .character
        XCTAssertEqual(p.look, .real)
        p.look = .plain
        XCTAssertEqual(p.look, .plain)
        let old = #"{"on":true,"shape":"character"}"#.data(using: .utf8)!
        let got = try JSONDecoder().decode(RugPrefs.self, from: old)
        XCTAssertNil(got.finish); XCTAssertEqual(got.look, .real)
        let round = try JSONDecoder().decode(RugPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round.finish, .plain)
        XCTAssertEqual(try JSONDecoder().decode(RugPrefs.self, from: #"{"face":"photo"}"#.data(using: .utf8)!).face, .photo)
    }

    /// The textures are redrawn for what they show, not for where the rug lies or how big or stiff it is.
    func testPaintKeyChangesOnlyWithThePicture() {
        let p = RugPrefs(), stamp = Date(timeIntervalSince1970: 1)
        let key = RugPaint(p, look: nil, photo: stamp)
        var q = p
        q.size = .huge; q.softness = .floppy; q.home = CGPoint(x: 0.9, y: 0.9); q.on = true
        XCTAssertEqual(RugPaint(q, look: nil, photo: stamp), key)
        XCTAssertEqual(RugPaint(p, look: nil, photo: Date()), key, "the photo counts only while it is the 그림")
        for change in [{ (r: inout RugPrefs) in r.face = .dots }, { $0.color = .sky }, { $0.shape = .character }, { $0.finish = .real }] {
            var r = p
            change(&r)
            XCTAssertNotEqual(RugPaint(r, look: nil, photo: stamp), key)
        }
        var photo = p
        photo.face = .photo
        XCTAssertNotEqual(RugPaint(photo, look: nil, photo: stamp), RugPaint(photo, look: nil, photo: Date()), "a new picture reprints")
    }

    /// 내 이미지 is a choice only once a picture is saved, or while it is the 그림 (from another Mac, say).
    func testPhotoIsOfferedOnlyWithAPicture() {
        XCTAssertFalse(RugFace.offered(current: .character, hasPhoto: false).contains(.photo))
        XCTAssertTrue(RugFace.offered(current: .character, hasPhoto: true).contains(.photo))
        XCTAssertTrue(RugFace.offered(current: .photo, hasPhoto: false).contains(.photo))
    }

    /// Picking a new picture while 내 이미지 is already the 그림 changes the textures' key, so it reprints.
    func testANewPictureReprints() throws {
        let saved = RugPhoto.url
        defer { RugPhoto.url = saved }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rugphoto-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        RugPhoto.url = dir.appendingPathComponent("RugPhoto.png")
        XCTAssertNil(RugPhoto.stamp)
        let src = dir.appendingPathComponent("in.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png(64, 64, clear: true).write(to: src)
        XCTAssertNil(RugPhoto.save(from: src))
        var p = RugPrefs()
        p.face = .photo
        let first = RugPaint(p, look: nil, photo: RugPhoto.stamp)
        XCTAssertNotNil(first.photo)
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertNil(RugPhoto.save(from: src))
        XCTAssertNotEqual(RugPaint(p, look: nil, photo: RugPhoto.stamp), first)
        XCTAssertNotNil(RugPhoto.load())
        XCTAssertEqual(RugPhoto.save(from: dir.appendingPathComponent("missing.png")), .unreadable)
    }

    // MARK: Mesh

    func testSplitMeshRunsThroughTheClothsPoints() {
        var c = ClothSheet(origin: CGPoint(x: 100, y: 100), walls: walls)
        _ = c.grab(at: CGPoint(x: 100, y: 100 + c.size.height / 2))
        for k in 1...40 { c.drag(to: CGPoint(x: 100 + Double(k) * 4, y: 100 + c.size.height / 2)); c.step(dt: 1.0 / 60) }
        let (pts, cols, rows) = DesktopRug.dense(c)
        let s = DesktopRug.split
        XCTAssertEqual(cols, (c.cols - 1) * s + 1); XCTAssertEqual(rows, (c.rows - 1) * s + 1)
        for y in 0..<c.rows { for x in 0..<c.cols {
            XCTAssertLessThan(simd_length(pts[y * s * cols + x * s] - c.points[c.index(x, y)]), 1e-9)
        } }
        let (uv, elements) = DesktopRug.mesh(c)
        XCTAssertEqual(uv.vectorCount, pts.count)
        XCTAssertEqual(elements[0].primitiveCount, (cols - 1) * (rows - 1) * 2)
    }

    // MARK: 내 이미지

    private func png(_ w: Int, _ h: Int, clear: Bool) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        if !clear { ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage())).representation(using: .png, properties: [:]))
    }

    func testPhotoChecksAndShape() throws {
        XCTAssertEqual(RugPhoto.prepare(Data(count: RugPhoto.maxBytes + 1)).failure, .tooBig)
        XCTAssertEqual(RugPhoto.prepare(Data("not a picture".utf8)).failure, .notImage)
        XCTAssertEqual(RugPhoto.prepare(try png(8, 8, clear: false), useVision: false).failure, .tooSmall)
        // A cut-out PNG keeps its own shape: cropped to the circle, its corners still see-through.
        let cut = try XCTUnwrap(RugPhoto.prepare(try png(400, 400, clear: true), useVision: false).success)
        XCTAssertEqual(cut.width, 200, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(RugTuft.rgba(cut))[3], 0)
        // A big picture comes down to 1024 on its long side.
        let big = try XCTUnwrap(RugPhoto.prepare(try png(3000, 1500, clear: true), useVision: false).success)
        XCTAssertLessThanOrEqual(max(big.width, big.height), RugPhoto.maxPixel)
        // As a rug: the mat follows the picture's alpha.
        let art = (image: NSImage(cgImage: cut, size: CGSize(width: cut.width, height: cut.height)), smooth: true)
        let m = try XCTUnwrap(RugArt.mask(art, grow: RugArt.realGrow))
        XCTAssertTrue(m.covers(u: 0.5, v: 0.5)); XCTAssertFalse(m.covers(u: 0.02, v: 0.02)); XCTAssertFalse(m.covers(u: 0.25, v: 0.12))
    }

    /// A small file (about 50 KB) that unpacks to a 20000 by 20000 picture is refused from its header, before
    /// anything is decoded.
    func testDecompressionBombIsRefused() throws {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tb = Array(type.utf8) + body
            var crc: UInt32 = 0xFFFF_FFFF
            for b in tb { crc ^= UInt32(b); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 } }
            return be(UInt32(body.count)) + tb + be(crc ^ 0xFFFF_FFFF)
        }
        // A 1-bit grey picture, every row a zero filter byte and zero pixels: zlib's header, deflate, Adler-32.
        let side = 20000, raw = (side / 8 + 1) * side
        let deflated = try (Data(count: raw) as NSData).compressed(using: .zlib) as Data
        let idat = [0x78, 0x9C] + [UInt8](deflated) + be(UInt32(raw % 65521) << 16 | 1)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", be(UInt32(side)) + be(UInt32(side)) + [1, 0, 0, 0, 0])
            + chunk("IDAT", idat) + chunk("IEND", [])
        XCTAssertLessThan(png.count, RugPhoto.maxBytes / 100)
        XCTAssertEqual(RugPhoto.prepare(Data(png), useVision: false).failure, .tooLarge)
    }

    /// The formats at the edge: HEIC (what an iPhone photo is) works; SVG and plain text are not pictures here.
    func testFormatsAtTheEdge() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><circle cx="32" cy="32" r="30"/></svg>"#
        XCTAssertEqual(RugPhoto.prepare(Data(svg.utf8), useVision: false).failure, .notImage)
        XCTAssertEqual(RugPhoto.prepare(Data(), useVision: false).failure, .notImage)
        let data = NSMutableData()
        let image = try XCTUnwrap(NSBitmapImageRep(data: try png(128, 96, clear: false))?.cgImage)
        if let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                let got = try XCTUnwrap(RugPhoto.prepare(data as Data, useVision: false).success)
                XCTAssertGreaterThanOrEqual(got.width, 64)   // its plain ground may be cut away
            }
        }
    }

    /// RUG_PERF=1: what 리얼 costs, printed. Building the textures (once per picture) and one frame's mesh while dragging.
    func testCost() throws {
        guard ProcessInfo.processInfo.environment["RUG_PERF"] == "1" else { throw XCTSkip("set RUG_PERF=1 to time") }
        let art = try XCTUnwrap(RugArt.art(DogSpriteCache(profile: .defaultDog, pixelSize: 8, style: .illustration)))
        var t = Date()
        let mask = try XCTUnwrap(RugArt.mask(art, grow: RugArt.realGrow))
        _ = RugArt.real(.character, color: .mint, character: art, mask: mask)
        print("RUGPERF texture \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        let texture = Date().timeIntervalSince(t)
        var c = ClothSheet(spacing: 25, walls: walls)
        let (uv, el) = DesktopRug.mesh(c), sm = DesktopRug.shadowMesh(c), m = (0..<4).map { _ in SCNMaterial() }
        _ = c.grab(at: .zero)
        t = Date()
        var hot = 0.0
        for k in 0..<600 {
            c.drag(to: CGPoint(x: Double(k % 200), y: 40)); c.step(dt: 1.0 / 60)
            let d = DesktopRug.dense(c)
            _ = DesktopRug.geometry(d, texcoords: uv, elements: el, materials: [m[0], m[1]], rest: c.size, shadow: (sm, m[2], m[3]))
            if k % 8 == 0 { let h = Date(); _ = RugMask.outline(mask, d, split: 2); hot += Date().timeIntervalSince(h) }
        }
        let frame = Date().timeIntervalSince(t) / 600
        print("RUGPERF frame \(String(format: "%.2f", frame * 1000)) ms (physics + mesh + shadows, hotspot every 8th: \(String(format: "%.2f", hot / 75 * 1000)) ms each)")
        // Budgets wide enough for a debug build, tight enough to catch a regression by an order of magnitude.
        XCTAssertLessThan(texture, 15, "texture build")
        XCTAssertLessThan(frame, 1.0 / 60, "a frame while dragging")
    }

    // MARK: QA renders

    /// RUG_QA_DIR=<dir>: the 리얼 rug on a wooden floor, flat, folded and crumpled, for three characters, a photo and the
    /// rectangle, in one sheet (rug-sheet.png).
    func testRenderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["RUG_QA_DIR"] else { throw XCTSkip("set RUG_QA_DIR to render") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let canvas = CGSize(width: 560, height: 400)
        var rows: [(String, [CGImage])] = []
        func kinds() throws -> [(String, (image: NSImage, smooth: Bool)?, RugFace, RugShape, FocusTheme)] {
            var k: [(String, (image: NSImage, smooth: Bool)?, RugFace, RugShape, FocusTheme)] = [
                ("jelly", RugArt.art(DogSpriteCache(profile: .defaultDog, pixelSize: 8, style: .illustration)), .character, .character, .strawberry),
                ("cat", RugArt.art(DogSpriteCache(try XCTUnwrap(CatCatalog.all.first), pixelSize: 8, style: .illustration)), .character, .character, .sky),
                ("original", RugArt.art(DogSpriteCache(try XCTUnwrap(OriginalCatalog.all.first), pixelSize: 8, style: .illustration)), .character, .character, .mint),
            ]
            let photo = ProcessInfo.processInfo.environment["RUG_QA_PHOTO"] ?? "my-dog/jelly-avatar.jpg"
            if let data = FileManager.default.contents(atPath: photo), let cg = RugPhoto.prepare(data).success {
                k.append(("photo", (NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)), true), .photo, .character, .lemon))
            }
            k.append(("rect", RugArt.art(DogSpriteCache(profile: .defaultDog, pixelSize: 8, style: .illustration)), .character, .rect, .peach))
            return k
        }
        for (name, art, face, shape, color) in try kinds() {
            let mask = shape == .character ? art.flatMap { RugArt.mask($0, grow: RugArt.realGrow) } : nil
            let faces = RugArt.real(face, color: color, character: art, mask: mask)
            var shots: [CGImage] = []
            for pose in 0..<3 {
                var c = ClothSheet(spacing: 25, bend: RugSoftness.normal.bend, walls: CGRect(origin: .zero, size: canvas))
                c.place(ClothSheet.flatten(from: c.rest, rest: c.rest, to: CGPoint(x: 92, y: 75), progress: 1))
                if pose == 1 { Self.fold(&c) }
                if pose == 2 { Self.crumple(&c) }
                shots.append(try Self.render(c, faces: faces, cut: mask != nil, canvas: canvas))
            }
            rows.append((name, shots))
        }
        let sheet = try Self.sheet(rows, canvas: canvas)
        try Self.write(sheet, out.appendingPathComponent("rug-sheet.png"))
        // Side by side with the reference: the reference on the left, our folded rug on the right.
        if let refPath = ProcessInfo.processInfo.environment["RUG_QA_REF"], let ref = NSImage(contentsOfFile: refPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let ours = rows.first?.1 {
            let h = 900, rw = ref.width * h / ref.height
            let ctx = try XCTUnwrap(CGContext(data: nil, width: rw + 2 * 1120 + 40, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: h))
            ctx.draw(ref, in: CGRect(x: 0, y: 0, width: rw, height: h))
            ctx.draw(ours[1], in: CGRect(x: rw + 20, y: h - 800, width: 1120, height: 800))
            ctx.draw(ours[2], in: CGRect(x: rw + 1140, y: h - 800, width: 1120, height: 800))
            try Self.write(try XCTUnwrap(ctx.makeImage()), out.appendingPathComponent("rug-vs-reference.png"))
        }
        // The texture alone at full size, for looking at the pile.
        if let (_, art, face, _, color) = try kinds().first, let mask = art.flatMap({ RugArt.mask($0, grow: RugArt.realGrow) }),
           let cg = RugArt.real(face, color: color, character: art, mask: mask).front.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try Self.write(cg, out.appendingPathComponent("rug-texture-jelly.png"))
        }
    }

    // MARK: Pack characters

    /// A pack in `root`: every frame a box of `fill`, slowWalk's of `stand` (so the frame picked shows).
    private func writePack(_ root: URL, _ id: String, size: (Int, Int), hd: Bool, fill: CGColor, stand: CGColor) throws {
        let frames = root.appendingPathComponent("\(id)/frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let counts = ["lying": 1, "slowWalk": 2, "walk": 4, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2]
        var json: [String: Any] = ["version": 1, "id": id, "name": "합성", "frames": counts]
        if hd { json["density"] = 8; json["smooth"] = true }
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("\(id)/pack.json"))
        for (key, n) in counts {
            let ctx = try XCTUnwrap(DogRenderer.context(width: size.0, height: size.1))
            ctx.setFillColor(key == "slowWalk" ? stand : fill)
            ctx.fill(CGRect(x: size.0 / 4, y: 0, width: size.0 / 2, height: size.1 * 3 / 4))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage())).representation(using: .png, properties: [:]))
            for i in 0..<n { try png.write(to: frames.appendingPathComponent("\(key)-\(i).png")) }
        }
    }

    /// 러그 캐릭터 on a pack: 리얼 takes the HD half's slowWalk frame at its full 272 x 160 (smooth, like a photo), not
    /// the bar's 34 x 20 copy; 기본 keeps the cached bar frame; the menu lists the pair once; a vanished pick follows the bar.
    func testPackCharactersUseTheirFullSizeArt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rugpacks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1), blue = CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        try writePack(root, "pack-rugtest", size: (68, 40), hd: false, fill: red, stand: red)
        try writePack(root, "pack-rugtest-hd", size: (272, 160), hd: true, fill: red, stand: blue)
        let saved = OriginalCatalog.all
        defer { OriginalCatalog.all = saved }
        OriginalCatalog.all += CharacterPack.loadAll(root: root)

        let choices = RugArt.characterChoices()
        XCTAssertNil(choices.first?.id)
        XCTAssertEqual(choices.filter { $0.id?.hasPrefix("pack-rugtest") == true }.map(\.id), ["pack-rugtest"])

        var prefs = RugPrefs()
        prefs.shape = .character; prefs.character = "pack-rugtest"
        let look = RugArt.look(AppSettings.shared, pick: prefs.character)
        let art = try XCTUnwrap(DesktopRug.art(RugPaint(prefs, look: look, photo: nil)))
        XCTAssertTrue(art.smooth)
        let cg = try XCTUnwrap(art.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual([cg.width, cg.height], [272, 160])
        let px = try XCTUnwrap(RugTuft.rgba(cg))
        let mid = (100 * 272 + 136) * 4   // memory rows top down: inside the box
        XCTAssertGreaterThan(px[mid + 2], 200, "the slowWalk (blue) frame, not walk's red")
        XCTAssertLessThan(px[mid], 60)

        prefs.look = .plain
        let plain = try XCTUnwrap(DesktopRug.art(RugPaint(prefs, look: look, photo: nil)))
        XCTAssertEqual(plain.image.size, NSSize(width: 34, height: 20))

        XCTAssertEqual(RugArt.look(AppSettings.shared, pick: "pack-gone").readyID, SpriteLook(AppSettings.shared).readyID)
        // Saved before 러그 캐릭터 existed: it follows the bar.
        XCTAssertNil(try JSONDecoder().decode(RugPrefs.self, from: Data(#"{"on":true}"#.utf8)).character)
        XCTAssertEqual(try JSONDecoder().decode(RugPrefs.self, from: try JSONEncoder().encode(prefs)).character, "pack-rugtest")
    }

    /// RUG_QA_PACKS=<dir>: the user's installed packs (read only) as 캐릭터 모양 리얼 rugs, one sheet per pack plus the
    /// first one's texture at full size. Never committed: the art is theirs.
    func testRenderPackSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["RUG_QA_PACKS"] else { throw XCTSkip("set RUG_QA_PACKS to render") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let saved = OriginalCatalog.all
        defer { OriginalCatalog.all = saved }
        OriginalCatalog.all += CharacterPack.loadAll()
        let canvas = CGSize(width: 560, height: 400)
        let picks = (ProcessInfo.processInfo.environment["RUG_QA_PICKS"] ?? "pack-ck-chiikawa,pack-ck-hachiware,pack-ck-usagi,pack-ck-momonga,pack-ck-kurimanju,pack-ck-rakko,pack-shin")
            .split(separator: ",").map(String.init)
        let colors: [FocusTheme] = [.strawberry, .sky, .lemon, .lavender, .peach, .mint, .cocoa]
        for (k, pick) in picks.enumerated() {
            var prefs = RugPrefs()
            prefs.shape = .character; prefs.character = pick; prefs.color = colors[k % colors.count]
            let art = DesktopRug.art(RugPaint(prefs, look: RugArt.look(AppSettings.shared, pick: pick), photo: nil))
            let mask = art.flatMap { RugArt.mask($0, grow: RugArt.realGrow) }
            let faces = RugArt.real(.character, color: prefs.color, character: art, mask: mask)
            var shots: [CGImage] = []
            for pose in 0..<3 {
                var c = ClothSheet(spacing: 25, bend: RugSoftness.normal.bend, walls: CGRect(origin: .zero, size: canvas))
                c.place(ClothSheet.flatten(from: c.rest, rest: c.rest, to: CGPoint(x: 92, y: 75), progress: 1))
                if pose == 1 { Self.fold(&c) }
                if pose == 2 { Self.crumple(&c) }
                shots.append(try Self.render(c, faces: faces, cut: mask != nil, canvas: canvas))
            }
            try Self.write(try Self.sheet([(pick, shots)], canvas: canvas), out.appendingPathComponent("\(pick).png"))
            if k == 0, let cg = faces.front.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                try Self.write(cg, out.appendingPathComponent("\(pick)-texture.png"))
            }
        }
    }

    /// A drape like the reference's: the top right corner picked up and laid diagonally across the rug.
    private static func fold(_ c: inout ClothSheet) {
        let p = c.points[c.index(c.cols - 1, c.rows - 1)]
        _ = c.grab(at: CGPoint(x: p.x, y: p.y))
        for k in 1...90 { c.drag(to: CGPoint(x: p.x - Double(k) * 3.6, y: p.y - Double(k) * 2.2)); c.step(dt: 1.0 / 60) }
        c.release()
        for _ in 0..<120 { c.step(dt: 1.0 / 60) }
    }

    /// Bunched: rubbed about the middle (it slides and buckles into ridges that stay), then a side edge pushed in.
    private static func crumple(_ c: inout ClothSheet) {
        for (x, y, dx, dy) in [(4, c.rows / 2, 3.0, 0.3), (c.cols - 4, c.rows / 2 + 2, -3.0, -0.4), (c.cols / 2, 2, 0.3, 2.6), (0, c.rows - 3, 2.4, -0.6)] {
            let p = c.points[c.index(x, y)]
            _ = c.grab(at: CGPoint(x: p.x, y: p.y))
            for k in 1...36 { c.drag(to: CGPoint(x: p.x + Double(k) * dx, y: p.y + Double(k) * dy)); c.step(dt: 1.0 / 60) }
            c.release()
            for _ in 0..<30 { c.step(dt: 1.0 / 60) }
        }
        for _ in 0..<120 { c.step(dt: 1.0 / 60) }
    }

    /// The rug as DesktopRug draws it (the same scene, materials and mesh), at 2x, over a wooden floor.
    private static func render(_ c: ClothSheet, faces: RugFaces, cut: Bool, canvas: CGSize) throws -> CGImage {
        let node = SCNNode(), shadow = SCNNode(), m = (0..<4).map { _ in SCNMaterial() }
        let (scene, cam) = DesktopRug.scene(size: canvas, node: node, shadow: shadow, materials: m)
        DesktopRug.light(scene, real: true)
        DesktopRug.dress(m, faces, real: true, cut: cut)
        let (uv, elements) = DesktopRug.mesh(c)
        let g = DesktopRug.geometry(DesktopRug.dense(c), texcoords: uv, elements: elements, materials: [m[0], m[1]], rest: c.size,
                                    shadow: (DesktopRug.shadowMesh(c), m[2], m[3]))
        node.geometry = g.cloth; shadow.geometry = g.contact; shadow.childNodes.first?.geometry = g.wide
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = scene; r.pointOfView = cam
        let px = CGSize(width: canvas.width * 2, height: canvas.height * 2)
        let rug = try XCTUnwrap(r.snapshot(atTime: 0, with: px, antialiasingMode: .multisampling4X).cgImage(forProposedRect: nil, context: nil, hints: nil))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        wood(ctx, px)
        ctx.draw(rug, in: CGRect(origin: .zero, size: px))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Light oak planks: rows of boards with staggered joints, each a slightly different tone, grain running along.
    private static func wood(_ ctx: CGContext, _ size: CGSize) {
        let w = Int(size.width), h = Int(size.height), plank = 92
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let row = y / plank, inRow = y % plank
            for x in 0..<w {
                let joint = (x + row * 377) % 640, board = (x + row * 377) / 640
                let tone = 0.92 + 0.12 * RugTuft.hash(Int32(row), Int32(board), 77)
                let grain = RugTuft.value(Float(x) / 90, Float(y) / 3.2 + RugTuft.value(Float(x) / 200, Float(y) / 40, 5) * 4, 9)
                var k = tone * (0.86 + 0.18 * grain) * (0.97 + 0.03 * RugTuft.hash(Int32(x / 2), Int32(y), 3))
                if inRow < 2 || joint < 2 { k *= 0.62 }
                let i = (y * w + x) * 4
                px[i] = UInt8(min(255, 214 * k)); px[i + 1] = UInt8(min(255, 160 * k)); px[i + 2] = UInt8(min(255, 108 * k))
            }
        }
        if let img = RugTuft.image(px, w, h) { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
    }

    private static func sheet(_ rows: [(String, [CGImage])], canvas: CGSize) throws -> CGImage {
        let cw = Int(canvas.width), ch = Int(canvas.height), gap = 16, label = 40
        let w = 3 * cw + 4 * gap, h = rows.count * (ch + label) + gap
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (r, (name, shots)) in rows.enumerated() {
            let top = h - gap - r * (ch + label)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for (k, title) in ["flat", "folded", "crumpled"].enumerated() {
                NSString(string: "\(name) · \(title)").draw(at: CGPoint(x: gap + k * (cw + gap), y: top - 26),
                                                           withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white])
            }
            NSGraphicsContext.restoreGraphicsState()
            for (k, shot) in shots.enumerated() {
                ctx.draw(shot, in: CGRect(x: gap + k * (cw + gap), y: top - label - ch + 4, width: cw, height: ch))
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func write(_ cg: CGImage, _ url: URL) throws {
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)
    }
}

private extension Result {
    var success: Success? { if case .success(let s) = self { return s } else { return nil } }
    var failure: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}
