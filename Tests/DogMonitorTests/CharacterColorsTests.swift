import XCTest
@testable import DogMonitor

final class CharacterColorsTests: XCTestCase {
    func testBaseTakesThePickedColourAndShadesFollow() {
        let red = RGBColor(hex: "#E02020")
        XCTAssertEqual(CharacterColors.shade("#C27A42", base: "#C27A42", to: red), red, "the base key becomes the pick")
        // A darker shade of the base stays darker after the change.
        let shade = CharacterColors.shade("#8E5428", base: "#C27A42", to: red)
        XCTAssertLessThan(Int(shade.r), Int(red.r))
        XCTAssertGreaterThan(Int(shade.r), Int(shade.g), "still red")
    }

    func testPaletteChangesOnlyThePartsKeys() {
        let parts = CharacterColors.parts(for: "original-tan-cat")
        let base = ["o": "#6E3C24", "F": "#C27A42", "f": "#8E5428", "T": "#22C3B5"]
        let out = CharacterColors.palette(base, parts: parts, choice: ["fur": RGBColor(hex: "#3355FF"), "nope": RGBColor(hex: "#000000")])
        XCTAssertEqual(out["o"], "#6E3C24", "outline untouched")
        XCTAssertEqual(out["T"], "#22C3B5", "other parts untouched")
        XCTAssertEqual(out["F"], "#3355FF")
        XCTAssertNotEqual(out["f"], "#8E5428")
    }

    func testEveryOriginalHasPartsWhoseKeysAreInItsPalette() {
        for c in OriginalCatalog.all {
            let parts = CharacterColors.parts(for: c.id)
            XCTAssertFalse(parts.isEmpty, c.id)
            let palette = (c as? any PaletteCharacter)?.palette ?? [:]
            for part in parts { for key in part.keys { XCTAssertNotNil(palette[key], "\(c.id) \(part.id) \(key)") } }
        }
    }

    func testRecolouredOriginalDrawsTheNewColour() throws {
        let cat = try XCTUnwrap(OriginalCharacterSet2.named("original-tan-cat"))
        let blue = RGBColor(hex: "#2050E0")
        let made = CharacterColors.apply(["fur": blue], to: cat)
        XCTAssertEqual(made.id, cat.id)
        XCTAssertEqual((made as? any PaletteCharacter)?.palette["F"], blue.hex)
        XCTAssertTrue((CharacterColors.apply(["fur": blue], to: cat) as AnyObject) === (made as AnyObject), "kept, not redrawn")
        XCTAssertTrue((CharacterColors.apply(nil, to: cat) as AnyObject) === cat)
    }

    func testSettingsKeepColoursAndTheHiddenList() throws {
        let suite = "test.colors.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.characterColors["original-tan-cat"] = ["cap": RGBColor(hex: "#FF0000")]
        var look = CatProfile.defaultCat
        look.baseColor = RGBColor(hex: "#111111")
        s.catLooks["cat-korean-shorthair"] = look
        s.hiddenCharacters = ["original-tan-cat"]
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.characterColors["original-tan-cat"]?["cap"], RGBColor(hex: "#FF0000"))
        XCTAssertEqual(again.catLooks["cat-korean-shorthair"]?.baseColor, RGBColor(hex: "#111111"))
        XCTAssertEqual(again.hiddenCharacters, ["original-tan-cat"])
    }

    /// A character taken off the list never stays in the menu bar, whatever was stored.
    func testHiddenCharactersFallBackToTheDog() throws {
        let suite = "test.hidden.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        let cat = try XCTUnwrap(CatCatalog.all.first)
        s.useCat(cat.id)
        XCTAssertEqual(s.shownCharacter, .cat)
        s.hiddenCharacters.append(cat.id)
        XCTAssertNil(s.activeCat)
        XCTAssertEqual(s.shownCharacter, .dog)
        s.hiddenCharacters = []
        XCTAssertEqual(s.shownCharacter, .cat, "restored")
    }
}
