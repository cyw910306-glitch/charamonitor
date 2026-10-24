import XCTest
@testable import DogMonitor

final class FriendNotesTests: XCTestCase {
    private let keys = MeetKeys(code: "K7QZ2MPAW4RHN")
    private let m = String(repeating: "2", count: 32)

    func testPretendOffGoesOutAsOff() {
        XCTAssertEqual(OfficeStatus.pretendOff.wire, .off)
        for s in OfficeStatus.allCases where s != .pretendOff { XCTAssertEqual(s.wire, s) }
        XCTAssertFalse(OfficeRules.atDesk(.pretendOff))
        // Picked by hand, it stays: the idle check never turns it back into 근무 중.
        XCTAssertNil(OfficeRules.auto(current: .pretendOff, autoSet: false, idle: 0, focusing: false, inMeeting: false))
        let e = MeetWire.clean(MeetEvent(kind: .status, name: "a", status: .pretendOff))
        XCTAssertEqual(e?.status, .off)
    }

    func testReceivedNoteIsCleanedAndBounded() {
        let raw = FriendNote(day: "2026-10-24", line: "  안녕\u{202E}하세요" + String(repeating: "가", count: 80), fortune: 9,
                             lunch: "김치\n찌개" + String(repeating: "x", count: 40))
        let n = try! XCTUnwrap(FriendNote.received(raw))
        XCTAssertEqual(n.line?.count, FriendNote.maxLine)
        XCTAssertFalse(n.line!.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertEqual(n.fortune, Fortune.redrawsPerDay)
        XCTAssertEqual(FriendNote.received(FriendNote(day: "2026-10-24", line: nil, fortune: -3, lunch: nil))?.fortune, 0)
        XCTAssertLessThanOrEqual(n.lunch!.count, LunchRules.maxName)
        XCTAssertFalse(n.lunch!.contains("\n"))
        XCTAssertNil(FriendNote.received(FriendNote(day: "2026-10-24", line: "   ", fortune: 0, lunch: " ")).flatMap { $0.line ?? $0.lunch })
        for bad in ["", "2026-1-24", "2026/10/24", "２０２６-10-24", "2026-10-245", "abcd-ef-gh"] {
            XCTAssertNil(FriendNote.received(FriendNote(day: bad, line: nil, fortune: 0, lunch: nil)), bad)
        }
        // The card's 운세 is the sender's own reading, rebuilt from (day, draw).
        XCTAssertEqual(n.reading, Fortune.reading(day: "2026-10-24", draw: 1))
    }

    func testMyNoteKeepsTheLineForItsDayOnly() {
        let suite = "test.friendnotes"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let bus = SocialBus()
        bus.defaults = d
        let today = Date(), tomorrow = today.addingTimeInterval(86_400)
        bus.setTodayLine(String(repeating: "하", count: 50), now: today)
        XCTAssertEqual(bus.todayLine(now: today).count, FriendNote.maxLine)
        XCTAssertEqual(bus.myNote(now: today).line?.count, FriendNote.maxLine)
        XCTAssertEqual(bus.todayLine(now: tomorrow), "")
        XCTAssertNil(bus.myNote(now: tomorrow).line)
    }

    func testDoodlePacksOnTheGridAndCaps() {
        let size = CGSize(width: 192, height: 192)
        let d = try! XCTUnwrap(Doodle.pack([[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 191.9, y: 300)], [], [CGPoint(x: -5, y: 96)]], in: size))
        // (0,0) and (1,1) land in one cell; a point off the canvas is clamped.
        XCTAssertEqual(d.strokes, [Data([0, 0, 63, 63]), Data([0, 32])])
        XCTAssertNil(Doodle.pack([[], []], in: size))
        let busy = (0..<40).map { s in (0..<64).map { CGPoint(x: CGFloat($0) * 3, y: CGFloat(s) * 4.8) } }
        let capped = try! XCTUnwrap(Doodle.pack(busy, in: size))
        XCTAssertEqual(capped.pointCount, Doodle.maxPoints)
        XCTAssertLessThanOrEqual(capped.strokes.count, Doodle.maxStrokes)
        XCTAssertEqual(Doodle.received(capped), capped)
        XCTAssertEqual(d.unitStrokes[0][1], CGPoint(x: 63.5 / 64, y: 63.5 / 64))
    }

