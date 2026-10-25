import XCTest
@testable import DogMonitor

/// 원격 모임 members in 친구 상주: hello's look, 200-character 한마디, 입력 중, resends shown once, poll pace, 대화 모아보기.
final class RemoteRoomTests: XCTestCase {
    private let keys = MeetKeys(code: "K7QZ2MPAW4RHN")
    private let me = String(repeating: "1", count: 32), you = String(repeating: "2", count: 32), them = String(repeating: "3", count: 32)

    // MARK: Wire

    func testChatKeepsThreeLinesAnd200Characters() {
        XCTAssertEqual(MeetWire.chat(" 안녕 \n\n 점심 \r\n 뭐 먹지 \n 넷째 줄 "), "안녕\n점심\n뭐 먹지")
        XCTAssertEqual(MeetWire.chat(String(repeating: "가", count: 300)).count, 200)
        XCTAssertEqual(MeetWire.chat("a\u{202E}b\u{200B}"), "ab")
        XCTAssertEqual(MeetWire.chat(" \n \n"), "")
        // The worst case still seals under the relay's 2,048 characters (and its 1,400 plaintext bytes).
        let id = UUID().uuidString
        let worst = MeetEvent(kind: .line, name: String(repeating: "냥", count: 16), text: MeetWire.chat(String(repeating: "\"", count: 200)), id: id)
        let box = MeetWire.seal(worst, keys: keys, member: me)
        XCTAssertNotNil(box)
        XCTAssertLessThanOrEqual(box?.count ?? .max, MeetWire.maxData)
        XCTAssertNotNil(MeetWire.seal(MeetEvent(kind: .line, name: "a", text: String(repeating: "가", count: 200), id: id), keys: keys, member: me))
    }

