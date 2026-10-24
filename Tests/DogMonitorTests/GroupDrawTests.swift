import XCTest
@testable import DogMonitor

/// 그룹 뽑기: the same seed gives the same result on every Mac, each show lands on the winner, the wire checks, the
/// limits, and the share fits both wires.
final class GroupDrawTests: XCTestCase {
    private let six = ["보리", "콩이", "나", "두부", "감자", "치즈"]

    private func share(_ g: DrawGame, _ items: [String]? = nil, seed: UInt64 = 7) -> DrawShare {
        DrawShare.make(g, title: "", items: items ?? six, seed: seed)!
    }

    /// Pinned: a change to the draw itself would split old and new Macs, so the numbers are fixed here.
    func testWheelLabelsCutButNeverTheSame() {
        let items = (1...12).map { "항목 \($0) 이름" }
        let l = DrawRules.wheelLabels(items, most: 5)
        XCTAssertEqual(Set(l).count, 12)
        XCTAssertEqual(l[0], "1·항목 1…")
        XCTAssertEqual(l[1], "항목 2…")
        XCTAssertEqual(DrawRules.wheelLabels(["짜장", "짬뽕"], most: 8), ["짜장", "짬뽕"])
    }

    func testThePlanIsFixedBySeedAlone() {
        XCTAssertEqual(DrawRules.plan(share(.roulette, seed: 1)), DrawRules.plan(share(.roulette, seed: 1)))
        let winners = DrawGame.allCases.map { DrawRules.plan(share($0, seed: 12345)).winner }
        XCTAssertEqual(winners, [Self.pinned[0], Self.pinned[1], Self.pinned[2]])
        // Different seeds reach every item.
        for g in DrawGame.allCases {
            XCTAssertEqual(Set((0..<300).map { DrawRules.plan(share(g, seed: UInt64($0))).winner }), Set(0..<6), "\(g)")
        }
    }
    static let pinned = [2, 2, 2]

    func testTheWheelStopsWithTheWinnerUnderThePointer() {
        for seed in 0..<200 {
            for n in [2, 3, 7, 12] {
                let s = share(.roulette, (0..<n).map { "항목\($0)" }, seed: UInt64(seed))
                let p = DrawRules.plan(s)
                XCTAssertEqual(DrawRules.slice(at: p.spin, count: n), p.winner)
                XCTAssertGreaterThan(p.spin, 3 * 2 * .pi)   // at least a few whole turns
                XCTAssertEqual(DrawRules.ease(1), 1, accuracy: 1e-9)
            }
        }
    }

    func testTheLadderWalkEndsOnTheStarAndIsAPermutation() {
        for seed in 0..<200 {
            let s = share(.ladder, (0..<9).map { "사람\($0)" }, seed: UInt64(seed))
            let p = DrawRules.plan(s)
            XCTAssertEqual(DrawRules.end(from: p.winner, p.rungs), p.star)
            XCTAssertEqual(Set((0..<9).map { DrawRules.end(from: $0, p.rungs) }), Set(0..<9))
            for row in p.rungs { XCTAssertFalse(zip(row, row.dropFirst()).contains { $0 && $1 }) }
        }
    }

    func testTheLotsHandEndsOnTheWinnerAndOpensIt() {
        let s = share(.lots)
        let p = DrawRules.plan(s), total = DrawRules.duration(s, p)
        XCTAssertEqual(p.hops.last, p.winner)
        XCTAssertNotEqual(p.hops[p.hops.count - 2], p.winner)   // the last hop moves
        XCTAssertEqual(DrawRules.lots(p, at: 0).unfold, 0)
        XCTAssertEqual(DrawRules.lots(p, at: total).hop, p.winner)
        XCTAssertEqual(DrawRules.lots(p, at: total).unfold, 1)
    }

