import CryptoKit
import XCTest
@testable import DogMonitor

final class SponsorTests: XCTestCase {
    private let seller = Curve25519.Signing.PrivateKey()
    private var pub: [UInt8] { Array(seller.publicKey.rawRepresentation) }
    private let suite = "test.sponsor.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data((try (key ?? seller).signature(for: data).base64EncodedString() + "\n").utf8)
    }

    private func card(_ id: String = "wayhome", url: String = "https://wayhomeguide.co.kr", color: String = "#B04238",
                      title: String = "길잡이", en: String = "Guide") -> [String: Any] {
        ["id": id, "emoji": "🏠", "color": color, "url": url,
         "title": ["ko": title, "en": en], "pitch": ["ko": "두 줄 소개", "en": "Two lines"], "cta": ["ko": "구경하기", "en": "Look"]]
    }

    private func json(serial: Int = 2, enabled: Bool = true, maxPerDay: Int = 2, minHours: Double = 3,
                      hosts: [String] = ["wayhomeguide.co.kr", "example.com"], cards: [[String: Any]]? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["serial": serial, "enabled": enabled, "maxPerDay": maxPerDay,
                                                     "minHoursBetween": minHours, "hosts": hosts, "cards": cards ?? [card()]])
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// A list fetched from the site just now.
    private var manifest: SponsorManifest {
        var m = try! SponsorCheck.parse(json()).manifest
        m.fetchedAt = t0
        return m
    }

    /// Past the first two days, nothing in the way.
    private func ready(_ now: Date) -> SponsorState {
        var s = SponsorState()
        s.firstSeen = now - 3 * 86_400
        return s
    }

    // MARK: Manifest

    func testSignedManifestVerifies() throws {
        let data = json()
        let (m, rejected) = try SponsorCheck.verify(data, signature: try sign(data), publicKey: pub)
        XCTAssertEqual(m.serial, 2)
        XCTAssertTrue(m.enabled)
        XCTAssertEqual(m.cards.map(\.id), ["wayhome"])
        XCTAssertEqual(rejected, 0)
    }

    func testTamperedUnsignedForeignKeyAndShippedKeyAreRejected() throws {
        let data = json()
        var tampered = data
        tampered[tampered.count - 3] ^= 1
        XCTAssertThrowsError(try SponsorCheck.verify(tampered, signature: try sign(data), publicKey: pub)) {
            XCTAssertEqual($0 as? SponsorCheck.Failure, .badSignature)
        }
        XCTAssertThrowsError(try SponsorCheck.verify(data, signature: Data(), publicKey: pub))
        XCTAssertThrowsError(try SponsorCheck.verify(data, signature: try sign(data, with: Curve25519.Signing.PrivateKey()), publicKey: pub))
        // The app's own key never takes a file signed with a test key.
        XCTAssertThrowsError(try SponsorCheck.verify(data, signature: try sign(data))) {
            XCTAssertEqual($0 as? SponsorCheck.Failure, .badSignature)
        }
    }

    func testOversizeAndRollbackAreRejected() throws {
        let big = json(cards: [card(title: String(repeating: "가", count: 30_000))])
        XCTAssertGreaterThan(big.count, SponsorCheck.maxBytes)
        XCTAssertThrowsError(try SponsorCheck.verify(big, signature: try sign(big), publicKey: pub)) {
            XCTAssertEqual($0 as? SponsorCheck.Failure, .tooBig)
        }
        let old = json(serial: 1)
        XCTAssertThrowsError(try SponsorCheck.verify(old, signature: try sign(old), publicKey: pub, minSerial: 2)) {
            XCTAssertEqual($0 as? SponsorCheck.Failure, .rollback)
        }
        XCTAssertNoThrow(try SponsorCheck.verify(old, signature: try sign(old), publicKey: pub, minSerial: 1))
        let hosts = json(hosts: (0..<21).map { "h\($0).com" })
        XCTAssertThrowsError(try SponsorCheck.verify(hosts, signature: try sign(hosts), publicKey: pub))
    }

    func testBadCardsAreDroppedOneByOne() throws {
        var missingEn = card("missing")
        missingEn["title"] = ["ko": "제목"]
        let cards = [card("good"), card("http", url: "http://wayhomeguide.co.kr"), card("foreign", url: "https://evil.com"),
                     card("port", url: "https://wayhomeguide.co.kr:8443"), card("login", url: "https://a@wayhomeguide.co.kr"),
                     card("Bad_ID"), card("color", color: "red"), card("long", title: String(repeating: "가", count: 41)),
                     card("blank", en: "  "), missingEn, card("good"), card("also-good", url: "https://EXAMPLE.com/page")]
        let (m, rejected) = try SponsorCheck.parse(json(cards: cards))
        XCTAssertEqual(m.cards.map(\.id), ["good", "also-good"])
        XCTAssertEqual(rejected, cards.count - 2)
    }

    func testLimitsAreClamped() throws {
        let m = try SponsorCheck.parse(json(maxPerDay: 9, minHours: 0.1)).manifest
        XCTAssertEqual(m.maxPerDay, 2)
        XCTAssertEqual(m.minHoursBetween, 1)
        let n = try SponsorCheck.parse(json(maxPerDay: -3, minHours: 900)).manifest
        XCTAssertEqual(n.maxPerDay, 0)
        XCTAssertEqual(n.minHoursBetween, 168)
    }

    func testShippedListIsValidAndMatchesTheBuiltInOne() throws {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../web/sponsors.json")
        let (m, rejected) = try SponsorCheck.parse(try Data(contentsOf: web))
        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(m.cards.count, 6)
        XCTAssertEqual(m, SponsorManifest.bundled)
        XCTAssertTrue(m.enabled)
        for c in m.cards {
            XCTAssertNotNil(SponsorRules.link(c, hosts: m.hosts), c.id)
            for text in [c.title.ko, c.title.en, c.pitch.ko, c.pitch.en, c.cta.ko, c.cta.en] { XCTAssertFalse(text.contains("\u{2014}"), c.id) }
        }
        // The signature next to it, when there is one, is the release key's over these bytes.
        let sig = web.appendingPathExtension("sig")
        if let s = try? Data(contentsOf: sig) { XCTAssertNoThrow(try SponsorCheck.verify(try Data(contentsOf: web), signature: s)) }
    }

    func testCachedListBeatsTheBuiltInOneAndItsKillSwitchHolds() throws {
        XCTAssertEqual(SponsorManifest.load(defaults, publicKey: pub), SponsorManifest.bundled)
        let off = json(serial: 5, enabled: false)
        defaults.set(off, forKey: SponsorCenter.manifestKey)
        defaults.set(try sign(off), forKey: SponsorCenter.signatureKey)
        let m = SponsorManifest.load(defaults, publicKey: pub)
        XCTAssertFalse(m.enabled)
        XCTAssertFalse(SponsorRules.canOffer(ready(t0), m, SponsorEnv(), now: t0))
        // A cache that no longer verifies is not used.
        defaults.set(try sign(json()), forKey: SponsorCenter.signatureKey)
        XCTAssertEqual(SponsorManifest.load(defaults, publicKey: pub), SponsorManifest.bundled)
    }

    func testAKillSwitchNeedsOnlySerialAndEnabled() throws {
        let off = Data(#"{"serial":2,"enabled":false}"#.utf8)
        let m = try SponsorCheck.verify(off, signature: try sign(off), publicKey: pub).manifest
        XCTAssertFalse(m.enabled)
        XCTAssertEqual(m.serial, 2)
        XCTAssertTrue(m.cards.isEmpty)
        XCTAssertThrowsError(try SponsorCheck.parse(Data(#"{"enabled":false}"#.utf8)))
    }

    func testTheHigherSerialWinsBetweenCacheAndBuiltIn() throws {
        let on = json(serial: 1)
        defaults.set(on, forKey: SponsorCenter.manifestKey)
        defaults.set(try sign(on), forKey: SponsorCenter.signatureKey)
        defaults.set(t0, forKey: SponsorCenter.fetchedKey)
        var builtInOff = try SponsorCheck.parse(Data(#"{"serial":2,"enabled":false}"#.utf8)).manifest
        XCTAssertEqual(SponsorManifest.load(defaults, publicKey: pub, bundled: builtInOff), builtInOff)
        builtInOff.serial = 1
        let cached = SponsorManifest.load(defaults, publicKey: pub, bundled: builtInOff)
        XCTAssertTrue(cached.enabled)
        XCTAssertEqual(cached.fetchedAt, t0)
    }

    func testAutomaticOffersNeedARecentlyFetchedList() {
        var m = manifest
        let s = ready(t0)
        m.fetchedAt = nil   // the built-in list, or nothing fetched yet
        XCTAssertFalse(SponsorRules.canOffer(s, m, SponsorEnv(), now: t0))
        m.fetchedAt = t0 - 13 * 86_400
        XCTAssertTrue(SponsorRules.canOffer(s, m, SponsorEnv(), now: t0))
        m.fetchedAt = t0 - 15 * 86_400
        XCTAssertFalse(SponsorRules.canOffer(s, m, SponsorEnv(), now: t0))
        XCTAssertFalse(SponsorRules.fetched(m, within: SponsorRules.staleFor, now: t0))
    }

    // MARK: Rules

    func testFirstTwoDaysAreQuiet() {
        var s = SponsorState()
        XCTAssertFalse(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0))   // never started
        s.firstSeen = t0 - 86_400
        XCTAssertFalse(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0))
        s.firstSeen = t0 - 2 * 86_400
        XCTAssertTrue(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0))
    }

    func testEverythingAroundTheMacKeepsItAway() {
        let s = ready(t0)
        XCTAssertTrue(SponsorRules.canOffer(s, manifest, SponsorEnv(idle: 120), now: t0))
        let blocked: [SponsorEnv] = [SponsorEnv(fullScreen: true), SponsorEnv(focusRunning: true), SponsorEnv(playing: true),
                                     SponsorEnv(asleep: true), SponsorEnv(idle: 121), SponsorEnv(muted: true),
                                     SponsorEnv(popoverOpen: true), SponsorEnv(busy: true)]
        for e in blocked { XCTAssertFalse(SponsorRules.canOffer(s, manifest, e, now: t0), "\(e)") }
        var off = s
        off.on = false
        XCTAssertFalse(SponsorRules.canOffer(off, manifest, SponsorEnv(), now: t0))
    }

    func testStopTodayBlocksOnlyToday() {
        var s = ready(t0)
        s.stop(now: t0)
        XCTAssertFalse(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0 + 60))
        XCTAssertTrue(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0 + 86_400))
        XCTAssertEqual(s.backoff, 0)
    }

    func testCapsAndGaps() {
        var s = ready(t0)
        let m = manifest
        XCTAssertEqual(SponsorRules.cap(s, m), 2)
        XCTAssertEqual(SponsorRules.gap(s, m), 3 * 3600)
        s.frequency = .sometimes
        XCTAssertEqual(SponsorRules.cap(s, m), 1)
        XCTAssertEqual(SponsorRules.gap(s, m), 6 * 3600)
        s.frequency = .normal
        s.backoff = 1
        XCTAssertEqual(SponsorRules.cap(s, m), 1)
        XCTAssertEqual(SponsorRules.gap(s, m), 6 * 3600)
        s.backoff = 2
        XCTAssertEqual(SponsorRules.gap(s, m), 12 * 3600)
        s.backoff = 5
        XCTAssertEqual(SponsorRules.gap(s, m), 96 * 3600)
        var strict = m
        strict.maxPerDay = 0
        XCTAssertEqual(SponsorRules.cap(ready(t0), strict), 0)
    }

    func testTwoADayAtMostWithTheGapBetween() {
        var s = SponsorRules.rolled(ready(t0), now: t0)   // as SponsorCenter does before counting
        let m = manifest, e = SponsorEnv()
        s.offered("wayhome", now: t0, automatic: true)
        XCTAssertFalse(SponsorRules.canOffer(s, m, e, now: t0 + 3600))
        XCTAssertTrue(SponsorRules.canOffer(s, m, e, now: t0 + 3 * 3600))
        s.offered("wayhome", now: t0 + 3 * 3600, automatic: true)
        XCTAssertFalse(SponsorRules.canOffer(s, m, e, now: t0 + 4 * 3600))   // two today (still the same day in Seoul and UTC)
    }

    func testANewDayStartsTheCountersOver() {
        var s = ready(t0)
        s = SponsorRules.rolled(s, now: t0)
        s.offersToday = 2
        s.rewardsToday = 2
        let same = SponsorRules.rolled(s, now: t0 + 60)
        XCTAssertEqual(same.offersToday, 2)
        let next = SponsorRules.rolled(s, now: t0 + 86_400)
        XCTAssertEqual(next.offersToday, 0)
        XCTAssertEqual(next.rewardsToday, 0)
        XCTAssertNotEqual(next.day, s.day)
    }

    func testAClockSetBackKeepsTheDaysCounters() {
        var s = SponsorRules.rolled(ready(t0), now: t0)
        s.offersToday = 2
        s.rewardsToday = 2
        let back = SponsorRules.rolled(s, now: t0 - 3 * 86_400)
        XCTAssertEqual(back.day, s.day)
        XCTAssertEqual(back.rewardsToday, 2)
        let forward = SponsorRules.rolled(back, now: t0 + 86_400)
        XCTAssertEqual(forward.rewardsToday, 0)
        XCTAssertEqual(SponsorRules.rolled(forward, now: t0).rewardsToday, 0)   // and back again: still that later day
    }

    func testFullScreenOnNotchedAndPlainScreens() {
        let s = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertTrue(SponsorCenter.covers(s, screen: s, notch: 0))
        XCTAssertTrue(SponsorCenter.covers(CGRect(x: 0, y: 0, width: 1512, height: 950), screen: s, notch: 32))   // under the notch
        XCTAssertFalse(SponsorCenter.covers(CGRect(x: 0, y: 0, width: 1512, height: 950), screen: s, notch: 0))
        XCTAssertFalse(SponsorCenter.covers(CGRect(x: 0, y: 70, width: 1512, height: 880), screen: s, notch: 32))  // above the Dock
        XCTAssertFalse(SponsorCenter.covers(CGRect(x: 0, y: 0, width: 1200, height: 982), screen: s, notch: 32))
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(SponsorCenter.covers(second, screen: second, notch: 0))
        XCTAssertFalse(SponsorCenter.covers(s, screen: second, notch: 0))
    }

    func testAnOpenCardStopsWhenLeftAlone() {
        XCTAssertFalse(SponsorRules.cardTimedOut(open: 30, paused: 0))
        XCTAssertFalse(SponsorRules.cardTimedOut(open: 200, paused: 119))
        XCTAssertTrue(SponsorRules.cardTimedOut(open: 200, paused: 120))
        XCTAssertTrue(SponsorRules.cardTimedOut(open: 300, paused: 0))
        XCTAssertLessThanOrEqual(SponsorCenter.watchingIdle, 20)
    }

    func testThreeIgnoredSlowItDownAndOpeningForgets() {
        var s = SponsorState()
        s.ignored(); s.ignored()
        XCTAssertEqual(s.backoff, 0)
        s.ignored()
        XCTAssertEqual(s.backoff, 1)
        XCTAssertEqual(s.ignoredStreak, 0)
        for _ in 0..<30 { s.ignored() }
        XCTAssertEqual(s.backoff, SponsorRules.maxBackoff)
        s.opened()
        XCTAssertEqual(s.backoff, 0)
        XCTAssertEqual(s.ignoredStreak, 0)
        XCTAssertEqual(s.stats.opens, 1)
    }

    func testShowNowCountsOnlyInTheTotals() {
        var s = ready(t0)
        s.offered("wayhome", now: t0, automatic: false)
        XCTAssertEqual(s.offersToday, 0)
        XCTAssertNil(s.lastOfferAt)
        XCTAssertEqual(s.stats.offers, 1)
        XCTAssertEqual(s.lastShown["wayhome"], t0)
        XCTAssertTrue(SponsorRules.canOffer(s, manifest, SponsorEnv(), now: t0))
    }

    func testRewardsStopAtTwoADayAndAfterAllEight() {
        let gifts = SponsorGifts(defaults: defaults, allOpen: false)
        var s = SponsorRules.rolled(SponsorState(), now: t0)
        XCTAssertEqual(s.completed { gifts.unlock() }.gift, .rugHearts)
        XCTAssertEqual(s.completed { gifts.unlock() }.gift, .peach)
        let third = s.completed { gifts.unlock() }
        XCTAssertNil(third.gift)
        XCTAssertTrue(third.capped)
        XCTAssertEqual(s.stats.completes, 3)
        XCTAssertEqual(gifts.openCount, 2)
        for _ in 0..<6 { gifts.unlock() }
        XCTAssertNil(gifts.next)
        s = SponsorRules.rolled(s, now: t0 + 86_400)
        let after = s.completed { gifts.unlock() }
        XCTAssertNil(after.gift)
        XCTAssertFalse(after.capped)
    }

    func testStateSurvivesASaveAndOddFields() throws {
        var s = ready(t0)
        s.frequency = .sometimes
        s.backoff = 3
        s.lastShown = ["offer": t0]
        s.stats.clicks = 4
        XCTAssertEqual(try JSONDecoder().decode(SponsorState.self, from: try JSONEncoder().encode(s)), s)
        let odd = Data(#"{"on":false,"frequency":"wild","backoff":99,"stats":"x"}"#.utf8)
        let d = try JSONDecoder().decode(SponsorState.self, from: odd)
        XCTAssertFalse(d.on)
        XCTAssertEqual(d.frequency, .normal)
        XCTAssertEqual(d.backoff, SponsorRules.maxBackoff)
        XCTAssertEqual(d.stats, SponsorStats())
    }

    // MARK: Pick, link, ink

    func testPickTakesUnseenFirstThenTheOldest() throws {
        let cards = try SponsorCheck.parse(json(cards: [card("a"), card("b"), card("c")])).manifest.cards
        XCTAssertEqual(SponsorRules.pick(cards, lastShown: [:])?.id, "a")
        XCTAssertEqual(SponsorRules.pick(cards, lastShown: ["a": t0])?.id, "b")
        XCTAssertEqual(SponsorRules.pick(cards, lastShown: ["a": t0, "b": t0 - 10, "c": t0 - 5])?.id, "b")
        XCTAssertEqual(SponsorRules.pick(cards, lastShown: ["a": t0, "b": t0, "c": t0])?.id, "a")
        XCTAssertNil(SponsorRules.pick([], lastShown: [:]))
    }

    func testLinkCarriesWhereItCameFrom() throws {
        let c = try SponsorCheck.parse(json(cards: [card("offer", url: "https://example.com/p?x=1&utm_source=old&UTM_Medium=m")])).manifest.cards[0]
        let url = try XCTUnwrap(SponsorRules.link(c, hosts: ["example.com"]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["x", "utm_source", "utm_medium", "utm_campaign"])
        XCTAssertEqual(items.map(\.value), ["1", "charamonitor", "sponsor_friend", "offer"])
        XCTAssertEqual(url.host, "example.com")
        XCTAssertNil(SponsorRules.link(c, hosts: ["wayhomeguide.co.kr"]))
    }

    func testInkReadsOnEveryColour() {
        XCTAssertEqual(SponsorRules.ink(on: "#3E3166"), "#FFFFFF")
        XCTAssertEqual(SponsorRules.ink(on: "#FFF4C7"), "#1E1E1E")
        XCTAssertEqual(SponsorRules.contrast("#000000", "#FFFFFF"), 21, accuracy: 0.01)
        for c in SponsorManifest.bundled.cards {
            XCTAssertGreaterThanOrEqual(SponsorRules.contrast(c.color, SponsorRules.ink(on: c.color)), 4.5, c.id)
        }
    }

    func testNewWidgetColoursKeepWhiteTextReadable() {
        for t in FocusTheme.allCases {
            XCTAssertGreaterThanOrEqual(SponsorRules.contrast(t.hexes(dark: false).accent, "#FFFFFF"), 4.5, t.rawValue)
            XCTAssertGreaterThanOrEqual(SponsorRules.contrast(t.hexes(dark: false).fill, t.hexes(dark: false).ink), 4.5, t.rawValue)
            XCTAssertGreaterThanOrEqual(SponsorRules.contrast(t.hexes(dark: true).fill, t.hexes(dark: true).ink), 4.5, t.rawValue)
        }
    }

    // MARK: Carrier

    func testOnlyBuiltInCharactersCarryTheFrame() throws {
        let s = AppSettings(defaults: defaults)
        s.character = .dog
        XCTAssertTrue(SponsorCarrier.buddyMayCarry(s))
        if let cat = CatCatalog.all.first { s.useCat(cat.id); XCTAssertTrue(SponsorCarrier.buddyMayCarry(s)) }
        let builtIn = try XCTUnwrap(OriginalCharacterSet2.all.first)
        s.useOriginal(builtIn.id)
        XCTAssertTrue(SponsorCarrier.buddyMayCarry(s))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sponsor-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try CharacterPack(folder: try makePack(in: root))
        let saved = OriginalCatalog.all
        defer { OriginalCatalog.all = saved }
        OriginalCatalog.all += [pack]
        s.useOriginal(pack.id)
        XCTAssertEqual(s.shownCharacter, .original)
        XCTAssertFalse(SponsorCarrier.buddyMayCarry(s))

        s.character = .custom
        s.customCharacterID = UUID().uuidString   // unknown: it shows the dog, which may carry
        XCTAssertTrue(SponsorCarrier.buddyMayCarry(s))
    }

    /// A minimal local pack (frames are small boxes), as CharacterPackTests makes them.
    private func makePack(in root: URL) throws -> URL {
        let dir = root.appendingPathComponent("pack-sponsor-test", isDirectory: true), frames = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let counts = ["lying": 1, "slowWalk": 2, "walk": 4, "fastWalk": 2, "run": 2, "sprint": 2, "exhausted": 2, "special": 2]
        let json: [String: Any] = ["version": 1, "id": "pack-sponsor-test", "name": "팩", "special": "특기", "blurb": "한 줄", "frames": counts]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("pack.json"))
        let ctx = DogRenderer.context(width: 68, height: 40)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 0, width: 28, height: 24))
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        for (key, n) in counts { for i in 0..<n { try png.write(to: frames.appendingPathComponent("\(key)-\(i).png")) } }
        return dir
    }

    // MARK: Gifts

    func testGiftsOpenInOrderAndIgnoreUnknownIds() throws {
        XCTAssertEqual(SponsorGift.allCases, [.rugHearts, .peach, .cloud, .party, .ribbon, .rugStars, .cocoa, .rugRainbow])
        XCTAssertEqual(Set(SponsorGift.allCases.map(\.rawValue)).count, SponsorGift.allCases.count)
        defaults.set(try JSONEncoder().encode(["cloud", "nope", "rugHearts"]), forKey: SponsorGifts.key)
        let g = SponsorGifts(defaults: defaults, allOpen: false)
        XCTAssertEqual(g.unlocked, [.rugHearts, .cloud])
        XCTAssertEqual(g.next, .peach)
        XCTAssertEqual(g.unlock(), .peach)
        XCTAssertEqual(SponsorGifts(defaults: defaults, allOpen: false).unlocked, [.rugHearts, .peach, .cloud])
        XCTAssertEqual(SponsorGifts.decode(Data("garbage".utf8)), [])
    }

    func testTheAppStoreBuildHasEveryGiftOpen() {
        let g = SponsorGifts(defaults: defaults, allOpen: true)
        XCTAssertTrue(SponsorGift.allCases.allSatisfy(g.isOpen))
        XCTAssertNil(g.next)
        XCTAssertNil(g.unlock())
    }

    func testPickersHideLockedGiftsButKeepTheCurrentOne() {
        // SponsorGifts.shared reads the test run's defaults, where nothing is unlocked.
        guard !SponsorGifts.shared.isOpen(.rugStars) else { return }
        XCTAssertFalse(RugFace.offered(current: .character).contains(.stars))
        XCTAssertTrue(RugFace.offered(current: .stars).contains(.stars))
        XCTAssertTrue(RugFace.offered(current: nil).contains(.dots))
        XCTAssertFalse(FocusTheme.offered(current: .mint).contains(.cocoa))
        XCTAssertFalse(ToyKind.cloud.isOffered || SponsorGifts.shared.isOpen(.cloud))
        XCTAssertEqual(FolderIconStyle.offered(current: .ribbon).last, .ribbon)
        XCTAssertNil(RugFace.dots.gift)
        XCTAssertEqual(FocusTheme.peach.gift, .peach)
    }

    // MARK: The new pieces

    func testPartyLiftsSpinsAndSettles() {
        let r = Reaction.party
        XCTAssertGreaterThan(r.pose(0.25, still: false).lift, 0.3)
        XCTAssertNotEqual(r.pose(0.25, still: false).angle, 0)
        XCTAssertTrue(r.spins)
        let end = r.pose(r.duration, still: false)
        XCTAssertEqual(end.lift, 0); XCTAssertEqual(end.angle, 0)
        XCTAssertEqual(r.pose(0.25, still: true).lift, 0)
        XCTAssertFalse(Reaction.cute.contains(.party))
        var combo = ClickCombo()
        XCTAssertEqual(combo.click(at: 0) { $0.contains(.party) ? .party : .hearts }, SponsorGifts.shared.isOpen(.party) ? .party : .hearts)
    }

    func testCloudCushionIsACushion() {
        let f = CGRect(x: 100, y: 0, width: ToyKind.cloud.size.width, height: ToyKind.cloud.size.height)
        let stand = ToyKind.cloud.stand(in: f)
        XCTAssertNotNil(stand)
        XCTAssertEqual(ToyKind.cloud.spot(in: f, width: 40, fromX: 0).y, stand?.maxY)
        XCTAssertGreaterThan(ToyPhysics.cushion(fall: -900), 0)
    }

    func testEveryRugFaceDraws() throws {
        for face in RugFace.allCases {
            let image = RugArt.front(face, color: .peach, character: nil)
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), face.rawValue)
            XCTAssertGreaterThan(rep.pixelsWide, 0, face.rawValue)
            let mid = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
            XCTAssertGreaterThan(mid?.alphaComponent ?? 0, 0.5, face.rawValue)
        }
    }

    func testRibbonFolderDrawsTheBand() throws {
        let folder = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }
        let who = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in NSColor.black.setFill(); r.fill(); return true }
        let plain = FolderIcons.art(folder: folder, character: who, smooth: false, style: .stand)
        let ribbon = FolderIcons.art(folder: folder, character: who, smooth: false, style: .ribbon)
        func pixel(_ i: NSImage) -> NSColor? {
            let rep = i.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            return rep.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: $0.pixelsHigh * 3 / 4) }   // the front panel's middle, low down
        }
        XCTAssertNotEqual(pixel(plain), pixel(ribbon))
    }

    func testSetupFileCarriesTheGiftsButNotTheCounters() throws {
        let data = try JSONEncoder().encode(["peach"])
        XCTAssertEqual(Set(SetupFile.filter(["sponsor.gifts": data, "sponsor.state": data, "sponsor.manifest": data]).keys), ["sponsor.gifts"])
        XCTAssertNil(SetupFile.keys["sponsor.state"])
        XCTAssertNil(SetupFile.keys["sponsor.manifestSig"])
        XCTAssertNil(SetupFile.keys["sponsor.fetchedAt"])
        SponsorGifts(defaults: defaults, allOpen: false).unlock()
        let snap = SetupFile.snapshot(defaults)
        let carried = try XCTUnwrap(snap["sponsor.gifts"] as? Data)
        XCTAssertEqual(SponsorGifts.decode(carried), [.rugHearts])
    }

    func testAPaidCardIsMarkedAndOldCardsAreNot() throws {
        var paid = card("acme"); paid["paid"] = true
        let m = try SponsorCheck.parse(json(cards: [card(), paid])).manifest
        XCTAssertEqual(m.cards.map(\.paid), [nil, true])
    }
}
