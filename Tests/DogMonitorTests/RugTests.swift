import XCTest
import simd
@testable import DogMonitor

/// 바탕화면 러그: the cloth's physics (ClothSheet), pure.
final class RugTests: XCTestCase {
    private let walls = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testFlatClothSettlesWhereItLies() {
        var c = ClothSheet(origin: CGPoint(x: 100, y: 100), walls: walls)
        let start = c.points
        for _ in 0..<120 { c.step(dt: 1.0 / 60) }
        XCTAssertTrue(c.isSettled)
        for (a, b) in zip(start, c.points) { XCTAssertEqual(simd_length(a - b), 0, accuracy: 0.5) }
    }

    func testDraggedCornerPullsTheFarCornerAlongAndNothingSinks() throws {
        var c = ClothSheet(origin: CGPoint(x: 600, y: 100), walls: walls)
        let far = c.index(c.cols - 1, c.rows - 1), farStart = c.points[far]
        XCTAssertTrue(c.grab(at: CGPoint(x: 600, y: 100)))   // the bottom-left corner
        for k in 1...120 {
            c.drag(to: CGPoint(x: 600 - Double(k) * 4, y: 100))   // 480 pt to the left over 2 s
            c.step(dt: 1.0 / 60)
            XCTAssertTrue(c.points.allSatisfy { $0.z >= 0 }, "a point went under the floor")
        }
        XCTAssertLessThan(c.points[far].x, farStart.x - 50)   // the whole rug came along
        XCTAssertLessThan(c.worstStretch, 1.2)                 // the constraints held
        c.release()
        for _ in 0..<240 { c.step(dt: 1.0 / 60) }
        XCTAssertTrue(c.points.allSatisfy { $0.z >= 0 })
        XCTAssertNil(c.held)
    }

    /// One touch must not keep the 60 fps timer (and the full-screen render) running: every kind of handling comes to rest.
    func testEveryTouchComesToRest() {
        for bend in RugSoftness.allCases.map(\.bend) {
            func rests(_ name: String, _ act: (inout ClothSheet) -> Void) {
                var c = ClothSheet(bend: bend, origin: CGPoint(x: 600, y: 300), walls: walls)
                act(&c)
                var n = 0
                while !c.isSettled, n < 60 * 60 { c.step(dt: 1.0 / 60); n += 1 }
                XCTAssertTrue(c.isSettled, "\(name) at bend \(bend) still moving after a minute")
                XCTAssertLessThan(c.points.map(\.z).max() ?? 0, c.spacing * 3, "\(name) at bend \(bend) flew up")
            }
            rests("nudge") { c in _ = c.grab(at: CGPoint(x: 600, y: 300)); for k in 1...10 { c.drag(to: CGPoint(x: 600 + Double(k) * 2, y: 300)); c.step(dt: 1.0 / 60) }; c.release() }
            rests("bunch") { c in
                let p = CGPoint(x: 600 + c.size.width / 2, y: 300 + c.size.height / 2)
                _ = c.grab(at: p)
                for k in 1...60 { c.drag(to: CGPoint(x: p.x + Double(k) * 3, y: p.y)); c.step(dt: 1.0 / 60) }
                c.release()
            }
            rests("throw") { c in
                _ = c.grab(at: CGPoint(x: 600, y: 300))
                for k in 1...20 { c.drag(to: CGPoint(x: 600 - Double(k) * 10, y: 300)); c.step(dt: 1.0 / 60) }
                c.release(velocity: CGVector(dx: -2000, dy: 500))
            }
        }
    }

    func testFoldingAnEdgeOverShowsItsBack() {
        var c = ClothSheet(origin: CGPoint(x: 300, y: 300), walls: walls)
        XCTAssertTrue(c.grab(at: CGPoint(x: 300, y: 300 + c.size.height / 2)))   // the left edge, halfway up
        for k in 1...90 { c.drag(to: CGPoint(x: 300 + Double(k) * 3, y: 300 + c.size.height / 2)); c.step(dt: 1.0 / 60) }
        c.release()
        for _ in 0..<120 { c.step(dt: 1.0 / 60) }
        XCTAssertTrue(c.normals().contains { $0.z < 0 }, "some of it lies face down")
    }

