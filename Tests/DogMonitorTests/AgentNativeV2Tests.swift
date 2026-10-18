import XCTest
@testable import DogMonitor

/// Messages/Mail.app scripts (built, never sent), absence thresholds and the phone's 거절/나중에 round trip.
final class AgentNativeV2Tests: XCTestCase {
    // MARK: AppleScript text

    func testQuoteEscapesAndKeepsOneLine() {
        XCTAssertEqual(AppleScriptText.quote(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(AppleScriptText.quote("첫 줄\n둘\r셋"), #""첫 줄\n둘\r셋""#)
        XCTAssertFalse(AppleScriptText.quote("x\ny\"; do shell script \"rm\"").contains("\n"))
    }

    /// The literal compiles back to the same text: AppleScript itself checks the escaping (no app is addressed).
    @MainActor
    func testQuoteRoundTripsThroughAppleScript() throws {
        for s in ["따옴표 \"안\" 백슬래시 \\ 끝", "줄\n바꿈\r\n탭\t", "end tell\" & (do shell script \"echo hi\") & \"", "🐶 이모지"] {
            let script = try XCTUnwrap(NSAppleScript(source: "return " + AppleScriptText.quote(s)))
            var err: NSDictionary?
            let out = script.executeAndReturnError(&err)
            XCTAssertNil(err)
            XCTAssertEqual(out.stringValue, s)
        }
    }

    func testIsPhone() {
        XCTAssertTrue(AppleScriptText.isPhone("010-1234-5678"))
        XCTAssertTrue(AppleScriptText.isPhone("+82 10 1234 5678"))
        XCTAssertFalse(AppleScriptText.isPhone("kim@x.com"))
        XCTAssertFalse(AppleScriptText.isPhone("1234"))
        XCTAssertFalse(AppleScriptText.isPhone("010-1234-5678 abc"))
    }

    #if !MAS
    func testMessagesScriptPhoneFallsBackToSMS() {
        let s = MessagesSender.script(to: "010-1234-5678", body: "내일 \"10시\"\n봬요", legacy: false)
        XCTAssertTrue(s.contains(#"set msg to "내일 \"10시\"\n봬요""#))
        XCTAssertTrue(s.contains("service type = iMessage"))
        XCTAssertTrue(s.contains("service type = SMS"))
        XCTAssertTrue(s.contains("send msg to participant addr of s"))
        XCTAssertTrue(s.contains("if n is -1743 or n is -1744 then error e number n"))
        XCTAssertFalse(s.contains("buddy"))
    }

    func testMessagesScriptAddressIsIMessageOnlyAndLegacyUsesBuddy() {
        let s = MessagesSender.script(to: "kim@x.com", body: "hi", legacy: true)
        XCTAssertFalse(s.contains("SMS"))
        XCTAssertTrue(s.contains("send msg to buddy addr of s"))
        XCTAssertFalse(s.contains("participant"))
    }

    func testMailScript() {
        let d = MailDraft(accountID: nil, to: [Recipient(name: "김", address: "kim@x.com", provenance: .ownerWords)],
                          cc: [Recipient(name: nil, address: "lee@y.com", provenance: .contact)],
                          subject: "회의 \"변경\"", body: "안녕하세요\n10시로 옮겨요 \\ 끝")
        let s = MailAppSender.script(draft: d, from: "me@icloud.com")
        XCTAssertTrue(s.contains(#"subject:"회의 \"변경\"""#))
        XCTAssertTrue(s.contains(#"content:"안녕하세요\n10시로 옮겨요 \\ 끝""#))
        XCTAssertTrue(s.contains("visible:false"))
        XCTAssertTrue(s.contains(#"make new to recipient at end of to recipients with properties {address:"kim@x.com"}"#))
        XCTAssertTrue(s.contains(#"make new cc recipient at end of cc recipients with properties {address:"lee@y.com"}"#))
        XCTAssertTrue(s.contains(#"set sender to "me@icloud.com""#))
        XCTAssertTrue(s.contains("send m"))
        XCTAssertFalse(MailAppSender.script(draft: d, from: nil).contains("sender"))
    }

    func testScriptErrorMapping() {
        XCTAssertEqual(NativeScript.error([NSAppleScript.errorNumber: -1743]), .notAllowed)
        XCTAssertEqual(NativeScript.error([NSAppleScript.errorNumber: -1744]), .notAllowed)
        XCTAssertEqual(NativeScript.error([NSAppleScript.errorNumber: -1728, NSAppleScript.errorMessage: "없음"]), .failed("없음"))
    }
    #endif

    // MARK: Absence

    func testAbsenceThresholds() {
        XCTAssertFalse(Absence.isAway(idle: 0, locked: false))
        XCTAssertFalse(Absence.isAway(idle: 599, locked: false))
        XCTAssertTrue(Absence.isAway(idle: 600, locked: false))
        XCTAssertTrue(Absence.isAway(idle: 5, locked: true))
        XCTAssertGreaterThanOrEqual(Absence.idleSeconds(), 0)
    }

    // MARK: Phone 거절/나중에

    func testCardRequestCarriesOnlyTitleBodyAndButtons() throws {
        let id = UUID()
        let r = try XCTUnwrap(Phone.cardRequest(topic: "charamonitor-abc", title: "캐릭모니터", body: "확인할 일 1건",
                                                cardID: id, replyTopic: "charamonitor-reply"))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["topic", "title", "message", "tags", "actions"])
        XCTAssertEqual(o["message"] as? String, "확인할 일 1건")
        let actions = try XCTUnwrap(o["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["label"] as? String }, ["거절", "나중에"])
        XCTAssertEqual(actions.map { $0["body"] as? String }, ["reject:\(id.uuidString)", "later:\(id.uuidString)"])
        for a in actions {
            XCTAssertEqual(a["action"] as? String, "http")
            XCTAssertEqual(a["method"] as? String, "POST")
            XCTAssertEqual(a["url"] as? String, "https://ntfy.sh/charamonitor-reply")
            XCTAssertEqual(a["clear"] as? Bool, true)
            XCTAssertEqual(Set(a.keys), ["action", "label", "url", "method", "body", "clear"])
        }
        XCTAssertNil(Phone.cardRequest(topic: "t", title: "", body: "", cardID: id, replyTopic: "../x"))
        XCTAssertNil(Phone.cardRequest(topic: "t", title: "", body: "", cardID: id, replyTopic: ""))
    }

    func testReplyTopicIsMadeOnceAndKept() {
        let saved = AppDefaults.store
        let d = UserDefaults(suiteName: "native-\(UUID().uuidString)")!
        AppDefaults.store = d
        defer { AppDefaults.store = saved }
        let t = Phone.replyTopic
        XCTAssertTrue(t.hasPrefix("charamonitor-"))
        XCTAssertEqual(Phone.replyTopic, t)
    }

    func testParseRepliesMovesCursorAndSkipsJunk() {
        let a = UUID(), b = UUID()
        let lines = [
            #"{"id":"m1","time":1,"event":"message","topic":"r","message":"reject:\#(a.uuidString)"}"#,
            "not json",
            #"{"id":"m2","event":"message","message":"hello"}"#,
            #"{"id":"k1","event":"keepalive"}"#,
            #"{"id":"m3","event":"message","message":"later:\#(b.uuidString.lowercased())"}"#,
            #"{"id":"m4","event":"message","message":"approve:\#(a.uuidString)"}"#,
            #"{"id":"m5","event":"message","message":"reject:not-a-uuid"}"#,
        ]
        var since: String? = nil
        let out = Phone.parseReplies(Data(lines.joined(separator: "\n").utf8), since: &since)
        XCTAssertEqual(out.map(\.0), [a, b])
        XCTAssertEqual(out.map(\.1), [.reject, .later])
        XCTAssertEqual(since, "m5")
        var kept: String? = "m9"
        XCTAssertTrue(Phone.parseReplies(Data("\n{bad\n".utf8), since: &kept).isEmpty)
        XCTAssertEqual(kept, "m9")
    }
}
