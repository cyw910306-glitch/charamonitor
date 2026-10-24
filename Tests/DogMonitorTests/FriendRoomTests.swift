import XCTest
@testable import DogMonitor

final class FriendRoomTests: XCTestCase {
    private func friend(_ id: String, _ status: OfficeStatus = .working) -> SocialFriend {
        SocialFriend(id: id, nickname: id, look: .fallback, status: status, pairedAt: Date(timeIntervalSince1970: 0))
    }

    func testOnlyOnlineFriendsStayAndAtMostSeven() {
        let all = (0..<10).map { friend("f\($0)") }
        XCTAssertEqual(RoomRules.members(all, online: ["f1", "f3"]).map(\.id), ["f1", "f3"])
        XCTAssertEqual(RoomRules.members(all, online: Set(all.map(\.id))).count, 7)
        XCTAssertTrue(RoomRules.members(all, online: []).isEmpty)
    }

    func testEmotesGoOnlyToFriendsThatReadThem() {
        XCTAssertFalse(RoomRules.canEmote(version: nil))
        XCTAssertFalse(RoomRules.canEmote(version: 1))
        XCTAssertTrue(RoomRules.canEmote(version: 2))
        XCTAssertTrue(RoomRules.canEmote(version: 3))
        // b is offline, c has an old app, d said nothing yet.
        XCTAssertEqual(RoomRules.emoteTargets(online: ["a", "c", "d", "e"], versions: ["a": 2, "b": 2, "c": 1, "e": 3]), ["a", "e"])
    }

    func testSlotsLineUpFromTheLeft() {
        XCTAssertEqual(RoomRules.slotX(0, minX: 0, width: 100), 90)
        XCTAssertEqual(RoomRules.slotX(2, minX: 0, width: 100), 90 + 216)
    }

    func testEmoteRoundTripAndKinds() {
        for k in EmoteKind.allCases {
            XCTAssertEqual(SocialWire.decode(SocialMessage.self, SocialWire.encode(SocialMessage.emote(k))!), .emote(k))
        }
        XCTAssertEqual(EmoteKind.kiss.effect, .hearts)
        XCTAssertEqual(EmoteKind.poop.effect, .poop)
        XCTAssertNil(EmoteKind.toss.effect)
    }

    func testANewerMessageIsSkippedButGarbageCloses() {
        // A case this build does not know, and a known case with a kind it does not know.
        for json in [#"{"dance":{}}"#, #"{"emote":{"_0":"hug"}}"#] {
            let d = Data(json.utf8)
            XCTAssertNil(SocialWire.decode(SocialMessage.self, d))
            XCTAssertTrue(SocialWire.fromNewer(d))
        }
        for junk in ["not json", "[1,2]", #"{"a":1,"b":2}"#, "{}"] { XCTAssertFalse(SocialWire.fromNewer(Data(junk.utf8))) }
    }

    func testEmoteRateLimitIsThreeInTenSeconds() {
        var r = SocialRateLimit()
        XCTAssertEqual((0..<6).filter { r.allow(.emote(.kiss), now: 100 + Double($0) * 0.1) }.count, 3)
        XCTAssertFalse(r.allow(.emote(.poop), now: 109))
        XCTAssertTrue(r.allow(.emote(.poop), now: 110.1))
        XCTAssertTrue(r.allow(.chat("emotes do not use up chat"), now: 100.2))
    }

    func testGatheringSeatsAndParty() {
        XCTAssertEqual(Gathering.capacity(0), 4)
        XCTAssertEqual(Gathering.capacity(3), 4)
        XCTAssertEqual(Gathering.capacity(8), 8)
        XCTAssertEqual(Gathering.waiting(capacity: 4, friends: 1), 2)
        XCTAssertEqual(Gathering.waiting(capacity: 2, friends: 5), 0)
        XCTAssertTrue(Gathering.isFull(capacity: 2, online: 1))
        XCTAssertFalse(Gathering.isFull(capacity: 8, online: 6))

        var g = Gathering()
        XCTAssertFalse(g.update(capacity: 4, online: 2))
        XCTAssertTrue(g.update(capacity: 4, online: 3))    // filled up: once
        XCTAssertFalse(g.update(capacity: 4, online: 3))
        XCTAssertFalse(g.update(capacity: 4, online: 2))   // someone left
        XCTAssertTrue(g.update(capacity: 4, online: 3))    // full again
        XCTAssertTrue(g.update(capacity: 2, online: 3) == false)   // a smaller size while full: no second party
    }
}