    func testLineIDsAndHelloLooks() {
        let id = UUID().uuidString
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .line, name: "a", text: "hi", id: id.lowercased()))?.id, id)
        XCTAssertNil(MeetWire.clean(MeetEvent(kind: .line, name: "a", text: "hi", id: "not-a-uuid"))?.id)
        var custom = FriendLook.fallback
        custom.character = .custom
        let hello = MeetWire.clean(MeetEvent(kind: .hello, name: "보리", status: .pretendOff, look: custom))
        XCTAssertEqual(hello?.look, .fallback)   // never pack or photo art
        XCTAssertEqual(hello?.status, .off)
        var cat = FriendLook.fallback
        cat.character = .cat
        cat.id = "tabby"
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .hello, name: "a", look: cat))?.look, cat)
        XCTAssertEqual(MeetWire.clean(MeetEvent(kind: .typing, name: "a", text: "secret"))?.text, nil)   // never the text
        let again = try! XCTUnwrap(MeetWire.clean(MeetEvent(kind: .presence, name: "a", status: .meal, text: "x", look: cat)))
        XCTAssertEqual(again, MeetEvent(kind: .presence, name: "a", status: .meal, look: cat))
        let seat = MeetSeats.heard([:], [MeetWire.Heard(member: "m1", event: again)], now: 5).members["m1"]
        XCTAssertEqual(seat?.look, cat)
        XCTAssertEqual(seat?.status, .meal)
        XCTAssertEqual(MeetWire.describe(again), "")   // never a line in the log
    }

    /// What a build from before this sees: the new fields are skipped, `.typing` does not decode (and is dropped).
    func testOlderBuildsSkipTheNewParts() throws {
        struct OldEvent: Decodable {
            enum Kind: String, Decodable { case hello, status, emote, fortune, line, bye, note, doodle, draw }
            var kind: Kind
            var name: String
            var text: String?
        }
        let hello = try JSONEncoder().encode(MeetEvent(kind: .hello, name: "보리", status: .meal, look: .fallback))
        XCTAssertEqual(try JSONDecoder().decode(OldEvent.self, from: hello).kind, .hello)
        let line = try JSONEncoder().encode(MeetEvent(kind: .line, name: "보리", text: "안녕", id: UUID().uuidString))
        XCTAssertEqual(try JSONDecoder().decode(OldEvent.self, from: line).text, "안녕")
        XCTAssertNil(try? JSONDecoder().decode(OldEvent.self, from: JSONEncoder().encode(MeetEvent(kind: .typing, name: "보리"))))
        // A hello sent again is .presence: an older build drops it instead of showing 들어왔어요 each time.
        XCTAssertNil(try? JSONDecoder().decode(OldEvent.self, from: JSONEncoder().encode(MeetEvent(kind: .presence, name: "보리", look: .fallback))))
    }

    func testTakeReadsTypingMineTheRelayVersionAndWait() throws {
        let id = UUID().uuidString
        let line = MeetEvent(kind: .line, name: "나", text: "안녕", id: id)
        let typing = MeetEvent(kind: .typing, name: "너")
        let seal = { (e: MeetEvent, m: String) in MeetWire.seal(e, keys: self.keys, member: m)! }
        let raw = try JSONSerialization.data(withJSONObject: [
            "v": 2, "seq": 2, "members": 3, "wait": 999,
            "events": [["s": 1, "m": me, "d": seal(line, me)], ["s": 2, "m": you, "d": seal(MeetEvent(kind: .emote, name: "너", text: "👋"), you)]],
            "live": [["m": you, "d": seal(typing, you), "a": 1500], ["m": you, "d": seal(typing, you), "a": 0],   // one per member
                     ["m": me, "d": seal(typing, me), "a": 0],                                                    // not mine
                     ["m": them, "d": seal(MeetEvent(kind: .emote, name: "x", text: "🎉"), them), "a": 0],         // typing only
                     ["m": them, "d": seal(typing, you), "a": 0]],                                                // another seat's box
        ])
        let t = try XCTUnwrap(MeetWire.take(raw, me: me, after: 0, keys: keys))
        XCTAssertEqual(t.events.map(\.member), [you])
        XCTAssertEqual(t.typing, [MeetWire.Typing(member: you, age: 1.5)])
        XCTAssertEqual(t.mine, [id])
        XCTAssertEqual(t.relay, 2)
        XCTAssertEqual(t.wait, 300)
        // An older relay: no live, no v.
        let old = try XCTUnwrap(MeetWire.take(try JSONSerialization.data(withJSONObject: ["seq": 0, "members": 1, "events": []]), me: me, after: 0, keys: keys))
        XCTAssertEqual(old.relay, 1)
        XCTAssertEqual(old.typing, [])
        XCTAssertEqual(old.wait, 0)
    }

    func testSeenShowsAResentLineOnce() {
        var seen = MeetSeen()
        XCTAssertTrue(seen.first("A", from: you))
        XCTAssertFalse(seen.first("A", from: you))
        XCTAssertTrue(seen.first("A", from: them))   // per member
        XCTAssertTrue(seen.first(nil, from: you))
        XCTAssertTrue(seen.first(nil, from: you))
        for i in 0..<MeetSeen.keep { _ = seen.first("x\(i)", from: you) }
        XCTAssertTrue(seen.first("A", from: you))   // the oldest went
    }

    // MARK: Seats

    func testSeatsFromHelloStatusAndBye() {
        var cat = FriendLook.fallback
        cat.character = .cat
        let heard = { (m: String, e: MeetEvent) in MeetWire.Heard(member: m, event: e) }
        var (m, newFace) = MeetSeats.heard([:], [heard(you, MeetEvent(kind: .hello, name: "보리", status: .meal, look: cat))], now: 100)
        XCTAssertTrue(newFace)
        XCTAssertEqual(m[you]?.look, cat)
        XCTAssertEqual(m[you]?.status, .meal)
        (m, newFace) = MeetSeats.heard(m, [heard(you, MeetEvent(kind: .status, name: "보리2", status: .off)),
                                           heard(you, MeetEvent(kind: .emote, name: "보리2", text: "👋"))], now: 200)
        XCTAssertFalse(newFace)
        XCTAssertEqual(m[you]?.look, cat)   // kept from the hello
        XCTAssertEqual(m[you]?.status, .off)
        XCTAssertEqual(m[you]?.name, "보리2")
        XCTAssertEqual(m[you]?.heard, 200)
        // Someone whose hello is long gone still stands, as the plain dog.
        (m, newFace) = MeetSeats.heard(m, [heard(them, MeetEvent(kind: .line, name: "콩이", text: "hi"))], now: 300)
        XCTAssertTrue(newFace)
        XCTAssertEqual(m[them]?.look, .fallback)
        XCTAssertEqual(MeetSeats.row(m, now: 300).map(\.name), ["보리2", "콩이"])
        XCTAssertEqual(MeetSeats.row(m, now: 200 + MeetSeats.seatSeconds).map(\.name), ["콩이"])   // quiet for 45 min
        (m, _) = MeetSeats.heard(m, [heard(them, MeetEvent(kind: .bye, name: "콩이"))], now: 400)
        XCTAssertNil(m[them])
        // 11 at most: the 12th seat is me.
        var many: [String: MeetMember] = [:]
        for i in 0..<20 { many["\(i)"] = MeetMember(id: "\(i)", name: String(format: "%02d", i), look: .fallback, status: .working, heard: 0) }
        XCTAssertEqual(MeetSeats.row(many, now: 1).count, 11)
        let f = { (id: String) in SocialFriend(id: id, nickname: id, look: .fallback, status: .working, pairedAt: .distantPast) }
        let row = RoomRules.row(nearby: (0..<7).map { f("n\($0)") }, remote: (0..<11).map { f("m:\($0)") })
        XCTAssertEqual(row.count, RoomRules.mostSeats)
        XCTAssertEqual(row.first?.id, "n0")
    }

    func testSeatTalkLineThenTypingTimes() {
        var t = SeatTalk()
        XCTAssertNil(t.show(at: 0))
        XCTAssertNil(t.next(after: 0))
        t.typing(at: 10, age: 1.5)
        XCTAssertEqual(t.show(at: 13.9), .typing)
        XCTAssertNil(t.show(at: 14.1))   // 5.5 s from the signal, 1.5 s of it already gone
        t.typing(at: 20)
        t.said("안녕", at: 21)
        XCTAssertEqual(t.show(at: 21), .line("안녕"))   // a line ends their typing
        XCTAssertEqual(t.next(after: 21), 21 + SpeechBubbleWindow.duration("안녕"))
        t.typing(at: 22)
        XCTAssertEqual(t.show(at: 23), .line("안녕"))   // the line stays first
        XCTAssertEqual(t.show(at: 27.4), .typing)
        XCTAssertNil(t.show(at: 28))
    }

    func testBubblesSitOnTheHeadAndStackApart() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 800), sprite = CGSize(width: 40, height: 40), size = CGSize(width: 120, height: 50)
        let seat = CGRect(x: 100, y: 0, width: 70, height: 84)
        let up = RoomBubbles.frame(seat: seat, sprite: sprite, size: size, edge: .bottom, in: vf)
        XCTAssertEqual(up.midX, 120)
        XCTAssertEqual(up.minY, 40 - RoomBubbles.pad / 2)
        let down = RoomBubbles.frame(seat: CGRect(x: 100, y: 716, width: 70, height: 84), sprite: sprite, size: size, edge: .top, in: vf)
        XCTAssertEqual(down.maxY, 716 + RoomBubbles.pad / 2)
        XCTAssertEqual(RoomBubbles.frame(seat: CGRect(x: -30, y: 0, width: 70, height: 84), sprite: sprite, size: size, edge: .bottom, in: vf).minX, 0)

        let a = CGRect(x: 100, y: 40, width: 120, height: 50), b = CGRect(x: 150, y: 40, width: 120, height: 50), c = CGRect(x: 600, y: 40, width: 120, height: 50)
        let s = RoomBubbles.stacked([a, b, c])
        XCTAssertEqual(s[0], a)
        XCTAssertEqual(s[2], c)   // far away: untouched
        XCTAssertFalse(s[1].insetBy(dx: RoomBubbles.pad, dy: RoomBubbles.pad).intersects(s[0].insetBy(dx: RoomBubbles.pad, dy: RoomBubbles.pad)))
        XCTAssertGreaterThan(s[1].minY, a.minY)
        let three = RoomBubbles.stacked([a, b, a.offsetBy(dx: 20, dy: 0)])
        XCTAssertGreaterThan(three[2].minY, three[1].minY)   // past both
        XCTAssertLessThan(RoomBubbles.stacked([a, b], down: true)[1].minY, a.minY)
    }

    // MARK: Pace

    func testPollIsFastOnlyWhileWatchedWithOthers() {
        for _ in 0..<30 {
            XCTAssertTrue(MeetRelay.fastSeconds.contains(MeetRelay.nextPoll(watched: true, members: 2)))
            XCTAssertTrue(MeetRelay.pollSeconds.contains(MeetRelay.nextPoll(watched: true, members: 1)))   // alone
            XCTAssertTrue(MeetRelay.pollSeconds.contains(MeetRelay.nextPoll(watched: false, members: 12)))
        }
        XCTAssertEqual(MeetRelay.nextPoll(watched: true, members: 5, wait: 45), 45)   // the relay asked to wait
        XCTAssertEqual(MeetRelay.nextPoll(wait: 10_000), 10_000)   // a quota retry
        XCTAssertEqual(MeetRelay.nextPoll(wait: 1e9), 86_520)
        XCTAssertEqual(MeetRelay.fastSeconds, 20...30)
        XCTAssertEqual(MeetWire.maxMembers, 12)
        XCTAssertEqual(MeetPhase.full.label, L("모임이 꽉 찼어요 (12명)"))
    }

    // MARK: 대화 모아보기

    func testTalkFileKeepsThreeDaysAndMarksLeftoversFailed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let e = { (ago: TimeInterval, s: TalkState?) in TalkEntry(date: now.addingTimeInterval(-ago), thread: TalkEntry.meet, name: "a", text: "t", mine: true, state: s) }
        XCTAssertEqual(TalkFile.trimmed([e(4 * 86400, nil), e(60, nil), e(-3600, nil)], now: now).count, 1)   // too old, and from the future
        XCTAssertEqual(TalkFile.trimmed((0..<400).map { _ in e(1, nil) }, now: now).count, TalkFile.keep)
        var long = e(1, .pending)
        long.text = String(repeating: "가", count: 500)
        let back = TalkFile.decode(try JSONEncoder().encode([long]), now: now)
        XCTAssertEqual(back.first?.state, .failed)
        XCTAssertEqual(back.first?.text.count, 200)
        XCTAssertEqual(TalkFile.decode(Data("nope".utf8), now: now), [])
        XCTAssertEqual(TalkFile.decode(Data(count: TalkFile.maxBytes + 1), now: now), [])
    }

    func testTalkLogStatesAndTheFileOnlyWhileKept() throws {
        let suite = "test.talklog.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = TalkLog()
        log.defaults = d
        log.url = dir.appendingPathComponent("TalkLog.json")
        log.add(TalkEntry(thread: TalkEntry.meet, name: "", text: "안녕", mine: true, msgID: "X", state: .pending))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url!.path))   // off at first: memory only
        XCTAssertTrue(log.has("X"))
        log.mark("X", .sent)
        XCTAssertEqual(log.state("X"), .sent)
        log.setKeeps(true)
        let attrs = try FileManager.default.attributesOfItem(atPath: log.url!.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let again = TalkLog()
        again.defaults = d
        again.url = log.url
        again.start()
        XCTAssertEqual(again.entries.map(\.text), ["안녕"])
        log.setKeeps(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url!.path))
    }
}
