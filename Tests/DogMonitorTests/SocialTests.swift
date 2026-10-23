import Network
import XCTest
@testable import DogMonitor

final class SocialTests: XCTestCase {
    // MARK: Pure parts

    func testFrameLengthAndLimit() {
        let f = SocialWire.frame(Data([1, 2, 3]))
        XCTAssertEqual(f.prefix(4), Data([0, 0, 0, 3]))
        XCTAssertEqual(SocialWire.length(f.prefix(4)), 3)
        XCTAssertEqual(SocialWire.length(SocialWire.frame(Data(count: SocialWire.maxFrame)).prefix(4)), SocialWire.maxFrame)
        XCTAssertNil(SocialWire.length(Data([0, 1, 0, 1])))   // 64 KiB + 1
        XCTAssertNil(SocialWire.length(Data([0, 1])))
    }

    func testMessagesRoundTrip() {
        let all: [SocialMessage] = [
            .hello(nickname: "초코", look: .fallback, status: .meal, version: 1), .chat("안녕"), .invite(.starDuel, seed: 42),
            .voice(seq: 7, pcm: Data(repeating: 9, count: 640)), .remoteAnswer(accept: true, screenSharingOn: false), .bye,
        ]
        for m in all { XCTAssertEqual(SocialWire.decode(SocialMessage.self, SocialWire.encode(m)!), m) }
    }

    func testChatTextIsCleaned() {
        XCTAssertEqual(SocialText.clean("a\u{202E}b\u{200B}c\u{0007}d\ne"), "abcde")
        XCTAssertEqual(SocialText.clean("  hi there  "), "hi there")
        XCTAssertEqual(SocialText.clean(String(repeating: "가", count: 300)).count, 200)
        XCTAssertEqual(SocialText.nickname(String(repeating: "x", count: 40)).count, 16)
        XCTAssertFalse(SocialText.nickname("\u{200B}").isEmpty)
    }

    func testRateLimits() {
        var r = SocialRateLimit()
        XCTAssertTrue(r.allow(.chat("a"), now: 0))
        XCTAssertFalse(r.allow(.chat("b"), now: 0.5))
        XCTAssertTrue(r.allow(.chat("c"), now: 1.0))
        let voice = (0..<70).filter { r.allow(.voice(seq: UInt32($0), pcm: Data()), now: 2 + Double($0) / 100) }.count
        XCTAssertEqual(voice, 60)
        let other = (0..<15).filter { _ in r.allow(.status(.meal), now: 5) }.count
        XCTAssertEqual(other, 10)
        let state = PlayNetState(x: 0, y: 0, vx: 0, vy: 0, onGround: true, crouching: false, facingLeft: false, stars: 0)
        XCTAssertEqual((0..<40).filter { _ in r.allow(.play(state), now: 6) }.count, 30)   // about 20 a second fits
        XCTAssertTrue(r.allow(.hello(nickname: "a", look: .fallback, status: .working, version: 1), now: 10))
        XCTAssertTrue(r.allow(.look(.fallback), now: 11))
        XCTAssertFalse(r.allow(.look(.fallback), now: 13))   // 2 in 4 s
        XCTAssertTrue(r.allow(.look(.fallback), now: 14))
    }

    func testCheckNumberAndTags() {
        let k1 = Data(repeating: 1, count: 32), k2 = Data(repeating: 2, count: 32)
        let c = SocialCrypto.check(k1)
        XCTAssertEqual(c.count, 7)
        XCTAssertEqual(c, SocialCrypto.check(k1))
        XCTAssertNotEqual(c, SocialCrypto.check(k2))
        let salt = SocialCrypto.newSalt()
        XCTAssertEqual(salt.count, 16)
        XCTAssertNotEqual(salt, SocialCrypto.newSalt())
        XCTAssertEqual(SocialCrypto.tag(k1, salt: salt).count, 12)
        XCTAssertNotEqual(SocialCrypto.tag(k1, salt: salt), SocialCrypto.tag(k1, salt: "other"))   // unlinkable across listeners
        XCTAssertNotEqual(SocialCrypto.tag(k1, salt: salt), SocialCrypto.tag(k2, salt: salt))
    }

