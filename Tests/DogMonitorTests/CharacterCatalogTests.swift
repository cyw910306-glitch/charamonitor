import AppKit
import XCTest
@testable import DogMonitor

/// A tiny ready-made character: one blank frame per pose, `special` only.
private struct FakeCharacter: AnimatedCharacter {
    let id: String
    var displayName: String { "테스트 \(id)" }
    var imageSize: NSSize { NSSize(width: 30, height: 20) }
    func frames(for pose: DogPose) -> [NSImage] { pose == .run ? [] : [NSImage(size: imageSize), NSImage(size: imageSize)] }
    func frames(forExtra motion: ExtraMotion) -> [NSImage]? { motion == .special ? [NSImage(size: imageSize)] : nil }
}

final class CharacterCatalogTests: XCTestCase {
    private var saved: (cats: [any AnimatedCharacter], originals: [any AnimatedCharacter])!
    private let suite = "test.dogmonitor.catalog.\(UUID().uuidString)"
    private var settings: AppSettings!

    override func setUp() {
        saved = (CatCatalog.all, OriginalCatalog.all)
        CatCatalog.all = [FakeCharacter(id: "cat-a")]
        OriginalCatalog.all = [FakeCharacter(id: "orig-a")]
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        CatCatalog.all = saved.cats
        OriginalCatalog.all = saved.originals
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testOldSavedValuesStillDecode() throws {
        for (stored, expected) in [("dog", SpriteCharacter.dog), ("custom", .custom), ("cat", .cat), ("original", .original)] {
            XCTAssertEqual(SpriteCharacter(rawValue: stored), expected, stored)
        }
        XCTAssertNil(SpriteCharacter(rawValue: "dragon"), "unknown values fall back to the dog in AppSettings")
        let old = Data(#"["dog","custom"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([SpriteCharacter].self, from: old), [.dog, .custom])
        // Raw values are what is saved; they must never change.
        XCTAssertEqual(SpriteCharacter.allCases.map(\.rawValue), ["dog", "custom", "cat", "original"])
    }

    func testOldSettingsLoadWithoutNewKeys() throws {
        let suite = "test.dogmonitor.catalog.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        d.set("custom", forKey: "character")   // a 1.9 install: no catID / originalID keys
        d.set("customCharacterID-1", forKey: "customCharacterID")
        let s = AppSettings(defaults: d)
        XCTAssertEqual(s.character, .custom)
        XCTAssertEqual(s.customCharacterID, "customCharacterID-1")
        XCTAssertNil(s.catID)
        XCTAssertNil(s.originalID)
        d.set("girl", forKey: "character")   // a character later builds removed
        XCTAssertEqual(AppSettings(defaults: d).character, .dog)
        d.set("future-thing", forKey: "character")
        XCTAssertEqual(AppSettings(defaults: d).character, .dog)
        // The new keys round-trip.
        s.useCat("cat-a")
        let again = AppSettings(defaults: d)
        XCTAssertEqual(again.character, .cat)
        XCTAssertEqual(again.catID, "cat-a")
    }

    func testUnknownCatShowsTheDog() {
        settings.useCat("cat-a")
        XCTAssertEqual(settings.shownCharacter, .cat)
        XCTAssertEqual(settings.characterName, "테스트 cat-a")
        settings.catID = "gone"
        XCTAssertEqual(settings.shownCharacter, .dog)
    }

    func testOriginalsShowAndMissingOnesShowTheDog() {
        settings.useOriginal("orig-a")
        XCTAssertEqual(settings.character, .original)
        XCTAssertEqual(settings.shownCharacter, .original)
        XCTAssertEqual(SpriteLook(settings).ready?.id, "orig-a")
        settings.originalID = "missing"
        XCTAssertEqual(settings.shownCharacter, .dog)
    }

    func testCacheWrapsAnimatedCharacter() {
        let cache = DogSpriteCache(FakeCharacter(id: "x"), pixelSize: 3)
        XCTAssertEqual(cache.imageSize, NSSize(width: 90, height: 60))
        XCTAssertEqual(cache.frames(for: .run).count, 2, "an empty pose plays the walk")
        XCTAssertEqual(cache.availableExtras, [.special])
        XCTAssertNil(cache.frames(forExtra: .eat))
        XCTAssertEqual(cache.frames(for: .walk, extra: .eat), cache.frames(for: .walk))
        XCTAssertEqual(cache.frames(for: .walk, extra: .special).count, 1)
        XCTAssertTrue(DogSpriteCache(profile: .defaultDog).availableExtras.isEmpty || BuiltinExtras.dog != nil)
    }

    func testPlaceholdersExistAndHaveFrames() {
        for p in CatCatalog.placeholders {
            XCTAssertFalse(p.frames(for: .walk).isEmpty, p.id)
        }
    }

    func testUpdaterAcceptsBothHosts() {
        XCTAssertTrue(UpdateCheck.isAllowed(URL(string: "https://jelly-monitor.vercel.app/JellyMonitor.zip")))
        XCTAssertTrue(UpdateCheck.isAllowed(URL(string: "https://charamonitor.vercel.app/CharaMonitor.zip")))
        XCTAssertTrue(UpdateCheck.isAllowed(URL(string: "https://CHARAMONITOR.vercel.app/x.zip")))
        for bad in ["https://charamonitor.vercel.app.evil.com/u", "http://charamonitor.vercel.app/u", "https://evil-charamonitor.vercel.app/u"] {
            XCTAssertFalse(UpdateCheck.isAllowed(URL(string: bad)), bad)
        }
        XCTAssertEqual(UpdateCheck.manifestURL.absoluteString, "https://jelly-monitor.vercel.app/update.json")
        XCTAssertTrue(UpdateCheck.hosts.contains(UpdateCheck.checkHost))
    }
}

final class CatalogWiringTests: XCTestCase {
    /// The shipped build lists every cat and original, and the dog carries hungry/eat frames.
    func testCatalogsAndBuiltinExtrasAreWired() {
        XCTAssertEqual(CatCatalog.all.count, 12)
        XCTAssertEqual(OriginalCatalog.all.map(\.id), ["original-tan-cat"])   // the test host loads no packs
        XCTAssertEqual(Set(CatCatalog.all.map(\.id)).count + Set(OriginalCatalog.all.map(\.id)).count, 13)
        XCTAssertEqual(DogSpriteCache(profile: .defaultDog).availableExtras, [.hungry, .eat])
        for c in OriginalCatalog.all { XCTAssertEqual(DogSpriteCache(c).availableExtras, Set(ExtraMotion.allCases), c.id) }
    }
}
