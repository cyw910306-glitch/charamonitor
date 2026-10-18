import XCTest
@testable import DogMonitor

final class OriginalSet2Tests: XCTestCase {
    func testEveryOriginalHasAllPosesAndExtrasOnTheCanvas() {
        let n = DogSpriteCache.canvasWidth * DogSpriteCache.canvasHeight * 4
        XCTAssertEqual(OriginalCharacterSet2.all.map(\.id), ["original-tan-cat"])
        for c in OriginalCharacterSet2.all {
            XCTAssertEqual(c.poseRGBA.count, DogPose.allCases.count, c.id)
            for pose in DogPose.allCases {
                XCTAssertTrue(FrameArt.frameRange(pose).contains(c.poseRGBA[pose.rawValue].count), "\(c.id) \(pose)")
                XCTAssertEqual(c.frames(for: pose).count, c.poseRGBA[pose.rawValue].count)
                // Feet on the ground row in the sitting/walking poses (hops are allowed in run and sprint).
                if [.lying, .slowWalk, .exhausted].contains(pose) {
                    for f in c.poseRGBA[pose.rawValue] { XCTAssertTrue(stride(from: n - 34 * 4 + 3, to: n, by: 4).contains { f[$0] != 0 }, "\(c.id) \(pose)") }
                }
            }
            for f in c.poseRGBA.flatMap({ $0 }) { XCTAssertEqual(f.count, n) }
            let counts = [ExtraMotion.hungry: 4...4, .eat: 4...4, .special: 6...8]
            for motion in ExtraMotion.allCases {
                let frames = c.extraRGBA[motion] ?? []
                XCTAssertTrue(counts[motion]!.contains(frames.count), "\(c.id) \(motion) \(frames.count)")
                XCTAssertTrue(frames.allSatisfy { $0.count == n && $0.contains { $0 != 0 } }, "\(c.id) \(motion)")
                XCTAssertEqual(c.frames(forExtra: motion)?.count, frames.count)
            }
            XCTAssertEqual(c.imageSize, DogSpriteCache(profile: .defaultDog).imageSize)
            // Works as a menu bar character through the existing custom-frames path.
            let cache = DogSpriteCache(profile: .defaultDog, custom: c.poseRGBA)
            XCTAssertEqual(cache.frames(for: .run).count, c.poseRGBA[DogPose.run.rawValue].count)
        }
    }

    func testNamesHaveNoEmDash() {
        for c in OriginalCharacterSet2.all {
            for text in [c.displayName, c.specialName, c.blurb] { XCTAssertFalse(text.contains("\u{2014}"), "\(c.id): \(text)") }
        }
    }

    /// ART-1: on a dark menu bar the outline is lifted so dark art stays visible; eyes stay dark.
    func testDarkMenuBarLiftsTheOutline() throws {
        for c in OriginalCharacterSet2.all {
            let img = try XCTUnwrap(c.frames(for: .walk).first)
            let light = Self.pixels(img, .aqua), dark = Self.pixels(img, .darkAqua), again = Self.pixels(img, .aqua)
            var changed = 0, same = 0
            for y in 0..<20 { for x in 0..<34 {
                let a = light.colorAt(x: x, y: y)!, b = dark.colorAt(x: x, y: y)!
                guard a.alphaComponent > 0.5 else { continue }
                let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                if d > 0.15 { changed += 1 } else { same += 1 }
                XCTAssertEqual(again.colorAt(x: x, y: y), a, "\(c.id) light draw after dark")
            } }
            XCTAssertGreaterThan(changed, 20, c.id)
            XCTAssertGreaterThan(same, changed, c.id)
        }
    }

    /// `image` drawn at 1 px per point in `appearance`.
    static func pixels(_ image: NSImage, _ name: NSAppearance.Name, width: Int = 34, height: Int = 20) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }

    /// Characters removed from the app (5.x): a saved selection, hide list or 꾸미기 colours for them falls back to the dog.
    func testRemovedOriginalFallsBackToTheDog() {
        let suite = "test.removed-originals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for id in ["original-swordsman", "original-fighter", "original-idol", "original-magical-girl", "original-ninja", "original-robot"] {
            defaults.set("original", forKey: "character")
            defaults.set(id, forKey: "originalID")
            defaults.set(try! JSONEncoder().encode([id]), forKey: "hiddenCharacters")
            defaults.set(try! JSONEncoder().encode([id: ["hair": RGBColor(hex: "#FF0000")]]), forKey: "characterColors")
            let s = AppSettings(defaults: defaults)
            XCTAssertNil(OriginalCatalog.character(id), id)
            XCTAssertNil(s.activeOriginal, id)
            XCTAssertEqual(s.shownCharacter, .dog, id)
            XCTAssertEqual(s.characterName, s.dogName, id)
            XCTAssertNil(SpriteLook(s).ready, id)
            XCTAssertFalse(DogSpriteCache(SpriteLook(s), pixelSize: 1).frames(for: .walk).isEmpty, id)
            XCTAssertEqual(Persona.preset(character: .original, id: id), .friendly, id)
        }
    }
}