    func testOversizeOrCustomLookShowsAsTheDog() {
        var big = FriendLook.fallback
        big.colors = Dictionary(uniqueKeysWithValues: (0..<400).map { ("part\($0)", RGBColor(r: 10, g: 20, b: 30)) })
        XCTAssertEqual(FriendLook.received(big), .fallback)
        var custom = FriendLook.fallback
        custom.character = .custom
        XCTAssertEqual(FriendLook.received(custom), .fallback)
        var cat = FriendLook.fallback
        cat.character = .cat
        XCTAssertEqual(FriendLook.received(cat), cat)
    }

    func testPairKeyDependsOnCode() {
        XCTAssertEqual(SocialCrypto.pairKey("123456"), SocialCrypto.pairKey("123456"))
        XCTAssertNotEqual(SocialCrypto.pairKey("123456"), SocialCrypto.pairKey("123457"))
        XCTAssertEqual(SocialCrypto.pairKey("000000").count, 32)
        XCTAssertEqual(SocialCrypto.newCode().count, 6)
    }

    func testVoiceRoundTrip() {
        let samples: [Float] = (0..<VoiceCodec.frameSamples).map { sin(Float($0) / 10) * 0.8 }
        let pcm = VoiceCodec.encode(samples + [2, -2])   // clamped
        XCTAssertEqual(pcm.count, (VoiceCodec.frameSamples + 2) * 2)
        let back = VoiceCodec.decode(pcm)
        for (a, b) in zip(samples, back) { XCTAssertEqual(a, b, accuracy: 1.0 / 32767 + 1e-6) }
        XCTAssertEqual(back.suffix(2).map { $0.rounded() }, [1, -1])
        XCTAssertEqual(pcm[0...1], Data([0, 0]))   // little-endian zero

        var chunker = VoiceChunker()
        XCTAssertEqual(chunker.push(Data(count: 1000)).count, 1)
        XCTAssertEqual(chunker.push(Data(count: 280)).map(\.count), [640])
        XCTAssertEqual(chunker.push(Data(count: 10)).count, 0)
    }

