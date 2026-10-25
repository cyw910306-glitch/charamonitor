import CryptoKit
import XCTest
@testable import DogMonitor

final class RemoteMeetTests: XCTestCase {
    private let keys = MeetKeys(code: "K7QZ2MPAW4RHN")

    // MARK: Codes and links

    func testCodesAndLinks() {
        let c = MeetCode.make()
        XCTAssertEqual(c.count, MeetCode.length)
        XCTAssertTrue(c.allSatisfy(PluginRules.alphabet.contains))
        XCTAssertEqual(MeetCode.normalized(" k7qz-2mpa-w4rhn "), "K7QZ2MPAW4RHN")
        XCTAssertNil(MeetCode.normalized("AB12"))
        XCTAssertNil(MeetCode.normalized("K7QZ2MPA"))   // an 8-letter code is guessable offline from the room id
        XCTAssertNotNil(MeetCode.normalized("K7QZ2MPAW4RH"))
        XCTAssertNil(MeetCode.normalized(String(repeating: "A", count: 25)))

        let link = MeetCode.link("K7QZ2MPAW4RHN")
        XCTAssertEqual(link.absoluteString, "https://jelly-monitor.vercel.app/meet.html#K7QZ2MPAW4RHN")
        XCTAssertEqual(MeetCode.code(in: link), "K7QZ2MPAW4RHN")
        XCTAssertEqual(MeetCode.parse(link.absoluteString), "K7QZ2MPAW4RHN")
        XCTAssertEqual(MeetCode.parse("k7qz2mpaw4rhn"), "K7QZ2MPAW4RHN")
        XCTAssertEqual(MeetCode.code(in: URL(string: "charamonitor://meet?code=k7qz2mpaw4rhn")!), "K7QZ2MPAW4RHN")
        XCTAssertNil(MeetCode.code(in: URL(string: "charamonitor://say?code=K7QZ2MPAW4RHN")!))
        XCTAssertNil(MeetCode.code(in: URL(string: "https://evil.example/meet.html#K7QZ2MPAW4RHN")!))
        XCTAssertNil(MeetCode.code(in: URL(string: "http://jelly-monitor.vercel.app/meet.html#K7QZ2MPAW4RHN")!))
        XCTAssertNil(MeetCode.parse("https://jelly-monitor.vercel.app/meet.html#AB"))
    }

    // MARK: Keys

