import XCTest
@testable import DogMonitor

/// Telling the owner what went wrong and how the app works: provider error bodies, the one busy retry, 문제 보내기
/// masking, the update one-liner and the first-run tour.
final class SupportTests: XCTestCase {
    private func replies(_ answers: [(Int, String)], count: @escaping () -> Void = {}) -> BYOAPIClient.Transport {
        var left = answers
        return { r in
            count()
            let (code, body) = left.count > 1 ? left.removeFirst() : left[0]
            return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: Error bodies

    func testErrorBodiesSayWhatReallyHappened() {
        func say(_ p: BYOProvider, _ status: Int, _ body: String) -> String { BYOAPIClient.failure(p, status: status, body: Data(body.utf8)).message }
        let noCredit = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        XCTAssertTrue(say(.chatgpt, 429, noCredit).contains("구독과 API 요금은 따로"))
        XCTAssertTrue(say(.chatgpt, 429, #"{"error":{"type":"requests","code":"rate_limit_exceeded"}}"#).contains("잠깐 걸렸어요"))
        let lowBalance = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#
        XCTAssertTrue(say(.claude, 400, lowBalance).contains("크레딧이 부족"))
        XCTAssertTrue(say(.claude, 529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#).contains("붐벼요"))
        XCTAssertTrue(say(.gemini, 503, #"{"error":{"code":503,"status":"UNAVAILABLE"}}"#).contains("붐벼요"))
        let perDay = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}"#
        XCTAssertTrue(say(.gemini, 429, perDay).contains("오늘 무료 사용 한도"))
        // Anything else echoes the provider's words, with a key it repeats masked.
        let echoed = say(.chatgpt, 400, #"{"error":{"message":"Bad key sk-proj-ABCDEF123456 here"}}"#)
        XCTAssertTrue(echoed.contains("(400)") && echoed.contains("Bad key"))
        XCTAssertFalse(echoed.contains("ABCDEF123456"))
    }

    // MARK: One retry, only when nothing was billed

    func testRetriesOnceOnlyWhenBusy() async throws {
        for (first, retried) in [(503, true), (529, true), (429, true), (401, false), (500, false)] {
            var calls = 0
            let c = BYOAPIClient(provider: .claude, key: "k", transport: replies([(first, "{}"), (200, #"{"data":[{"id":"claude-opus-5-5"}]}"#)]) { calls += 1 },
                                 pause: { _ in })
            _ = try? await c.models()
            XCTAssertEqual(calls, retried ? 2 : 1, "\(first)")
        }
        // A used-up quota is not retried, and a second busy answer is the last.
        let quota = #"{"error":{"code":"insufficient_quota"}}"#
        for answers in [[(429, quota)], [(503, "{}"), (503, "{}"), (200, "{}")]] {
            var calls = 0
            let c = BYOAPIClient(provider: .chatgpt, key: "k", transport: replies(answers) { calls += 1 }, pause: { _ in })
            do { _ = try await c.models(); XCTFail("should fail") } catch {}
            XCTAssertEqual(calls, answers.count == 1 ? 1 : 2)
        }
    }

    func testConnectionCheckKeepsAKeyThatIsOnlyBusy() async throws {
        let busy = try await BYOAPIClient(provider: .gemini, key: "k", transport: replies([(429, "{}")])).check()
        XCTAssertTrue(busy.models.isEmpty)
        XCTAssertTrue(busy.note?.contains("연결은 됐어요") ?? false)
        do { _ = try await BYOAPIClient(provider: .gemini, key: "k", transport: replies([(401, "{}")])).check(); XCTFail("bad key") } catch {}
    }

    // MARK: 문제 보내기

    func testReportMasksSecrets() {
        let text = """
        claude sk-ant-api03-SECRETSECRET gemini AIzaSyA1234567890abcdefghij
        Authorization: Bearer abc.def-123 me@example.com /Users/owner/Library topic jelly-abc123xyz
        """
        let out = Redact.secrets(text, topic: "jelly-abc123xyz", home: "/Users/owner")
        for leak in ["SECRETSECRET", "AIzaSyA1234567890", "abc.def-123", "me@example.com", "/Users/owner", "abc123xyz"] {
            XCTAssertFalse(out.contains(leak), leak)
        }
        XCTAssertTrue(out.contains("~/Library"))
        let url = Diagnostics.mailURL(String(repeating: "가", count: 5000))!.absoluteString
        XCTAssertTrue(url.hasPrefix("mailto:\(Diagnostics.supportMail)?"))
        XCTAssertLessThan(url.removingPercentEncoding!.count, Diagnostics.mailLimit + 200)
    }

    // MARK: 업데이트 후 한마디 and the tour

    func testWhatsNewOnlyAfterAnUpdate() {
        XCTAssertFalse(WhatsNew.announces(last: nil, current: "2.2"))   // a first install
        XCTAssertTrue(WhatsNew.announces(last: "2.1", current: "2.2"))
        XCTAssertTrue(WhatsNew.announces(last: "2.9", current: "2.10"))
        XCTAssertFalse(WhatsNew.announces(last: "2.2", current: "2.2"))
        XCTAssertFalse(WhatsNew.announces(last: "2.3", current: "2.2"))
    }

    func testUpdateFromBeforeWhatsNewSkipsTourAndAnnounces() {
        let d = UserDefaults(suiteName: "SupportTests.upgrade")!
        d.removePersistentDomain(forName: "SupportTests.upgrade")
        WhatsNew.noteUpgrade(d)                       // a fresh install: nothing to note
        XCTAssertNil(d.string(forKey: WhatsNew.key))
        XCTAssertFalse(d.bool(forKey: Tour.seenKey))
        d.set("rarely", forKey: "assistant.nudges")   // an older build ran here
        WhatsNew.noteUpgrade(d)
        XCTAssertTrue(d.bool(forKey: Tour.seenKey))
        XCTAssertTrue(WhatsNew.announces(last: d.string(forKey: WhatsNew.key), current: "2.2"))
    }

    /// 2.3 removes what only the paid code wrote, once, and an update from the paid era still counts as one.
    func testOpenSourceCleanupRemovesThePaidEraOnce() throws {
        let suite = "SupportTests.cleanup.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        for key in OpenSourceCleanup.removedKeys { d.set("x", forKey: key) }
        d.set("cat", forKey: "assistant.persona")
        OpenSourceCleanup.run(d, settings: AppSettings(defaults: d))
        for key in OpenSourceCleanup.removedKeys { XCTAssertNil(d.object(forKey: key), key) }
        XCTAssertEqual(d.string(forKey: "assistant.persona"), "cat")
        // "proLicenseKey" was the only sign of an update here: no tour, the one-liner shows, 먼저 말 걸기 stays off.
        XCTAssertTrue(d.bool(forKey: Tour.seenKey))
        XCTAssertTrue(WhatsNew.announces(last: d.string(forKey: WhatsNew.key), current: "2.3"))
        XCTAssertEqual(d.string(forKey: "assistant.nudges"), NudgeFrequency.off.rawValue)
        d.set("x", forKey: "proNotice")
        OpenSourceCleanup.run(d, settings: AppSettings(defaults: d))
        XCTAssertEqual(d.string(forKey: "proNotice"), "x", "once")
    }

    func testOpenSourceCleanupLeavesANewInstallNew() throws {
        let suite = "SupportTests.cleanup-new.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        OpenSourceCleanup.run(d, settings: AppSettings(defaults: d))
        XCTAssertNil(d.string(forKey: WhatsNew.key))
        XCTAssertFalse(d.bool(forKey: Tour.seenKey))
        XCTAssertEqual(d.string(forKey: "assistant.nudges"), NudgeFrequency.rarely.rawValue)
        XCTAssertFalse(d.bool(forKey: OpenSourceCleanup.goodbyeKey))
    }

    /// The guitar girl retired: her fans get the dog and one goodbye, her 지운 캐릭터 entry and profile go.
    func testGuitarGirlFansGetTheDogAndOneGoodbye() throws {
        let suite = "SupportTests.girl.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("girl", forKey: "character")
        d.set(try JSONEncoder().encode(["girl", "cat-korean-shorthair"]), forKey: "hiddenCharacters")
        d.set(Data("{}".utf8), forKey: "girl")
        let s = AppSettings(defaults: d)
        OpenSourceCleanup.run(d, settings: s)
        XCTAssertEqual(d.string(forKey: "character"), "dog")
        XCTAssertEqual(s.hiddenCharacters, ["cat-korean-shorthair"])
        XCTAssertEqual(AppSettings(defaults: d).hiddenCharacters, ["cat-korean-shorthair"])
        XCTAssertNil(d.object(forKey: "girl"))

        let bubble = SpeechBubbleCenter()
        bubble.isMuted = { true }
        XCTAssertFalse(OpenSourceCleanup.sayGoodbye(d, on: bubble))   // muted: the next launch tries again
        bubble.isMuted = { false }
        XCTAssertTrue(OpenSourceCleanup.sayGoodbye(d, on: bubble))
        XCTAssertEqual(bubble.current?.text, OpenSourceCleanup.goodbye)
        XCTAssertFalse(OpenSourceCleanup.goodbye.contains("\u{2014}"))
        XCTAssertFalse(OpenSourceCleanup.sayGoodbye(d, on: SpeechBubbleCenter()), "once")

        // Her name as builds before 1.4 saved it counts too; anyone else keeps their character and hears nothing.
        for (stored, goodbye) in [(String("irotih".reversed()), true), ("cat", false)] {
            let other = try XCTUnwrap(UserDefaults(suiteName: suite + stored))
            defer { other.removePersistentDomain(forName: suite + stored) }
            other.set(stored, forKey: "character")
            OpenSourceCleanup.run(other, settings: AppSettings(defaults: other))
            XCTAssertEqual(other.string(forKey: "character"), goodbye ? "dog" : stored)
            XCTAssertEqual(other.bool(forKey: OpenSourceCleanup.goodbyeKey), goodbye, stored)
        }
    }

    func testRetryIgnoresANegativeRetryAfter() async throws {
        var calls = 0, waited: [TimeInterval] = []
        var client = BYOAPIClient(provider: .claude, key: "k")
        client.transport = { r in
            calls += 1
            let code = calls == 1 ? 429 : 200
            return (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "-1"])!)
        }
        client.pause = { waited.append($0) }
        _ = try await client.send(URLRequest(url: URL(string: "https://example.invalid")!))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(waited, [2])
    }

    func testTourStepsOnClickAndIsSeenOnlyWhenShown() {
        let d = UserDefaults(suiteName: "SupportTests.tour")!
        d.removePersistentDomain(forName: "SupportTests.tour")
        let bubble = SpeechBubbleCenter()
        bubble.isMuted = { true }
        Tour.start(d, on: bubble)
        XCTAssertFalse(d.bool(forKey: Tour.seenKey))   // muted: try again next launch
        bubble.isMuted = { false }
        Tour.start(d, on: bubble)
        XCTAssertTrue(d.bool(forKey: Tour.seenKey))
        XCTAssertTrue(bubble.current?.text.hasPrefix("(1/4)") ?? false)
        XCTAssertEqual(bubble.current?.seconds, Tour.stay)
        XCTAssertFalse(Tour.advance("다른 말풍선", on: bubble))
        for n in 2...4 {
            XCTAssertTrue(Tour.advance(bubble.current!.text, on: bubble))
            XCTAssertTrue(bubble.current?.text.hasPrefix("(\(n)/4)") ?? false)
        }
        XCTAssertTrue(Tour.advance(bubble.current!.text, on: bubble))
        XCTAssertNil(bubble.current)
        XCTAssertNil(Tour.step)
        for polite in [false, true] { XCTAssertEqual(Tour.lines(polite: polite).count, 4) }
        // 사용법 다시 보기 shows even while muted, every step, under the menu bar icon.
        bubble.isMuted = { true }
        Tour.start(d, on: bubble, asked: true)
        XCTAssertTrue(bubble.current?.text.hasPrefix("(1/4)") ?? false)
        XCTAssertTrue(bubble.current?.atIcon ?? false)
        XCTAssertTrue(Tour.advance(bubble.current!.text, on: bubble))
        XCTAssertTrue(bubble.current?.text.hasPrefix("(2/4)") ?? false)
        Tour.start(d, on: bubble)   // the launch tour still keeps quiet while muted
        XCTAssertTrue(bubble.current?.text.hasPrefix("(2/4)") ?? false)
    }
}