    func testJitterWaitsForThreeAndDropsOld() {
        var j = VoiceJitter()
        XCTAssertEqual(j.push(2, Data([2])), [])
        XCTAssertEqual(j.push(1, Data([1])), [])
        XCTAssertEqual(j.push(3, Data([3])), [Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(j.push(3, Data([3])), [])   // already played
        XCTAssertEqual(j.push(1, Data([1])), [])
        XCTAssertEqual(j.push(4, Data([4])), [Data([4])])
    }

    func testVoiceBudgetCapsBacklogAndLength() {
        var b = VoiceBudget()
        // 60 frames a second against 50 played: the queue stops at 0.5 s instead of growing.
        let sent = (0..<600).map { Double($0) / 60 }
        let played = sent.filter { b.admit(now: $0) }.count
        XCTAssertLessThanOrEqual(played, 500 + 25)
        XCTAssertGreaterThan(played, 480)
        var c = VoiceBudget()
        XCTAssertTrue(c.admit(now: 100))
        XCTAssertTrue(c.admit(now: 129))
        XCTAssertFalse(c.admit(now: 130.5))   // 30 s per talk
    }

    func testRemoteAskLimit() {
        var l = RemoteAskLimit()
        XCTAssertTrue(l.ask("a", now: 0))
        XCTAssertFalse(l.ask("a", now: 10))                       // one pending
        XCTAssertTrue(l.answered("a", now: 20, final: false))     // screen sharing off: still pending
        XCTAssertTrue(l.answered("a", now: 30, final: true))
        XCTAssertFalse(l.answered("a", now: 31, final: true))     // nobody asked
        XCTAssertTrue(l.ask("a", now: 40))
        XCTAssertTrue(l.answered("a", now: 41, final: true))
        XCTAssertTrue(l.ask("a", now: 50))
        XCTAssertTrue(l.answered("a", now: 51, final: true))
        XCTAssertFalse(l.ask("a", now: 60))                       // 3 in 10 minutes
        XCTAssertTrue(l.ask("a", now: 601))
        XCTAssertTrue(l.ask("b", now: 0))
        XCTAssertFalse(l.answered("b", now: 200, final: true))    // too late
        XCTAssertTrue(l.ask("c", now: 0))
        XCTAssertTrue(l.answered("c", now: 60, final: false))
        XCTAssertFalse(l.answered("c", now: 95, final: true))     // 90 s from the ask, however many answers came
    }

    func testVNCAddress() {
        XCTAssertEqual(RemoteHelp.vncURL(.ipv4(IPv4Address("192.168.0.7")!))?.absoluteString, "vnc://192.168.0.7")
        let v6 = RemoteHelp.vncURL(.ipv6(IPv6Address("fe80::1")!))?.absoluteString
        XCTAssertEqual(v6, "vnc://[fe80::1]")
    }

    // MARK: Two Macs over loopback

    private func node(_ id: String, friends: @escaping () -> [String]) -> SocialNode {
        let n = SocialNode(myID: id, keys: .memory(), bonjour: false)
        n.friendIDs = friends
        n.me = { ("mac-" + id, .fallback) }
        n.backoff = 0
        return n
    }

    private func pause(_ seconds: TimeInterval) {
        let waited = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { waited.fulfill() }
        wait(for: [waited], timeout: seconds + 5)
    }

    private func port(_ n: SocialNode) -> NWEndpoint {
        let got = expectation(description: "port")
        var port: NWEndpoint.Port?
        n.whenListening { port = $0; got.fulfill() }
        wait(for: [got], timeout: 5)
        return .hostPort(host: "127.0.0.1", port: port!)
    }

    /// A shows a code, B types it: both save the same friend key, then a friend link carries chat both ways.
    func testPairThenChat() throws {
        var aFriends: [String] = [], bFriends: [String] = []
        let a = node("A-id", friends: { aFriends })
        let b = node("B-id", friends: { bFriends })
        defer { a.stop(); b.stop() }
        a.start(); b.start()
        let code = a.showCode()
        var asked: PairHello?, aCheck: String?, bCheck: String?
        a.onPairRequest = { hello, check, answer in asked = hello; aCheck = check; answer(true) }
        // The joiner says yes a moment later, so the host's yes arrives first.
        b.onPairRequest = { _, check, answer in bCheck = check; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(true) } }
        let paired = expectation(description: "paired")
        paired.expectedFulfillmentCount = 2
        a.onPaired = { f in XCTAssertEqual(f.id, "B-id"); XCTAssertEqual(f.nickname, "mac-B-id"); aFriends = [f.id]; paired.fulfill() }
        b.onPaired = { f in XCTAssertEqual(f.id, "A-id"); bFriends = [f.id]; paired.fulfill() }
        b.join(port(a), id: "A-id", code: code)
        wait(for: [paired], timeout: 10)
        XCTAssertEqual(asked?.id, "B-id")
        let keyAB = try XCTUnwrap(a.keys.load("B-id"))
        XCTAssertEqual(keyAB.count, 32)
        XCTAssertEqual(b.keys.load("A-id"), keyAB)
        XCTAssertEqual(aCheck, SocialCrypto.check(keyAB))   // both Macs showed the same 확인 숫자
        XCTAssertEqual(aCheck, bCheck)
        XCTAssertNil(a.code)   // pairing over

        a.relisten()
        let online = expectation(description: "online")
        online.expectedFulfillmentCount = 2
        a.onOnline = { id, on in if on { XCTAssertEqual(id, "B-id"); online.fulfill() } }
        b.onOnline = { id, on in if on { XCTAssertEqual(id, "A-id"); online.fulfill() } }
        let toA = expectation(description: "A hears B")
        let toB = expectation(description: "B hears A")
        a.onMessage = { from, m in XCTAssertEqual(from, "B-id"); if m == .chat("안녕") { toA.fulfill() } }
        b.onMessage = { from, m in XCTAssertEqual(from, "A-id"); if m == .status(.meal) { toB.fulfill() } }
        let at = port(a)
        b.dial("A-id", at: at, salt: a.salt)
        wait(for: [online], timeout: 10)
        // Forward secrecy: the link runs ECDHE-PSK, never plain PSK.
        let m = try XCTUnwrap(b.links["A-id"]?.conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
        XCTAssertEqual(sec_protocol_metadata_get_negotiated_tls_ciphersuite(m.securityProtocolMetadata).rawValue, SocialNode.suite)
        b.send(.chat("안녕"), to: "A-id")
        a.send(.status(.meal), to: "B-id")
        wait(for: [toA, toB], timeout: 10)
        XCTAssertEqual(a.online, ["B-id"])
        XCTAssertEqual(b.online, ["A-id"])

        let off = expectation(description: "offline")
        a.onOnline = { id, on in if !on { XCTAssertEqual(id, "B-id"); off.fulfill() } }
        b.stop()
        wait(for: [off], timeout: 10)
    }

    func testWrongCodeFailsAndThreeTriesMakeANewCode() {
        let a = node("A-id", friends: { [] })
        let b = node("B-id", friends: { [] })
        defer { a.stop(); b.stop() }
        a.start(); b.start()
        let first = a.showCode()
        let wrong = first == "000000" ? "000001" : "000000"
        a.onPaired = { _ in XCTFail("paired with a wrong code") }
        a.onPairRequest = { _, _, _ in XCTFail("a wrong code reached the question") }
        var guessed = false
        a.onPairGuessed = { guessed = true }
        func tryWrong() {
            let failed = expectation(description: "failed")
            b.onPairFailed = { failed.fulfill() }
            b.join(port(a), id: "A-id", code: wrong)
            wait(for: [failed], timeout: 10)
            pause(0.2)
        }
        for _ in 0..<SocialNode.pairTries { tryWrong() }
        XCTAssertNotNil(a.code)
        XCTAssertNotEqual(a.code, first)
        // A port scan or a plain TCP connect is not a wrong code.
        let scan = NWConnection(to: port(a), using: .tcp)
        scan.start(queue: .main)
        pause(0.3)
        scan.cancel()
        pause(0.3)
        let second = a.code
        for _ in 0..<SocialNode.pairTries - 1 { tryWrong() }
        XCTAssertEqual(a.code, second)
        XCTAssertFalse(guessed)
        tryWrong()
        XCTAssertNil(a.code)   // 6 wrong codes end 친구 추가
        XCTAssertTrue(guessed)
    }

    /// Either owner saying no saves nothing on both Macs.
    func testDeclinedPairingSavesNothing() {
        let a = node("A-id", friends: { [] })
        let b = node("B-id", friends: { [] })
        defer { a.stop(); b.stop() }
        a.start(); b.start()
        let code = a.showCode()
        a.onPairRequest = { _, _, answer in answer(true) }
        b.onPairRequest = { _, _, answer in answer(false) }
        a.onPaired = { _ in XCTFail("host saved a declined pairing") }
        b.onPaired = { _ in XCTFail("joiner saved a declined pairing") }
        let failed = expectation(description: "failed")
        b.onPairFailed = { failed.fulfill() }
        b.join(port(a), id: "A-id", code: code)
        wait(for: [failed], timeout: 10)
        pause(0.5)
        XCTAssertNil(a.keys.load("B-id"))
        XCTAssertNil(b.keys.load("A-id"))
    }

    /// The joiner pairs only with the Mac it picked, and neither side lets a pairing replace a friend.
    func testPairingNeverReplacesAFriendOrTakesAnotherMac() {
        for (expect, aFriends) in [("C-id", [String]()), ("A-id", ["B-id"])] {
            let a = node("A-id", friends: { aFriends })
            let b = node("B-id", friends: { [] })
            a.start(); b.start()
            let code = a.showCode()
            a.onPairRequest = { _, _, _ in XCTFail("asked about a pairing that must not happen") }
            b.onPairRequest = { _, _, _ in XCTFail("asked about a pairing that must not happen") }
            let failed = expectation(description: "failed")
            b.onPairFailed = { failed.fulfill() }
            b.join(port(a), id: expect, code: code)
            wait(for: [failed], timeout: 10)
            a.stop(); b.stop()
        }
    }

    /// A Mac that is not a friend (no key, or a made-up one) never gets a message through.
    func testStrangerCannotSend() {
        let a = node("A-id", friends: { ["B-id"] })
        _ = a.keys.save(Data(repeating: 1, count: 32), "B-id")
        let c = node("B-id", friends: { ["A-id"] })   // pretends to be B with the wrong key
        _ = c.keys.save(Data(repeating: 2, count: 32), "A-id")
        defer { a.stop(); c.stop() }
        a.start(); c.start()
        a.onOnline = { _, _ in XCTFail("a stranger came online") }
        a.onMessage = { _, _ in XCTFail("a stranger's message arrived") }
        c.dial("A-id", at: port(a), salt: a.salt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.send(.chat("hi"), to: "A-id") }
        let waited = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { waited.fulfill() }
        wait(for: [waited], timeout: 5)
        XCTAssertTrue(a.online.isEmpty)
    }
}