    func testKeysComeFromTheCodeOnly() {
        let again = MeetKeys(code: "K7QZ2MPAW4RHN"), other = MeetKeys(code: "K7QZ2MPAW4RHP")
        XCTAssertEqual(keys.room, again.room)
        XCTAssertNotEqual(keys.room, other.room)
        XCTAssertNotNil(keys.room.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression))
        // The room id is not the key: the key's bytes never appear in it.
        let keyHex = keys.key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(keyHex, keys.room)
        XCTAssertNotNil(MeetKeys.newMember().range(of: #"\A[0-9a-f]{32}\z"#, options: .regularExpression))

        // The id the room sees is derived from the secret exactly as web/api/relay.js memberId does.
        XCTAssertEqual(MeetKeys.memberID(String(repeating: "1", count: 32)), "8a83665f3798727f14f92ad0e6c99fda")
    }

    // MARK: Events

    func testSealOpenRoundTripAndTampering() throws {
        let e = MeetEvent(kind: .line, name: "보리", text: "오늘 저녁 어때?")
        let me = String(repeating: "1", count: 32), you = String(repeating: "2", count: 32)
        let box = try XCTUnwrap(MeetWire.seal(e, keys: keys, member: me))
        XCTAssertEqual(MeetWire.open(box, keys: keys, member: me), e)
        XCTAssertNil(MeetWire.open(box, keys: MeetKeys(code: "OTHERROOMCODE"), member: me))
        XCTAssertNil(MeetWire.open(box, keys: keys, member: you))   // posted again under another seat
        var bytes = try XCTUnwrap(Data(base64Encoded: box))
        bytes[bytes.count - 1] ^= 1
        XCTAssertNil(MeetWire.open(bytes.base64EncodedString(), keys: keys, member: me))
        XCTAssertNil(MeetWire.open(String(repeating: "A", count: MeetWire.maxData + 4), keys: keys, member: me))
        XCTAssertNil(MeetWire.seal(MeetEvent(kind: .line, name: "x", text: String(repeating: "가", count: 600)), keys: keys, member: me))   // over maxPlain
    }

    func testCleanKeepsOnlyWhatEachKindCarries() {
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .emote, name: "a", text: "💣")))
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .emote, name: "a", text: "🎉"))?.text, "🎉")
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .line, name: "a", text: " \u{202E}\n ")))
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .line, name: "a", text: String(repeating: "a", count: 250)))?.text?.count, 200)
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .fortune, name: "a", text: String(repeating: "a", count: 99)))?.text?.count, 60)
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .status, name: "a")))
        let hello = MeetWire.clean(MeetEvent(kind: .hello, name: String(repeating: "n", count: 40), status: .meal, text: "extra"))
        XCTAssertEqual(hello, MeetEvent(kind: .hello, name: String(repeating: "n", count: 16), status: .meal))
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .bye, name: ""))?.name, L("친구"))
        XCTAssertEqual(MeetWire.describe(MeetEvent(kind: .status, name: "a", status: .meal)), "🍚 \(OfficeStatus.meal.label)")
    }

    // MARK: Poll replies

    private func reply(seq: Int, members: Int = 2, _ items: [(Int, String, MeetEvent)]) -> Data {
        let events = items.map { ["s": $0.0, "m": $0.1, "d": MeetWire.seal($0.2, keys: keys, member: $0.1)!] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["seq": seq, "members": members, "events": events])
    }

    func testTakeSkipsMineAndOldOnesOldestFirst() throws {
        let me = String(repeating: "1", count: 32), you = String(repeating: "2", count: 32)
        let a = MeetEvent(kind: .emote, name: "너", text: "👋"), b = MeetEvent(kind: .line, name: "너", text: "안녕")
        let data = reply(seq: 5, [(5, you, b), (3, you, a), (4, me, a), (2, you, b)])
        let t = try XCTUnwrap(MeetWire.take(data, me: me, after: 2, keys: keys))
        XCTAssertEqual(t.events.map(\.event), [a, b])
        XCTAssertEqual(t.events.map(\.member), [you, you])
        XCTAssertEqual(t.seq, 5)
        XCTAssertEqual(t.members, 2)
    }

    func testTakeAfterTheRoomStartedOver() throws {
        let you = String(repeating: "2", count: 32), a = MeetEvent(kind: .emote, name: "너", text: "☕")
        let t = try XCTUnwrap(MeetWire.take(reply(seq: 1, [(1, you, a)]), me: "", after: 40, keys: keys))
        XCTAssertEqual(t.events.map(\.event), [a])
        XCTAssertEqual(t.seq, 1)
    }

    func testTakeRejectsJunk() throws {
        XCTAssertNil(MeetWire.take(Data("nope".utf8), me: "", after: 0, keys: keys))
        XCTAssertNil(MeetWire.take(Data(count: MeetWire.maxReply + 1), me: "", after: 0, keys: keys))
        // A bad box is skipped, members are clamped, events past the reply's seq are ignored.
        let you = String(repeating: "2", count: 32), me = String(repeating: "3", count: 32), a = MeetEvent(kind: .emote, name: "너", text: "🔥")
        let raw = try JSONSerialization.data(withJSONObject: ["seq": 3, "members": 99, "events": [
            ["s": 1, "m": you, "d": "AAAA"], ["s": 2, "m": you, "d": MeetWire.seal(a, keys: keys, member: you)!],
            ["s": 3, "m": me, "d": MeetWire.seal(a, keys: keys, member: you)!],   // replayed under another seat
            ["s": 9, "m": you, "d": MeetWire.seal(a, keys: keys, member: you)!]]])
        let t = try XCTUnwrap(MeetWire.take(raw, me: "", after: 0, keys: keys))
        XCTAssertEqual(t.events.map(\.event), [a])
        XCTAssertEqual(t.members, 12)
        XCTAssertEqual(t.seq, 3)
    }

    // MARK: The rest

    func testPhaseFromTheRelaysAnswer() {
        XCTAssertEqual(MeetPhase.from(status: 200, members: 3), .live(members: 3))
        XCTAssertEqual(MeetPhase.from(status: 403, members: 0), .full)
        for s in [nil, 404, 429, 502, 503] { XCTAssertEqual(MeetPhase.from(status: s, members: 0), .waiting) }
        XCTAssertEqual(MeetPhase.waiting.label, L("연결 중"))
        XCTAssertNotEqual(L("연결 중"), L("준비 중"))   // not the 출시 전 label
        let poll = (0..<50).map { _ in MeetRelay.nextPoll() }
        XCTAssertTrue(poll.allSatisfy { (120...300).contains($0) })   // 2 to 5 min unwatched
    }

    func testQuotaRestsUntilTheRelaysDayOpens() throws {
        let body = { (o: [String: Any]) in try! JSONSerialization.data(withJSONObject: o) }
        let r = try XCTUnwrap(MeetWire.rest(body(["error": "quota", "retry": 3600]), status: 503))
        XCTAssertTrue((3600...3720).contains(r))
        XCTAssertNotNil(MeetWire.rest(body(["error": "quota", "retry": 10]), status: 429))   // one address's share
        let long = try XCTUnwrap(MeetWire.rest(body(["error": "quota", "retry": 1e12]), status: 503))
        let short = try XCTUnwrap(MeetWire.rest(body(["error": "quota", "retry": -5]), status: 503))
        XCTAssertTrue((86_400...86_520).contains(long))
        XCTAssertTrue((1...121).contains(short))
        XCTAssertNil(MeetWire.rest(body(["error": "busy"]), status: 503))
        XCTAssertNil(MeetWire.rest(body(["error": "quota", "retry": 60]), status: 200))
        XCTAssertNil(MeetWire.rest(body(["error": "quota"]), status: 503))
        XCTAssertNil(MeetWire.rest(Data("nope".utf8), status: 503))
        XCTAssertNil(MeetWire.rest(nil, status: 503))
        XCTAssertEqual(MeetRelay.nextPoll(watched: true, members: 3, wait: r), r)   // no poll before then
        XCTAssertEqual(MeetPhase.resting.label, L("원격 모임 서버가 오늘 쓸 양을 다 써서 잠시 쉬어요. 하루 안에 다시 이어져요"))
        XCTAssertGreaterThanOrEqual(RemoteMeet.typingEvery, 30)   // 입력 중 is rare: each costs the relay's day
    }

    func testPluginTileAndCodeStore() {
        XCTAssertTrue(PluginID.remoteMeet.isInstalled)
        XCTAssertNil(PluginID.remoteMeet.desktopToggle)
        XCTAssertTrue(PluginID.shown.contains(.remoteMeet))
        let store = MeetCodeStore.memory()
        XCTAssertNil(store.load())
        store.save("K7QZ2MPAW4RHN")
        XCTAssertEqual(store.load(), "K7QZ2MPAW4RHN")
        store.delete()
        XCTAssertNil(store.load())
        for s in MeetWire.emotes { XCTAssertFalse(s.contains("\u{2014}")) }
    }
}
