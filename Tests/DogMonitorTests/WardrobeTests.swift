import SwiftUI
import XCTest
@testable import DogMonitor

/// 옷 입히기: anchors from a frame's pixels, steady anchors per pose, the overlay, the store key and the saved form.
final class WardrobeTests: XCTestCase {
    /// A `w` x `h` frame with the boxes `(x, y, w, h)` (rows from the top) filled in `rgb`.
    private func frame(_ w: Int, _ h: Int, _ boxes: [(Int, Int, Int, Int)], rgb: UInt8 = 200) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: w * h * 4)
        for (bx, by, bw, bh) in boxes {
            for y in by..<(by + bh) { for x in bx..<(bx + bw) { let i = (y * w + x) * 4; f[i] = rgb; f[i + 1] = rgb; f[i + 2] = rgb; f[i + 3] = 255 } }
        }
        return f
    }

    func testAnchorIsTheHeadAtTheTopNotATailTip() {
        // A head 8 wide at x 20..27 from row 4, a one-px tail tip at x 2 on row 4, a body below.
        let f = frame(34, 20, [(20, 4, 8, 6), (2, 4, 1, 1), (2, 8, 26, 8)])
        let a = Wardrobe.anchor(f, w: 34, h: 20)
        XCTAssertEqual(a, Wardrobe.Anchor(x: 24, top: 4, width: 8, height: 12))
        XCTAssertEqual(a?.eyesY, 4 + 2)   // 0.30 of a head 0.42 of the box
        XCTAssertEqual(a?.neckY, 4 + 5)
        XCTAssertEqual(a?.band, 9..<13)
        XCTAssertNil(Wardrobe.anchor([UInt8](repeating: 0, count: 34 * 20 * 4), w: 34, h: 20))
    }

    func testAnchorsHoldStillWithinTwoPixelsOfThePosesFirstFrame() {
        let first = Wardrobe.Anchor(x: 20, top: 4, width: 8, height: 12)
        let got = Wardrobe.steady([first, Wardrobe.Anchor(x: 25, top: 1, width: 5, height: 9), nil, Wardrobe.Anchor(x: 21, top: 5, width: 8, height: 12)])
        XCTAssertEqual(got, [first, Wardrobe.Anchor(x: 22, top: 2, width: 8, height: 12), first, Wardrobe.Anchor(x: 21, top: 5, width: 8, height: 12)])
    }

    func testAnEmptyOutfitLeavesEveryPixelAsItWas() {
        let f = frame(34, 20, [(20, 4, 8, 6), (2, 8, 26, 8)])
        XCTAssertEqual(Wardrobe.dress([[f]], outfit: Outfit()), [[f]])
        XCTAssertEqual(Wardrobe.dress([[f]], outfit: nil), [[f]])
        let img = NSImage(size: NSSize(width: 34, height: 20))
        XCTAssertTrue(Wardrobe.dress([img], outfit: Outfit(), grid: (34, 20), smooth: false)[0] === img)
    }

    func testAHatSitsOnTheHeadAndAShirtTintsTheBandButNotTheOutline() {
        var f = frame(34, 20, [(20, 4, 8, 6), (2, 8, 26, 8)])
        let dark = (12 * 34 + 2) * 4   // an outline pixel inside the band
        f[dark] = 10; f[dark + 1] = 10; f[dark + 2] = 10
        let a = Wardrobe.anchor(f, w: 34, h: 20)!
        let over = Wardrobe.overlay(f, w: 34, h: 20, outfit: Outfit(head: "beret", shirt: "#FF0000"), anchor: a)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { over[(y * 34 + x) * 4 + 3] }
        XCTAssertEqual(alpha(24, 4), 255, "the beret's brim (its pin row) on the head's top row")
        XCTAssertEqual(alpha(24, 2), 255, "its tip two rows up")
        XCTAssertEqual(alpha(24, 1), 0, "the beret is 3 rows: nothing above its top")
        XCTAssertEqual(alpha(10, 10), UInt8(255 * 0.85), "body in the band: tinted")
        XCTAssertEqual(over[(10 * 34 + 10) * 4 + 1], 0, "red has no green")
        XCTAssertEqual(alpha(2, 12), 0, "the darkest outline stays")
        XCTAssertEqual(alpha(10, 15), 0, "below the band: as drawn")
        XCTAssertEqual(alpha(0, 10), 0, "see-through stays see-through")
        let dressed = Wardrobe.composite(f, over)
        XCTAssertEqual(dressed[(10 * 34 + 10) * 4], UInt8(min(255, Int(UInt8(255 * 0.85)) + 200 * (255 - Int(UInt8(255 * 0.85))) / 255)))
    }

    func testNudgesMoveAStampAndStopAtEight() {
        let f = frame(34, 20, [(20, 8, 8, 6), (2, 12, 26, 6)])
        let a = Wardrobe.anchor(f, w: 34, h: 20)!
        let plain = Wardrobe.overlay(f, w: 34, h: 20, outfit: Outfit(head: "beret"), anchor: a)
        let moved = Wardrobe.overlay(f, w: 34, h: 20, outfit: Outfit(head: "beret", nudges: ["head": OutfitNudge(dx: 1, dy: -2)]), anchor: a)
        func row(_ o: [UInt8], _ y: Int) -> [UInt8] { (0..<34).map { o[(y * 34 + $0) * 4 + 3] } }
        XCTAssertEqual(row(plain, 8).firstIndex(of: 255).map { $0 + 1 }, row(moved, 6).firstIndex(of: 255))
        let far = Wardrobe.overlay(f, w: 34, h: 20, outfit: Outfit(head: "beret", nudges: ["head": OutfitNudge(dx: 0, dy: -50)]), anchor: a)
        XCTAssertEqual(row(far, 0), row(plain, 8), "clamped to 8 up")
    }

    func testStampsScaleOnDenserFramesOnly() {
        let f = frame(68, 40, [(40, 8, 16, 12), (4, 16, 52, 16)])
        let a = Wardrobe.anchor(f, w: 68, h: 40)!
        let over = Wardrobe.overlay(f, w: 68, h: 40, outfit: Outfit(head: "beret"), anchor: a, unit: 2)
        let wide = (0..<68).filter { over[(8 * 68 + $0) * 4 + 3] > 0 }.count
        XCTAssertEqual(wide, 14, "the 7 px brim at 2x")
    }

    func testKeyIsTheCharacterIdTheCustomUUIDOrDog() {
        var look = SpriteLook(AppSettings(defaults: UserDefaults(suiteName: "wardrobe-key-\(UUID())")!))
        look.character = .dog
        XCTAssertEqual(Wardrobe.key(look), "dog")
        look.character = .original; look.readyID = "original-tan-cat-hd"
        XCTAssertEqual(Wardrobe.key(look), "original-tan-cat", "an HD pair shares its dot twin's outfit")
        look.character = .cat; look.readyID = "cat-tabby"
        XCTAssertEqual(Wardrobe.key(look), "cat-tabby")
        look.character = .custom; look.custom = nil
        XCTAssertEqual(Wardrobe.key(look), "dog")
    }

    func testOutfitsRoundTripThroughSettings() throws {
        let suite = "wardrobe-store-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let outfit = Outfit(head: "crown", eyes: "sun", neck: nil, shirt: "#3EC48F", nudges: ["eyes": OutfitNudge(dx: -1, dy: 2)])
        AppSettings(defaults: defaults).outfits = ["dog": outfit]
        XCTAssertEqual(AppSettings(defaults: defaults).outfits, ["dog": outfit])
        XCTAssertEqual(try JSONDecoder().decode(Outfit.self, from: JSONEncoder().encode(outfit)), outfit)
        XCTAssertEqual(SetupFile.keys["outfits"], .data, "travels in 내 설정 내보내기")
    }

    func testEveryItemHasArtOrAColourAndAUniqueId() {
        XCTAssertEqual(Set(Wardrobe.items.map(\.id)).count, Wardrobe.items.count)
        for it in Wardrobe.items {
            if it.slot == .shirt { XCTAssertNotNil(it.hex, it.id) } else { XCTAssertFalse(it.art.isEmpty, it.id); XCTAssertTrue(it.art.indices.contains(it.pin), it.id) }
        }
    }

    /// QA sheet: WARDROBE_QA_DIR=<folder> swift test --filter WardrobeTests/testRenderQASheets
    func testRenderQASheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["WARDROBE_QA_DIR"] else { throw XCTSkip("set WARDROBE_QA_DIR to render") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let outfits: [(String, Outfit)] = [
            ("none", Outfit()),
            ("beret-round-scarf-strawberry", Outfit(head: "beret", eyes: "round", neck: "scarf", shirt: "#FF7EA8")),
            ("crown-sun-bowtie-mint", Outfit(head: "crown", eyes: "sun", neck: "bowtie", shirt: "#3EC48F")),
            ("party-heart-lavender", Outfit(head: "party", eyes: "heart", shirt: "#9D86EE")),
            ("cap-sky", Outfit(head: "cap", shirt: "#5AAEF5")),
            ("beanie-black", Outfit(head: "beanie", shirt: "#333333")),
            ("ribbon-white", Outfit(head: "ribbon", shirt: "#FFFFFF")),
            ("flower-lemon", Outfit(head: "flower", neck: "scarf", shirt: "#EDBE2B")),
        ]
        let shiba = DogProfile.presets.first { $0.id == "shiba" }?.profile ?? .defaultDog
        var rows: [(String, (Outfit) -> DogSpriteCache)] = [
            ("dog", { DogSpriteCache(profile: .defaultDog, pixelSize: 6, style: .pixel, outfit: $0) }),
            ("shiba", { DogSpriteCache(profile: shiba, pixelSize: 6, style: .pixel, outfit: $0) }),
            ("dog-illustration", { DogSpriteCache(profile: .defaultDog, pixelSize: 6, style: .illustration, outfit: $0) }),
        ]
        for c in Array(CatCatalog.all.prefix(2)) + Array(OriginalCatalog.all.prefix(3)) {
            rows.append((c.id, { DogSpriteCache(c, pixelSize: 6, style: .pixel, outfit: .some($0)) }))
        }
        if let c = OriginalCatalog.all.first { rows.append((c.id + "-illustration", { DogSpriteCache(c, pixelSize: 6, style: .illustration, outfit: .some($0)) })) }
        let cell = NSSize(width: 34 * 6 + 16, height: 20 * 6 + 24)
        for dark in [false, true] {
            let size = NSSize(width: cell.width * CGFloat(outfits.count * 2), height: cell.height * CGFloat(rows.count))
            let sheet = NSImage(size: size, flipped: true) { _ in
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
                NSRect(origin: .zero, size: size).fill()
                for (r, row) in rows.enumerated() {
                    for (o, outfit) in outfits.enumerated() {
                        let walk = row.1(outfit.1).frames(for: .walk)
                        for k in 0..<2 where walk.indices.contains(k) {
                            let origin = NSPoint(x: cell.width * CGFloat(o * 2 + k) + 8, y: cell.height * CGFloat(r) + 4)
                            NSGraphicsContext.current?.imageInterpolation = .none
                            walk[k].draw(in: NSRect(origin: origin, size: walk[k].size), from: .zero, operation: .sourceOver, fraction: 1,
                                         respectFlipped: true, hints: nil)
                            if k == 0 {
                                (row.0 + " / " + outfit.0 as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + 20 * 6 + 2), withAttributes: [
                                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dark ? NSColor.white : NSColor.black])
                            }
                        }
                    }
                }
                return true
            }
            let rep = NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation))
            try XCTUnwrap(rep?.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(dark ? "wardrobe-dark.png" : "wardrobe-light.png"))
        }
        // The settings card, dressing the dog.
        let suite = "wardrobe-qa-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.outfits = ["dog": Outfit(head: "beret", eyes: "round", neck: "scarf", shirt: "#FF7EA8", nudges: ["eyes": OutfitNudge(dx: 1, dy: 0)])]
        let host = NSHostingView(rootView: WardrobeSettings(settings: s).frame(width: 380).padding(14).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 408, height: 420)
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("wardrobe-settings.png"))
    }
}
