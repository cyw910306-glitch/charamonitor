import XCTest
@testable import DogMonitor

/// 2P 캐릭터: the saved pick, and when P2 wears it plain or falls back to P1's own character tinted.
final class P2CharacterTests: XCTestCase {
    private let suite = "test.p2character"
    private var saved: UserDefaults!

    override func setUp() {
        saved = AppDefaults.store
        AppDefaults.store = UserDefaults(suiteName: suite)!
        AppDefaults.store.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        AppDefaults.store.removePersistentDomain(forName: suite)
        AppDefaults.store = saved
    }

    private var base: SpriteLook { SpriteLook(AppSettings.shared) }

    func testPickIsSavedAndReadBack() {
        XCTAssertEqual(P2Character.pick, "")
        P2Character.pick = "dog:shiba"
        XCTAssertEqual(AppDefaults.store.string(forKey: "play.p2Character"), "dog:shiba")
        XCTAssertEqual(P2Character.pick, "dog:shiba")
        P2Character.pick = ""
        XCTAssertEqual(P2Character.pick, "")
    }

    func testNothingPickedIsP1Tinted() {
        XCTAssertNil(P2Character.resolve("", p1: base, base: base))
    }

    func testAGoneOrUnknownPickFallsBackToP1() {
        for gone in ["dog:no-such-breed", "cat:no-such-cat", "original:a-removed-pack", "custom:\(UUID().uuidString)", "nonsense", "dog"] {
            XCTAssertNil(P2Character.resolve(gone, p1: base, base: base), gone)
        }
    }

    func testAnotherCharacterIsWornPlain() throws {
        var p1 = base
        p1.character = .dog
        p1.profile = DogProfile.presets[0].profile
        let look = try XCTUnwrap(P2Character.resolve("dog:shiba", p1: p1, base: base))
        XCTAssertEqual(look.character, .dog)
        XCTAssertEqual(P2Character.pick(of: look), "dog:shiba")
        let cat = try XCTUnwrap(CatCatalog.all.first)
        let catLook = try XCTUnwrap(P2Character.resolve("cat:\(cat.id)", p1: p1, base: base))
        XCTAssertEqual(catLook.character, .cat)
        XCTAssertEqual(catLook.readyID, cat.id)
        let original = try XCTUnwrap(OriginalCatalog.all.first)
        XCTAssertEqual(P2Character.resolve("original:\(original.id)", p1: p1, base: base)?.readyID, original.id)
    }

    func testTheSameCharacterAsP1IsTinted() throws {
        let p1 = try XCTUnwrap(P2Character.look("dog:shiba", base: base))
        XCTAssertNil(P2Character.resolve("dog:shiba", p1: p1, base: base))
        let original = try XCTUnwrap(OriginalCatalog.all.first)
        let o1 = try XCTUnwrap(P2Character.look("original:\(original.id)", base: base))
        XCTAssertNil(P2Character.resolve("original:\(original.id)", p1: o1, base: base))
    }

    func testChoicesListEveryKindOnceWithSameFirst() {
        let ids = P2Character.choices().map(\.id)
        XCTAssertEqual(ids.first, "")
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("dog:jelly"))
        XCTAssertTrue(ids.contains { $0.hasPrefix("cat:") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("original:") })
        for id in ids.dropFirst() { XCTAssertNotNil(P2Character.look(id, base: base), id) }
    }
}