    func testReceivedDoodleIsChecked() {
        XCTAssertNil(Doodle.received(Doodle(strokes: [])))
        XCTAssertNil(Doodle.received(Doodle(strokes: [Data([1, 2, 3])])))            // half a point
        XCTAssertNil(Doodle.received(Doodle(strokes: [Data([1, 64])])))              // off the grid
        XCTAssertNil(Doodle.received(Doodle(strokes: [Data(), Data([1, 1])])))       // an empty stroke
        XCTAssertNil(Doodle.received(Doodle(strokes: Array(repeating: Data([1, 1]), count: Doodle.maxStrokes + 1))))
        XCTAssertNil(Doodle.received(Doodle(strokes: [Data(repeating: 5, count: (Doodle.maxPoints + 1) * 2)])))
        XCTAssertNotNil(Doodle.received(Doodle(strokes: [Data(repeating: 5, count: Doodle.maxPoints * 2)])))
    }

    /// The biggest doodle and a full note fit one sealed event under the relay's 2048 characters, and come back.
    func testNotesAndDoodlesRideTheMeet() {
        let big = Doodle(strokes: (0..<Doodle.maxStrokes).map { i in Data(repeating: UInt8(i), count: i < 12 ? 26 : 24) })
        XCTAssertEqual(big.pointCount, Doodle.maxPoints)
        let name = String(repeating: "가", count: 16)
        let e = MeetEvent(kind: .doodle, name: name, doodle: big)
        let sealed = try! XCTUnwrap(MeetWire.seal(e, keys: keys, member: m))
        XCTAssertLessThanOrEqual(sealed.count, MeetWire.maxData)
        XCTAssertEqual(MeetWire.open(sealed, keys: keys, member: m), e)

        let note = FriendNote(day: "2026-10-24", line: String(repeating: "나", count: 40), fortune: 1, lunch: String(repeating: "다", count: 20))
        let n = MeetEvent(kind: .note, name: name, note: note)
        XCTAssertEqual(MeetWire.open(try! XCTUnwrap(MeetWire.seal(n, keys: keys, member: m)), keys: keys, member: m), n)
        // A doodle or note event without its payload, or with a bad one, is dropped.
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .doodle, name: "a")))
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .doodle, name: "a", doodle: Doodle(strokes: [Data([99, 99])]))))
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .note, name: "a", note: FriendNote(day: "yesterday", line: nil, fortune: 0, lunch: nil))))
    }

    /// A card shows a note from the viewer's day or one day off (time zones), nothing older.
    func testCardShowsANoteWithinADay() {
        XCTAssertTrue(FriendNote.current("2026-10-24", today: "2026-10-24"))
        XCTAssertTrue(FriendNote.current("2026-10-25", today: "2026-10-24"))
        XCTAssertTrue(FriendNote.current("2026-10-31", today: "2026-11-01"))
        XCTAssertFalse(FriendNote.current("2026-10-22", today: "2026-10-24"))
        XCTAssertFalse(FriendNote.current("nope", today: "2026-10-24"))
    }

    func testDoodlesAndNotesOnTheLink() {
        var r = SocialRateLimit()
        let d = SocialMessage.doodle(Doodle(strokes: [Data([1, 1])]))
        XCTAssertEqual(SocialRateLimit.kind(d), .doodle)
        XCTAssertTrue(r.allow(d, now: 0))
        XCTAssertTrue(r.allow(d, now: 1))
        XCTAssertFalse(r.allow(d, now: 2))
        XCTAssertTrue(r.allow(d, now: 10.5))
        let note = SocialMessage.note(FriendNote(day: "2026-10-24", line: "hi", fortune: 0, lunch: nil))
        let wire = try! XCTUnwrap(SocialWire.encode(note))
        XCTAssertEqual(SocialWire.decode(SocialMessage.self, wire), note)
        XCTAssertTrue(SocialWire.fromNewer(wire))   // a version 2 build skips it rather than closing the link
    }
}
