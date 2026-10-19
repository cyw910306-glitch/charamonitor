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
