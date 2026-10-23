import CryptoKit
import XCTest
@testable import DogMonitor

final class PluginTests: XCTestCase {
    private let seller = Curve25519.Signing.PrivateKey()
    private var pub: [UInt8] { Array(seller.publicKey.rawRepresentation) }
    private let suite = "test.plugins.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() { defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func sign(_ data: Data) throws -> Data { Data((try seller.signature(for: data).base64EncodedString() + "\n").utf8) }

    private func json(serial: Int = 2, handle: String = "0won.made", url: String? = "https://www.instagram.com/0won.made/",
                      plugins: [[String: Any]]) -> Data {
        var insta: [String: Any] = ["handle": handle]
        if let url { insta["url"] = url }
        return try! JSONSerialization.data(withJSONObject: ["serial": serial, "instagram": insta, "plugins": plugins])
    }

    private func entry(_ id: String, _ day: String, code: String? = nil, post: Any = NSNull()) -> [String: Any] {
        ["id": id, "release": day, "code": code.map { PluginRules.hash(PluginID(rawValue: id)!, $0) } ?? NSNull(), "post": post]
    }

    private func manifest(_ releases: [PluginID: PluginRelease], serial: Int = 1) -> PluginManifest {
        PluginManifest(serial: serial, handle: "0won.made", profile: URL(string: "https://www.instagram.com/0won.made/")!, releases: releases)
    }

    // MARK: Codes

