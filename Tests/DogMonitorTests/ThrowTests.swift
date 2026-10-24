import XCTest
@testable import DogMonitor

final class ThrowTests: XCTestCase {
    func testItemsAreOursAndNumberedOnce() {
        let items = Throwables.items
        XCTAssertGreaterThanOrEqual(items.filter { !$0.season }.count, 8)
        XCTAssertEqual(Set(items.map(\.wire)).count, items.count)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        for i in items {
            XCTAssertTrue(i.id.hasPrefix("t-"))
            XCTAssertFalse(i.art.isEmpty)
            XCTAssertFalse([ThrowRules.friend, ThrowRules.scare, ThrowRules.kiss].contains(i.wire))
            for ch in i.art.joined() where ch != "." { XCTAssertNotNil(Wardrobe.ink[ch], "\(i.id) \(ch)") }
            XCTAssertTrue(ThrowRules.valid(i.wire))
        }
        for w in [ThrowRules.friend, ThrowRules.scare, ThrowRules.kiss] { XCTAssertTrue(ThrowRules.valid(w)) }
        for w in [-1, 11, 89, 92, Int.max] { XCTAssertFalse(ThrowRules.valid(w)) }
    }

    func testSeasonOnesNeedWinning() {
        XCTAssertEqual(Set(Throwables.seasonIDs), ["t-snowball", "t-pinecone"])
        XCTAssertFalse(Throwables.usable(owned: []).contains { $0.season })
        XCTAssertTrue(Throwables.usable(owned: ["t-snowball"]).contains { $0.id == "t-snowball" })
        XCTAssertFalse(Throwables.usable(owned: ["t-snowball"]).contains { $0.id == "t-pinecone" })
        // A season.json may give them, the board draws them and calls them by name.
        XCTAssertTrue(SeasonCatalog.known.isSuperset(of: Throwables.seasonIDs))
        XCTAssertFalse(Throwables.items.filter { !$0.season }.contains { SeasonCatalog.known.contains($0.id) })
        XCTAssertEqual(SeasonCatalog.name("t-pinecone"), Throwables.item(id: "t-pinecone")?.name)
        XCTAssertFalse(SeasonIcon.art("t-snowball").0.isEmpty)
        var s = SeasonState()
        s.owned = ["t-snowball", "t-paper", "s-bell"]
        let back = try! JSONDecoder().decode(SeasonState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.owned, ["s-bell", "t-snowball"])   // an everyday item is never a season prize
    }

