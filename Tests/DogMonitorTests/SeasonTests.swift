import CryptoKit
import XCTest
@testable import DogMonitor

final class SeasonTests: XCTestCase {
    private let seller = Curve25519.Signing.PrivateKey()
    private var pub: [UInt8] { Array(seller.publicKey.rawRepresentation) }

    private func sign(_ data: Data) throws -> Data { Data((try seller.signature(for: data).base64EncodedString() + "\n").utf8) }

    private func json(serial: Int = 2, id: String = "test-season", starts: String = "2026-11-01", ends: String = "2026-11-30",
                      cells: Int = 6, items: [String] = ["s-earmuffs", "s-bell", "bubble-snow"], coins: Int = 8, refund: Int = 15,
                      free: Int = 2, price: Int = 40, buy: Int = 3) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "serial": serial,
            "season": ["id": id, "title": ["ko": "테스트", "en": "Test"], "starts": starts, "ends": ends, "cells": cells, "items": items,
                       "coins": coins, "refund": refund, "freePerDay": free, "ticketPrice": price, "buyPerDay": buy, "sponsorTickets": 1],
        ])
    }

    private var m: SeasonManifest { try! SeasonCheck.parse(json()) }
    private let inSeason = "2026-11-10"

    // MARK: The file

    func testShippedFileIsSignedAndMatchesTheBuiltInOne() throws {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../web")
        let data = try Data(contentsOf: web.appendingPathComponent("season.json"))
        let sig = try Data(contentsOf: web.appendingPathComponent("season.json.sig"))
        XCTAssertEqual(try SeasonCheck.verify(data, signature: sig), SeasonManifest.bundled)
        XCTAssertEqual(SeasonManifest.bundled.items.count, 12)
        XCTAssertNotEqual(SeasonManifest.bundled.id, "none")
    }

    func testParseDropsUnknownAndRepeatedItemsAndHoldsNumbers() throws {
        let p = try SeasonCheck.parse(json(cells: 4, items: ["s-bell", "nope", "s-bell", "bubble-pine", "s-snowcap", "s-antlers", "s-earmuffs"],
                                           coins: 999, refund: -5, free: 50, price: 0, buy: 99))
        XCTAssertEqual(p.items, ["s-bell", "bubble-pine", "s-snowcap", "s-antlers"])   // no more items than cells
        XCTAssertEqual([p.coins, p.refund, p.freePerDay, p.ticketPrice, p.buyPerDay], [50, 0, 5, 1, 10])
    }

    func testParseRefusesABadSeason() {
        for bad in [json(id: "Bad Id"), json(starts: "2026-12-01", ends: "2026-11-01"), json(ends: "soon"), json(cells: 3), json(cells: 99),
                    json(items: ["nope"]), Data("{}".utf8), json(serial: -1)] {
            XCTAssertThrowsError(try SeasonCheck.parse(bad))
        }
    }

    func testVerifyNeedsTheKeyTheBytesAndANewEnoughSerial() throws {
        let d = json()
        XCTAssertNoThrow(try SeasonCheck.verify(d, signature: try sign(d), publicKey: pub))
        var tampered = d
        tampered[tampered.count - 3] ^= 1
        XCTAssertThrowsError(try SeasonCheck.verify(tampered, signature: try sign(d), publicKey: pub)) {
            XCTAssertEqual($0 as? SeasonCheck.Failure, .badSignature)
        }
        XCTAssertThrowsError(try SeasonCheck.verify(d, signature: try sign(d), publicKey: pub, minSerial: 3)) {
            XCTAssertEqual($0 as? SeasonCheck.Failure, .rollback)
        }
        let big = Data(repeating: 0x20, count: SeasonCheck.maxBytes + 1)
        XCTAssertThrowsError(try SeasonCheck.verify(big, signature: try sign(big), publicKey: pub)) {
            XCTAssertEqual($0 as? SeasonCheck.Failure, .tooBig)
        }
    }

    func testEverySeasonItemIsDrawnInCode() {
        for id in SeasonCatalog.known {
            let (rows, colors) = SeasonIcon.art(id)
            XCTAssertFalse(rows.isEmpty, id)
            XCTAssertTrue(rows.joined().contains { colors[$0] != nil }, id)
        }
        XCTAssertTrue(Wardrobe.items.filter(\.season).allSatisfy { $0.id.hasPrefix("s-") })
    }

    // MARK: The board

    func testDealPutsEachItemOnceAndIsSeeded() {
        let b = SeasonRules.deal(m, seed: 1)
        XCTAssertEqual(b.cells.count, 6)
        XCTAssertEqual(b.cells.compactMap { $0 }.sorted(), m.items.sorted())
        XCTAssertEqual(b.cells.filter { $0 == nil }.count, 3)
        XCTAssertEqual(b, SeasonRules.deal(m, seed: 1))
    }

    func testOpeningTheWholeBoardGivesEverythingForExactlyItsCells() {
        var s = SeasonState()
        s.tickets = 20
        SeasonRules.ensureBoard(&s, m, seed: 9)
        var coins = 0
        for i in 0..<m.cells { coins += SeasonRules.open(&s, cell: i, m, today: inSeason)?.coins ?? -1000 }
        XCTAssertEqual(Set(s.owned), Set(m.items))
        XCTAssertEqual(s.tickets, 20 - m.cells)
        XCTAssertEqual(coins, 3 * m.coins)
        XCTAssertEqual(s.boardsDone, 1)
        XCTAssertTrue(s.board!.isDone)
        // The next board: everything owned now, so each item pays its refund.
        SeasonRules.ensureBoard(&s, m, seed: 10)
        XCTAssertEqual(s.board!.opened, [])
        let cell = s.board!.cells.firstIndex { $0 != nil }!
        XCTAssertEqual(SeasonRules.open(&s, cell: cell, m, today: inSeason), .duplicate(s.board!.cells[cell]!, coins: m.refund))
    }

    func testOpenNeedsATicketTheSeasonAndAClosedCell() {
        var s = SeasonState()
        SeasonRules.ensureBoard(&s, m, seed: 3)
        XCTAssertNil(SeasonRules.open(&s, cell: 0, m, today: inSeason))   // no 뽑기권
        s.tickets = 2
        XCTAssertNil(SeasonRules.open(&s, cell: 0, m, today: "2026-12-01"))   // over
        XCTAssertNil(SeasonRules.open(&s, cell: 99, m, today: inSeason))
        XCTAssertNotNil(SeasonRules.open(&s, cell: 0, m, today: inSeason))
        XCTAssertNil(SeasonRules.open(&s, cell: 0, m, today: inSeason))   // once
        XCTAssertEqual(s.tickets, 1)
    }

    func testANewSeasonDealsANewBoardAndKeepsWhatIsOwned() {
        var s = SeasonState()
        s.tickets = 1
        SeasonRules.ensureBoard(&s, m, seed: 3)
        _ = SeasonRules.open(&s, cell: 0, m, today: inSeason)
        let owned = s.owned
        var next = m
        next.id = "next-season"
        SeasonRules.ensureBoard(&s, next, seed: 4)
        XCTAssertEqual(s.board!.season, "next-season")
        XCTAssertEqual(s.owned, owned)
    }

    // MARK: 뽑기권

    func testFreeTicketsComeOnceADayInSeasonOnlyAndPileUpToTheCap() {
        var s = SeasonRules.rolled(SeasonState(), m, today: inSeason)
        XCTAssertEqual(s.tickets, 2)
        XCTAssertEqual(SeasonRules.rolled(s, m, today: inSeason), s)
        XCTAssertEqual(SeasonRules.rolled(s, m, today: "2026-11-09").tickets, 2)   // the clock set back pays nothing
        XCTAssertEqual(SeasonRules.rolled(s, m, today: "2026-12-05").tickets, 2)   // after the season: none
        s.tickets = SeasonRules.maxTickets - 1
        XCTAssertEqual(SeasonRules.rolled(s, m, today: "2026-11-11").tickets, SeasonRules.maxTickets)
    }

    func testBuyingAndSponsorTicketsHaveDailyCaps() {
        var s = SeasonRules.rolled(SeasonState(), m, today: inSeason)
        XCTAssertFalse(SeasonRules.canBuy(s, m, coins: 39, today: inSeason))
        XCTAssertTrue(SeasonRules.canBuy(s, m, coins: 40, today: inSeason))
        s.bought = 3
        XCTAssertFalse(SeasonRules.canBuy(s, m, coins: 999, today: inSeason))
        XCTAssertTrue(SeasonRules.sponsorTicket(&s, m, today: inSeason))
        XCTAssertFalse(SeasonRules.sponsorTicket(&s, m, today: inSeason))   // one a day here
        XCTAssertEqual(s.tickets, 3)
        s = SeasonRules.rolled(s, m, today: "2026-11-11")
        XCTAssertEqual([s.bought, s.sponsored], [0, 0])
    }

    func testDaysBetween() {
        XCTAssertEqual(SeasonRules.days(from: "2026-11-30", to: "2026-12-02"), 2)
        XCTAssertEqual(SeasonRules.days(from: "2026-11-01", to: "2026-11-01"), 0)
        XCTAssertNil(SeasonRules.days(from: "x", to: "2026-11-01"))
    }

    // MARK: Coins and saving

    func testSeasonBonusCoinsStopAtTheDailyCapAndSpendNeedsEnough() {
        var p = PetState(now: Date(timeIntervalSince1970: 1_800_000_000))
        var paid = 0
        for _ in 0..<20 { paid += p.bonus(SeasonRules.breathCoins, cap: SeasonRules.bonusPerDay) }
        XCTAssertEqual(paid, SeasonRules.bonusPerDay)
        XCTAssertEqual(p.coins, SeasonRules.bonusPerDay)
        XCTAssertFalse(p.spend(31))
        XCTAssertTrue(p.spend(30))
        XCTAssertEqual(p.coins, 0)
        let back = try! JSONDecoder().decode(PetState.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.today.bonus, SeasonRules.bonusPerDay)
    }

    func testSavedStateIsCheckedWhenRead() throws {
        let raw = #"{"tickets":9999,"owned":["s-bell","made-up"],"board":{"season":"x","cells":[null],"opened":[5]},"day":"2026-11-01"}"#
        let s = try JSONDecoder().decode(SeasonState.self, from: Data(raw.utf8))
        XCTAssertEqual(s.tickets, SeasonRules.maxTickets)
        XCTAssertEqual(s.owned, ["s-bell"])
        XCTAssertNil(s.board)
        XCTAssertEqual(s.day, "2026-11-01")
    }

    func testCenterIsQuietWhileOff() {
        let suite = "test.season.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = SeasonCenter(defaults: defaults)
        XCTAssertFalse(c.isOn)
        XCTAssertFalse(c.sponsorWatched())
        XCTAssertNil(c.open(0))
        XCTAssertNil(c.bubbleHex)
        XCTAssertEqual(c.state, SeasonState())
    }
}