    func testCodesAreNormalizedAndHashedPerPlugin() {
        XCTAssertEqual(PluginRules.normalized(" fly7-k2qz\n"), "FLY7K2QZ")
        XCTAssertEqual(PluginRules.normalized("가나 ß!"), "SS")
        XCTAssertEqual(PluginRules.hash(.wardrobe, "abcd 2345"), PluginRules.hash(.wardrobe, "ABCD2345"))
        XCTAssertNotEqual(PluginRules.hash(.wardrobe, "ABCD2345"), PluginRules.hash(.nearby, "ABCD2345"))
        let expected = SHA256.hash(data: Data("charamonitor-plugin:wardrobe:ABCD2345".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(PluginRules.hash(.wardrobe, "abcd2345"), expected)
        XCTAssertEqual(expected.count, 64)
    }

    func testACodeOpensOnlyItsOwnPlugin() {
        let m = manifest([.wardrobe: PluginRelease(day: "2099-01-01", codeHash: PluginRules.hash(.wardrobe, "WEAR2345")),
                          .nearby: PluginRelease(day: "2099-01-01", codeHash: nil)])
        XCTAssertEqual(PluginRules.match("wear-2345", m), .wardrobe)
        XCTAssertNil(PluginRules.match("WEAR2346", m))
        XCTAssertNil(PluginRules.match("", m))
        XCTAssertNil(PluginRules.match("!!!", m))
    }

    // MARK: Open rule

    func testInstalledAlwaysOpenNewOnesByDayOrCode() {
        let m = manifest([.wardrobe: PluginRelease(day: "2026-11-06")])
        for id in PluginID.allCases where id.isInstalled {
            XCTAssertTrue(PluginRules.isOpen(id, today: "2000-01-01", manifest: m, unlocked: []), id.rawValue)
        }
        XCTAssertFalse(PluginRules.isOpen(.wardrobe, today: "2026-11-05", manifest: m, unlocked: []))
        XCTAssertTrue(PluginRules.isOpen(.wardrobe, today: "2026-11-06", manifest: m, unlocked: []))
        XCTAssertTrue(PluginRules.isOpen(.wardrobe, today: "2027-01-01", manifest: m, unlocked: []))
        XCTAssertTrue(PluginRules.isOpen(.wardrobe, today: "2026-11-01", manifest: m, unlocked: [.wardrobe]))
        // No entry: closed until a code (a list that leaves one out keeps the built-in day: testStoredListMergesOverBundled).
        XCTAssertFalse(PluginRules.isOpen(.office, today: "2099-01-01", manifest: m, unlocked: []))
    }

    func testDayIsTheLocalCalendarDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let d = Date(timeIntervalSince1970: 1_793_890_800)   // 2026-11-05T15:00:00Z = 11/6 00:00 in Seoul
        XCTAssertEqual(PluginRules.day(d, calendar: cal), "2026-11-06")
    }

    func testFiveTriesAMinute() {
        let t0 = Date()
        var tries: [Date] = []
        for i in 0..<5 {
            let r = PluginRules.recent(tries, now: t0 + Double(i))
            XCTAssertTrue(r.mayTry)
            tries = r.kept + [t0 + Double(i)]
        }
        XCTAssertFalse(PluginRules.recent(tries, now: t0 + 10).mayTry)
        XCTAssertTrue(PluginRules.recent(tries, now: t0 + 60.5).mayTry)
    }

    // MARK: The list

    func testParseDropsBadEntriesAndLinks() throws {
        let m = try PluginCheck.parse(json(plugins: [
            entry("wardrobe", "2026-11-06", code: "WEAR2345", post: "https://www.instagram.com/p/abc/"),
            entry("nearby", "11/13"),                                        // bad day: dropped
            entry("cursor", "2026-11-06"),                                   // installed: ignored
            entry("teleport", "2026-11-06"),                                 // unknown: ignored
            ["id": "office", "release": "2026-12-04", "code": "NOTHEX", "post": "https://evil.example/p/1"],
            ["id": "netPlay", "release": 7],                                 // wrong type: only it is dropped
        ]))
        XCTAssertEqual(Set(m.releases.keys), [.wardrobe, .office])
        XCTAssertEqual(m.releases[.wardrobe]?.post?.absoluteString, "https://www.instagram.com/p/abc/")
        XCTAssertNotNil(m.releases[.wardrobe]?.codeHash)
        XCTAssertNil(m.releases[.office]?.codeHash)
        XCTAssertNil(m.releases[.office]?.post)
    }

    func testInstagramLinksAndHandle() throws {
        XCTAssertNotNil(PluginCheck.instagram("https://instagram.com/0won.made"))
        XCTAssertNil(PluginCheck.instagram("http://www.instagram.com/0won.made"))
        XCTAssertNil(PluginCheck.instagram("https://www.instagram.com.evil.example/"))
        XCTAssertNil(PluginCheck.instagram("https://user@www.instagram.com/"))
        XCTAssertNil(PluginCheck.instagram("https://www.instagram.com:444/"))
        XCTAssertThrowsError(try PluginCheck.parse(json(handle: "bad handle!", plugins: [])))
        // A bad profile link falls back to the handle's page.
        let m = try PluginCheck.parse(json(url: "https://example.com/", plugins: []))
        XCTAssertEqual(m.profile.absoluteString, "https://www.instagram.com/0won.made/")
    }

    func testSignatureSizeAndRollback() throws {
        let data = json(serial: 3, plugins: [entry("wardrobe", "2026-11-06")])
        XCTAssertEqual(try PluginCheck.verify(data, signature: try sign(data), publicKey: pub).serial, 3)
        XCTAssertThrowsError(try PluginCheck.verify(data + Data(" ".utf8), signature: try sign(data), publicKey: pub))
        XCTAssertThrowsError(try PluginCheck.verify(data, signature: try sign(data)))   // not the release key
        XCTAssertThrowsError(try PluginCheck.verify(data, signature: try sign(data), publicKey: pub, minSerial: 4)) {
            XCTAssertEqual($0 as? PluginCheck.Failure, .rollback)
        }
        let big = Data(repeating: 0x20, count: PluginCheck.maxBytes + 1)
        XCTAssertThrowsError(try PluginCheck.verify(big, signature: try sign(big), publicKey: pub)) {
            XCTAssertEqual($0 as? PluginCheck.Failure, .tooBig)
        }
    }

    func testShippedListIsValidAndMatchesTheBuiltInOne() throws {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../web/plugins.json")
        let data = try Data(contentsOf: web)
        let m = try PluginCheck.parse(data)
        XCTAssertEqual(m, PluginManifest.bundled)
        XCTAssertEqual(m.handle, "0won.made")
        XCTAssertEqual(Set(m.releases.keys), Set(PluginID.drip))
        // One a week, in drip order, each with a code.
        let days = PluginID.drip.compactMap { m.releases[$0]?.day }
        XCTAssertEqual(days, ["2026-10-30", "2026-11-06", "2026-11-13", "2026-11-20", "2026-11-27", "2026-12-04", "2026-12-11"])
        XCTAssertTrue(PluginID.drip.allSatisfy { m.releases[$0]?.codeHash != nil })
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\u{2014}"))
        let sig = web.appendingPathExtension("sig")
        if let s = try? Data(contentsOf: sig) { XCTAssertNoThrow(try PluginCheck.verify(data, signature: s)) }
    }

    // MARK: The center

    func testCenterOpensByCodeOnceAndRemembers() {
        let bundled = manifest([.wardrobe: PluginRelease(day: "2099-01-01", codeHash: PluginRules.hash(.wardrobe, "WEAR2345")),
                                .nearby: PluginRelease(day: "2000-01-01")])
        let c = PluginCenter(defaults: defaults, bundled: bundled)
        XCTAssertTrue(c.open.contains(.nearby))
        XCTAssertFalse(c.open.contains(.wardrobe))
        XCTAssertEqual(c.unlock("nope"), .wrong)
        XCTAssertEqual(c.unlock("wear 2345"), .opened(.wardrobe))
        XCTAssertTrue(c.open.contains(.wardrobe))
        XCTAssertEqual(c.unlock("WEAR2345"), .already(.wardrobe))
        // Saved: a new center (the next launch) still has it, and it never goes into the setup file.
        XCTAssertTrue(PluginCenter(defaults: defaults, bundled: bundled).open.contains(.wardrobe))
        XCTAssertEqual(defaults.stringArray(forKey: PluginCenter.unlockedKey), ["wardrobe"])
    }

    func testCenterLimitsTries() {
        let c = PluginCenter(defaults: defaults, bundled: manifest([:]))
        let t0 = Date()
        for i in 0..<5 { XCTAssertEqual(c.unlock("WRONG000", now: t0 + Double(i)), .wrong) }
        XCTAssertEqual(c.unlock("WRONG000", now: t0 + 6), .wait)
        XCTAssertEqual(c.unlock("WRONG000", now: t0 + 61), .wrong)
    }

    func testMovesAndNetPlayAreOnOnceOpen() {
        _ = PluginCenter(defaults: defaults, bundled: manifest([:]))
        XCTAssertTrue(defaults.bool(forKey: "play.moves"))
        XCTAssertTrue(defaults.bool(forKey: "netplay.on"))
        defaults.set(false, forKey: "play.moves")
        XCTAssertFalse(defaults.bool(forKey: "play.moves"))
    }

    func testStoredListMergesOverBundledAndRollbackKeepsBundled() throws {
        // Only lists signed with the release key are stored, so a test-key list never loads: the bundled one stays.
        let data = json(serial: 9, plugins: [entry("wardrobe", "2000-01-01")])
        defaults.set(data, forKey: PluginCenter.manifestKey)
        defaults.set(try sign(data), forKey: PluginCenter.signatureKey)
        let bundled = manifest([.wardrobe: PluginRelease(day: "2099-01-01"), .office: PluginRelease(day: "2099-02-01")])
        XCTAssertEqual(PluginManifest.load(defaults, bundled: bundled), bundled)
    }

    func testInstalledTilesFindTheirDesktopSwitch() {
        for id in [PluginID.cursor, .clones, .hanging, .meadow, .folder, .rug, .weather] {
            XCTAssertNotNil(id.desktopToggle, id.rawValue)
        }
        XCTAssertEqual(DesktopFriends.toggles.count, 7)
        XCTAssertNil(PluginID.wardrobe.desktopToggle)
    }

    func testTextsHaveNoLongDash() {
        for id in PluginID.allCases { XCTAssertFalse((id.name + id.line).contains("\u{2014}"), id.rawValue) }
        XCTAssertEqual(PluginID.drip.count, 7)
        XCTAssertEqual(Set(PluginID.shown).count, PluginID.shown.count)
    }
}