    func testSmoothingEndsExactlyFlatAtItsPlace() {
        var c = ClothSheet(origin: CGPoint(x: 50, y: 60), walls: walls)
        _ = c.grab(at: CGPoint(x: 50, y: 60))
        for k in 1...30 { c.drag(to: CGPoint(x: 50 + Double(k) * 5, y: 60 + Double(k) * 2)); c.step(dt: 1.0 / 60) }
        c.release()
        let crumpled = c.points
        let home = CGPoint(x: 400, y: 300)
        let mid = ClothSheet.flatten(from: crumpled, rest: c.rest, to: home, progress: 0.5)
        let done = ClothSheet.flatten(from: crumpled, rest: c.rest, to: home, progress: 1)
        for (p, r) in zip(done, c.rest) {
            XCTAssertEqual(p.x, r.x + 400, accuracy: 1e-9); XCTAssertEqual(p.y, r.y + 300, accuracy: 1e-9); XCTAssertEqual(p.z, 0, accuracy: 1e-9)
        }
        XCTAssertNotEqual(mid, done)
        c.place(done)
        XCTAssertTrue(c.covers(CGPoint(x: 400 + c.size.width / 2, y: 300 + c.size.height / 2)))
        XCTAssertFalse(c.covers(CGPoint(x: 10, y: 10)))
    }
}

/// 바탕화면 러그's prefs and faces.
final class RugFaceTests: XCTestCase {
    func testOldSavedPrefsGetTheCharacterFace() throws {
        let old = #"{"on":true,"softness":"floppy","home":[0.5,0.5]}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(RugPrefs.self, from: old)
        XCTAssertTrue(p.on)
        XCTAssertEqual(p.softness, .floppy)
        XCTAssertEqual(p.face, .character)
        XCTAssertEqual(p.color, .strawberry)
        let round = try JSONDecoder().decode(RugPrefs.self, from: JSONEncoder().encode(RugPrefs(face: .pattern, color: .sky)))
        XCTAssertEqual(round.face, .pattern)
        XCTAssertEqual(round.color, .sky)
    }

    func testSizeIsSavedAndOldPrefsAreNormal() throws {
        let old = #"{"on":true,"face":"pattern","size":"gigantic"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(RugPrefs.self, from: old)
        XCTAssertEqual(p.size, .normal)        // an unknown size falls back, the rest still loads
        XCTAssertEqual(p.face, .pattern)
        let round = try JSONDecoder().decode(RugPrefs.self, from: JSONEncoder().encode(RugPrefs(face: .dots, size: .huge)))
        XCTAssertEqual(round.size, .huge)
        XCTAssertEqual(round.face, .dots)
    }