    func testMakeTidiesAndTheWireRefusesWhatIsNotTidy() {
        XCTAssertNil(DrawShare.make(.lots, title: "", items: ["하나", "  "]))
        XCTAssertNil(DrawShare.make(.lots, title: "", items: (0..<13).map { "\($0)" }))
        let s = DrawShare.make(.roulette, title: "  커피  쏘기 내기 열다섯 글자 넘게  ", items: ["a\u{200B}b", "열여섯 글자가 넘는 아주 긴 항목 이름"])!
        XCTAssertEqual(s.items[0], "ab")
        XCTAssertEqual(s.items[1].count, 15)
        XCTAssertEqual(s.title?.count, 15)
        XCTAssertEqual(DrawShare.tidy("가나다라마바사아자차카타파하 끝"), "가나다라마바사아자차카타파하")   // the cut leaves no space
        XCTAssertNotNil(DrawShare.make(.lots, title: "", items: ["가나다라마바사아자차카타파하 끝", "b"]))
        var bad = s
        bad.items[0] = "줄\n바꿈"
        XCTAssertNil(DrawShare.received(bad))
        bad = s
        bad.id = "../../x"
        XCTAssertNil(DrawShare.received(bad))
        bad = s
        bad.items = ["하나"]
        XCTAssertNil(DrawShare.received(bad))
        bad = s
        bad.items = Array(repeating: String(repeating: "👨‍👩‍👧‍👦", count: 15), count: 12)   // 15 characters, far over the bytes
        XCTAssertNil(DrawShare.received(bad))
        XCTAssertEqual(DrawShare.received(s), s)
    }

    func testTheFullestDrawFitsTheMeetBoxAndTheMessageRoundTrips() {
        let s = DrawShare.make(.ladder, title: String(repeating: "가", count: 15),
                               items: (0..<12).map { _ in String(repeating: "힣", count: 15) })!
        let keys = MeetKeys(code: "ABCDEFGHJKLMN")
        let e = MeetEvent(kind: .draw, name: String(repeating: "닉", count: 16), draw: s)
        let sealed = MeetWire.seal(e, keys: keys, member: "m1")
        XCTAssertNotNil(sealed)
        XCTAssertEqual(MeetWire.open(sealed!, keys: keys, member: "m1")?.draw, s)
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .draw, name: "x")))
        let wire = SocialWire.encode(SocialMessage.draw(s))!
        XCTAssertEqual(SocialWire.decode(SocialMessage.self, wire), .draw(s))
        XCTAssertTrue(SocialWire.fromNewer(wire))   // an older build skips it instead of closing the link
        XCTAssertTrue(MeetWire.describe(MeetWire.clean(e)!).contains("👑"))
    }

    func testTheBookKeepsTheLimits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var book = DrawBook()
        func rec(_ sender: String, _ at: Date) -> DrawRecord { DrawRecord(share: share(.lots, seed: .random(in: 0...UInt64.max)), from: "x", sender: sender, at: at) }
        for _ in 0..<DrawBook.maxLive { XCTAssertNil(book.add(rec("me", now), now: now)) }
        XCTAssertEqual(book.add(rec("me", now), now: now), .tooMany)
        XCTAssertNil(book.add(rec("f:a", now), now: now))   // per maker
        let first = book.records[0]
        XCTAssertEqual(book.add(first, now: now), .seen)
        book.end(first.id)
        XCTAssertNil(book.add(rec("me", now), now: now))   // 끝내기 frees a place
        XCTAssertFalse(book.crowned(book.records[0], now: now))
        XCTAssertTrue(book.crowns(now: now).contains(book.records[1].winner))

        // 20 an hour, even after 끝내기 or 지우기.
        var hourly = DrawBook()
        for i in 0..<DrawBook.perHour {
            let r = rec("m:z", now.addingTimeInterval(Double(i)))
            XCTAssertNil(hourly.add(r, now: r.at))
            hourly.remove(r.id)
        }
        XCTAssertEqual(hourly.add(rec("m:z", now.addingTimeInterval(60)), now: now.addingTimeInterval(60)), .hourly)
        XCTAssertNil(hourly.add(rec("m:z", now.addingTimeInterval(3700)), now: now.addingTimeInterval(3700)))

        // The crown goes after its hours, the record after a day.
        let later = now.addingTimeInterval(DrawBook.crownHours * 3600 + 1)
        XCTAssertEqual(book.live("me", now: later), 0)
        XCTAssertTrue(book.crowns(now: later).isEmpty)
        book.prune(now.addingTimeInterval(DrawBook.keepHours * 3600))
        XCTAssertTrue(book.records.isEmpty)
    }
}