    func testFlightTimeAndArc() {
        XCTAssertEqual(ThrowRules.seconds(0), ThrowRules.base, accuracy: 1e-9)
        XCTAssertEqual(ThrowRules.seconds(1600), 1 + ThrowRules.base, accuracy: 1e-9)
        XCTAssertEqual(ThrowRules.arc(10), 24)
        XCTAssertEqual(ThrowRules.arc(300), 54, accuracy: 1e-9)
        XCTAssertEqual(ThrowRules.arc(5000), 96)
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 300, y: 0)
        XCTAssertEqual(ThrowRules.point(from: a, to: b, u: 0), a)
        XCTAssertEqual(ThrowRules.point(from: a, to: b, u: 1), b)
        XCTAssertEqual(ThrowRules.point(from: a, to: b, u: 2), b)
        let mid = ThrowRules.point(from: a, to: b, u: 0.5)
        XCTAssertEqual(mid.x, 150, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 54, accuracy: 1e-9)   // the top of the arc
    }

    func testFiveHitsInTenSecondsKnockOutForSix() {
        var r = StunRule()
        XCTAssertEqual((0..<4).map { r.hit(at: 100 + Double($0)) }, [false, false, false, false])
        XCTAssertTrue(r.hit(at: 104))
        XCTAssertTrue(r.isOut(at: 109.9))
        XCTAssertFalse(r.isOut(at: 110))
        XCTAssertFalse(r.hit(at: 105))   // out: it does not count
        XCTAssertTrue(r.recent.isEmpty)
        // Spread out over more than ten seconds: never out.
        var slow = StunRule()
        XCTAssertFalse((0..<10).map { slow.hit(at: Double($0) * 2.6) }.contains(true))
        // After waking, five more are needed.
        XCTAssertEqual((0..<5).map { r.hit(at: 111 + Double($0) * 0.2) }, [false, false, false, false, true])
    }

    func testAScareKnocksOutAtOnce() {
        var r = StunRule()
        r.knockOut(at: 50)
        XCTAssertTrue(r.isOut(at: 55))
        XCTAssertFalse(r.isOut(at: 56))
    }

    func testGuardAllowsTenSecondsAfterReady() {
        var g = ThrowGuard()
        XCTAssertTrue(g.allows(at: 0, guarded: false))
        XCTAssertFalse(g.allows(at: 0, guarded: true))
        g.arm(at: 100)
        XCTAssertTrue(g.allows(at: 109.9, guarded: true))
        XCTAssertFalse(g.allows(at: 110, guarded: true))
    }

    func testTheSameSoundWaitsAndAllAreCapped() {
        var g = SoundGap()
        XCTAssertTrue(g.allow(.tap, at: 10))
        XCTAssertFalse(g.allow(.tap, at: 10.05))
        XCTAssertTrue(g.allow(.thump, at: 10.05))
        XCTAssertTrue(g.allow(.tap, at: 10.09))
        var many = SoundGap()
        XCTAssertEqual((0..<11).filter { many.allow(.boing, at: 20 + Double($0) * 0.09) }.count, SoundGap.perSecond)
    }

    func testSoundsAreMadeForEveryKind() {
        for k in ThrowSound.Kind.allCases {
            let d = ThrowSound.make(k)
            XCTAssertEqual(d.prefix(4), Data("RIFF".utf8))
            XCTAssertGreaterThan(d.count, 44 + 1000)
        }
        XCTAssertEqual(ThrowSound.kind(ThrowRules.friend), .thump)
        XCTAssertNil(ThrowSound.kind(ThrowRules.kiss))
        XCTAssertNil(ThrowSound.kind(42))
    }

    func testAThrownFriendHitsEachOtherOnce() {
        let others = ["b": CGRect(x: 100, y: 0, width: 80, height: 80), "c": CGRect(x: 400, y: 0, width: 80, height: 80),
                      "d": CGRect(x: 175, y: 0, width: 80, height: 80)]
        XCTAssertEqual(ThrowRules.hits(CGRect(x: 150, y: 10, width: 80, height: 80), others: others, already: []), ["b", "d"])
        XCTAssertEqual(ThrowRules.hits(CGRect(x: 150, y: 10, width: 80, height: 80), others: others, already: ["b"]), ["d"])
        // Only the clear margins touching: no hit.
        XCTAssertEqual(ThrowRules.hits(CGRect(x: 30, y: 0, width: 80, height: 80), others: others, already: []), [])
    }

    func testWireCarriesNumbersOnlyAndOldBuildsSkipIt() {
        for m in [SocialMessage.hit(item: 3), .ko(seconds: 6)] {
            let d = SocialWire.encode(m)!
            XCTAssertEqual(SocialWire.decode(SocialMessage.self, d), m)
            XCTAssertTrue(SocialWire.fromNewer(d))   // a version 2 build skips it instead of closing the link
        }
        var r = SocialRateLimit()
        XCTAssertEqual((0..<12).filter { r.allow(.hit(item: 1), now: 100 + Double($0) * 0.1) }.count, 8)
        XCTAssertFalse(r.allow(.ko(seconds: 6), now: 105))
        XCTAssertTrue(r.allow(.emote(.kiss), now: 105))
    }

    func testRemoteHitsAreChecked() {
        let member = String(repeating: "a", count: 32)
        var hit = MeetEvent(kind: .hit, name: "보리")
        hit.item = 2
        hit.target = member
        XCTAssertEqual(MeetWire.clean(hit)?.item, 2)
        XCTAssertEqual(MeetWire.clean(hit)?.target, member)
        var bad = hit
        bad.item = 77
        XCTAssertNil(MeetWire.clean(bad))
        bad = hit
        bad.target = "../" + member
        XCTAssertNil(MeetWire.clean(bad))
        bad = hit
        bad.target = nil
        XCTAssertNil(MeetWire.clean(bad))
        var ko = MeetEvent(kind: .ko, name: "보리")
        XCTAssertNil(MeetWire.clean(ko))
        ko.seconds = 60
        XCTAssertNil(MeetWire.clean(ko))
        ko.seconds = 6
        XCTAssertEqual(MeetWire.clean(ko)?.seconds, 6)
        // Other kinds never carry them.
        var line = MeetEvent(kind: .line, name: "a", text: "hi")
        line.item = 1
        line.seconds = 3
        XCTAssertNil(MeetWire.clean(line)?.item)
        XCTAssertNil(MeetWire.clean(line)?.seconds)
        XCTAssertFalse(MeetWire.describe(MeetWire.clean(hit)!).isEmpty)
    }
}