    /// Bigger sizes make a bigger cloth, 보통 keeps the original 255 by 170 pt rug, and every size still comes to rest.
    func testEachSizeIsBiggerAndSettles() {
        let walls = CGRect(x: 0, y: 0, width: 2000, height: 1400)
        let widths = RugSize.allCases.map { ClothSheet(spacing: $0.spacing, walls: walls).size.width }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, widths.count)
        XCTAssertEqual(ClothSheet(spacing: RugSize.normal.spacing, walls: walls).size, CGSize(width: 255, height: 170))
        for s in RugSize.allCases {
            var c = ClothSheet(spacing: s.spacing, origin: CGPoint(x: 600, y: 300), walls: walls)
            _ = c.grab(at: CGPoint(x: 600, y: 300))
            for k in 1...30 { c.drag(to: CGPoint(x: 600 + Double(k) * 6, y: 300)); c.step(dt: 1.0 / 60) }
            c.release()
            var n = 0
            while !c.isSettled, n < 60 * 60 { c.step(dt: 1.0 / 60); n += 1 }
            XCTAssertTrue(c.isSettled, "\(s) still moving after a minute")
        }
    }

    /// Every pattern takes 러그 색: two colours never print the same picture.
    func testPatternsTakeTheRugColour() throws {
        func pixels(_ face: RugFace, _ t: FocusTheme) throws -> Data {
            let cg = try XCTUnwrap(RugArt.front(face, color: t, character: nil).cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(cg.dataProvider?.data as Data?)
        }
        for face in RugFace.allCases where face != .character {
            XCTAssertNotEqual(try pixels(face, .mint), try pixels(face, .strawberry), "\(face) ignores the colour")
            XCTAssertEqual(RugArt.front(face, color: .sky, character: nil).size, RugArt.size)
        }
        let faces = try RugFace.allCases.filter { $0 != .character }.map { try pixels($0, .sky) }
        XCTAssertEqual(Set(faces).count, faces.count, "two patterns draw the same")
    }

    func testCharacterFaceDrawsABuiltInCharacter() throws {
        let art = try XCTUnwrap(RugArt.art(DogSpriteCache(profile: .defaultDog, style: .pixel)))
        XCTAssertGreaterThan(RugArt.opaqueBounds(art.image).width, 0)
        let face = RugArt.front(.character, color: .mint, character: art)
        XCTAssertEqual(face.size, RugArt.size)
        XCTAssertNotNil(face.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
}

extension RugFaceTests {
    /// The tan cat's frames carry a dark menu bar copy (lifted outline): a rug printed in dark mode must still use the light one.
    func testCharacterFaceIgnoresDarkMode() throws {
        let cat = try XCTUnwrap(OriginalCatalog.all.first)
        let art = try XCTUnwrap(RugArt.art(DogSpriteCache(cat, style: .pixel)))
        func pixels(_ name: NSAppearance.Name) throws -> Data {
            var image: NSImage?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { image = RugArt.front(.character, color: .lemon, character: art) }
            let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(cg.dataProvider?.data as Data?)
        }
        XCTAssertEqual(try pixels(.darkAqua), try pixels(.aqua))
    }
}

/// 캐릭터 모양 러그: the cut-out (RugMask), its hotspot as the cloth moves, and the textures cut to it.
final class RugShapeTests: XCTestCase {
    private let walls = CGRect(x: 0, y: 0, width: 1200, height: 800)

    /// A 20 by 14 block in a 40 by 30 grid with a one-cell hole and a one-cell-wide tail out to the right.
    private func block() -> [Bool] {
        var g = Array(repeating: false, count: 40 * 30)
        for y in 8...21 { for x in 10...29 { g[y * 40 + x] = true } }
        g[15 * 40 + 20] = false
        for x in 30...37 { g[15 * 40 + x] = true }
        return g
    }

    private func centre(_ x: Int, _ y: Int) -> (u: Double, v: Double) { ((Double(x) + 0.5) / 40, (Double(y) + 0.5) / 30) }

    func testMaskGrowsFillsHolesAndPrunesThinTails() {
        let m = RugMask(silhouette: block(), cols: 40, rows: 30, grow: 2, thin: 2)
        func on(_ x: Int, _ y: Int) -> Bool { let c = centre(x, y); return m.covers(u: c.u, v: c.v) }
        XCTAssertTrue(on(20, 15), "the hole is filled")
        XCTAssertTrue(on(10, 8) && on(29, 21) && on(15, 12), "the block is all on the mat")
        XCTAssertTrue(on(31, 12) && on(15, 6), "the mat reaches past the block")
        XCTAssertFalse(on(37, 15) || on(35, 15), "the 1 cell tail is pruned")
        XCTAssertFalse(on(0, 0) || on(39, 29) || on(5, 15), "off the character stays see-through")
        for (a, b) in zip(m.inner, m.cells) { XCTAssertLessThanOrEqual(a, b + 1e-6) }   // the rim's inside is inside
        XCTAssertFalse(m.isEmpty)
        XCTAssertTrue(RugMask(silhouette: Array(repeating: false, count: 100), cols: 10, rows: 10).isEmpty)
    }

    func testMorphologyKeepsWideLegsAndFillsAnyEnclosedHole() {
        var g = Array(repeating: false, count: 30 * 30)
        for y in 5...24 { for x in 5...24 where !(10...19 ~= x && 10...19 ~= y) { g[y * 30 + x] = true } }   // a ring
        let filled = RugMask.filled(g, 30, 30)
        XCTAssertTrue(filled[15 * 30 + 15])
        XCTAssertFalse(filled[2 * 30 + 2])
        var leg = Array(repeating: false, count: 30 * 30)
        for y in 2...27 { for x in 14...16 { leg[y * 30 + x] = true } }   // three wide: survives a radius 1 opening
        let opened = RugMask.dilate(RugMask.erode(leg, 30, 30, 1), 30, 30, 1)
        XCTAssertTrue(opened[15 * 30 + 15])
        XCTAssertEqual(RugMask.erode(leg, 30, 30, 2).filter { $0 }.count, 0)
    }

    /// The hotspot is the mat as the cloth lies: it moves and bends with the cloth, and the see-through corners let clicks by.
    func testOutlineFollowsTheCloth() {
        let m = RugMask(silhouette: block(), cols: 40, rows: 30, grow: 2, thin: 2)
        var c = ClothSheet(origin: CGPoint(x: 100, y: 100), walls: walls)
        func mid(_ x: Int, _ y: Int, _ o: CGFloat) -> CGPoint {
            let q = centre(x, y)
            return CGPoint(x: o + CGFloat(q.u) * c.size.width, y: 100 + CGFloat(q.v) * c.size.height)
        }
        var path = m.outline(c)
        XCTAssertTrue(path.contains(mid(15, 12, 100)))
        XCTAssertFalse(path.contains(CGPoint(x: 103, y: 103)), "a see-through corner takes no click")
        XCTAssertFalse(path.contains(mid(37, 15, 100)))
        c.place(ClothSheet.flatten(from: c.points, rest: c.rest, to: CGPoint(x: 500, y: 100), progress: 1))
        path = m.outline(c)
        XCTAssertTrue(path.contains(mid(15, 12, 500)))
        XCTAssertFalse(path.contains(mid(15, 12, 100)))
        // Folded over, every bit of the hotspot is still on the cloth.
        _ = c.grab(at: CGPoint(x: 500, y: 100 + c.size.height / 2))
        for k in 1...60 { c.drag(to: CGPoint(x: 500 + Double(k) * 3, y: 100 + c.size.height / 2)); c.step(dt: 1.0 / 60) }
        c.release()
        for _ in 0..<60 { c.step(dt: 1.0 / 60) }
        let box = m.outline(c).boundingBoxOfPath
        XCTAssertFalse(box.isEmpty)
        XCTAssertTrue(c.outline().boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(box))
    }

    func testOldPrefsAreRectangleAndTheShapeIsSaved() throws {
        let old = #"{"on":true,"face":"stars","size":"huge"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(RugPrefs.self, from: old).shape, .rect)
        let round = try JSONDecoder().decode(RugPrefs.self, from: JSONEncoder().encode(RugPrefs(face: .stripes, shape: .character)))
        XCTAssertEqual(round.shape, .character)
        XCTAssertEqual(round.face, .stripes)
    }

    /// Each built-in kind gets a mat: corners see-through, the middle of the character solid, a dark rim at the edge.
    func testBuiltInCharactersGetAMat() throws {
        let caches = [DogSpriteCache(profile: .defaultDog, style: .pixel), DogSpriteCache(try XCTUnwrap(CatCatalog.all.first), style: .pixel),
                      DogSpriteCache(try XCTUnwrap(OriginalCatalog.all.first), style: .pixel),
                      DogSpriteCache(profile: .defaultDog, style: .illustration)]
        for cache in caches {
            let art = try XCTUnwrap(RugArt.art(cache))
            let m = try XCTUnwrap(RugArt.mask(art))
            let share = Double(m.cells.filter { $0 >= 0.5 }.count) / Double(m.cells.count)
            XCTAssertGreaterThan(share, 0.15); XCTAssertLessThan(share, 0.9)
            XCTAssertFalse(m.covers(u: 0.01, v: 0.01))
            for face in [RugFace.character, .stars] {
                let cg = try XCTUnwrap(RugArt.front(face, color: .mint, character: art, mask: m).cgImage(forProposedRect: nil, context: nil, hints: nil))
                let data = try XCTUnwrap(cg.dataProvider?.data as Data?), row = cg.bytesPerRow
                XCTAssertEqual(data[3], 0, "the corner is see-through")
                let alphas = stride(from: 3, to: data.count, by: 4).map { data[$0] }
                XCTAssertGreaterThan(alphas.filter { $0 == 255 }.count, alphas.count / 10)
                _ = row
            }
            let back = try XCTUnwrap(RugArt.back(.stars, color: .mint, mask: m).cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(try XCTUnwrap(back.dataProvider?.data as Data?)[3], 0)
        }
    }
}
