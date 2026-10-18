import AppKit
import CoreGraphics
import Foundation

// 비서가 행동하기 v2, native pieces: Messages and Mail.app sends (direct build only), absence mode, and the phone's
// 거절/나중에 buttons. Design: docs/AGENT-DESIGN.md sections 3, 10, 11, 12.

/// Why a Messages or Mail.app send did not happen.
enum NativeSendError: Error, Equatable {
    /// Automation for Messages or Mail is off (-1743) or not asked yet (-1744): fall back to the compose sheet.
    case notAllowed
    case failed(String)
}

#if !MAS   // the App Store build sends nothing through other apps (2.4.5, 2.5.2)
enum AppleScriptText {
    /// An AppleScript string literal. Backslashes and quotes escaped; line breaks as \n and \r so the source stays one line each.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": continue
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// "010-1234-5678", "+82 10 1234 5678": SMS can carry it. Addresses with "@" are iMessage only.
    static func isPhone(_ address: String) -> Bool {
        guard !address.contains("@") else { return false }
        let digits = address.filter(\.isNumber)
        return digits.count >= 7 && address.allSatisfy { $0.isNumber || "+-() .".contains($0) }
    }
}

enum MessagesSender {
    /// Sends `body` to one address: iMessage first, then SMS (phones only, through the iPhone's 문자 forwarding).
    /// macOS 14+ names the recipient class "participant", 13 "buddy" (26 has no "buddy" at all). A term must exist at
    /// compile time, so the choice is made here, not in a try block. -1743/-1744 always propagate so the caller can
    /// fall back to the compose sheet.
    /// ponytail: iMessage to a phone without iMessage may "send" and fail later in Messages; SMS fallback only covers errors.
    static func script(to: String, body: String, legacy: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14) -> String {
        let who = legacy ? "buddy" : "participant"
        func attempt(_ service: String, _ tab: String) -> [String] {
            ["set s to 1st account whose service type = \(service)", "send msg to \(who) addr of s", "return \"\(service)\""]
                .map { tab + $0 }
        }
        var lines = ["set addr to \(AppleScriptText.quote(to))", "set msg to \(AppleScriptText.quote(body))",
                     "tell application \"Messages\""]
        if AppleScriptText.isPhone(to) {
            lines += ["\ttry"] + attempt("iMessage", "\t\t")
                + ["\ton error e number n", "\t\tif n is -1743 or n is -1744 then error e number n", "\tend try"]
                + attempt("SMS", "\t")
        } else {
            lines += attempt("iMessage", "\t")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// One message per address (not a group chat). Stops at the first failure.
    @MainActor
    static func send(to: [String], body: String) throws {
        for a in to { try NativeScript.run(script(to: a, body: body)) }
    }
}

enum MailAppSender {
    /// For iCloud accounts (the app has no iCloud SMTP): Mail.app makes and sends the message, window hidden.
    /// `from` picks Mail's account by address; nil leaves Mail's default.
    static func script(draft: MailDraft, from: String?) -> String {
        var lines = ["tell application \"Mail\""]
        if let from, !from.isEmpty {
            // The card names this account: never let Mail send from another one (error 9001 -> the compose sheet).
            lines += ["\tset found to false",
                      "\trepeat with a in every account",
                      "\t\tif (email addresses of a) contains \(AppleScriptText.quote(from)) then set found to true",
                      "\tend repeat",
                      "\tif not found then error \"no account\" number 9001"]
        }
        lines += ["\tset m to make new outgoing message with properties {subject:\(AppleScriptText.quote(draft.subject)), content:\(AppleScriptText.quote(draft.body)), visible:false}",
                     "\ttell m"]
        for r in draft.to { lines.append("\t\tmake new to recipient at end of to recipients with properties {address:\(AppleScriptText.quote(r.address))}") }
        for r in draft.cc { lines.append("\t\tmake new cc recipient at end of cc recipients with properties {address:\(AppleScriptText.quote(r.address))}") }
        if let from, !from.isEmpty { lines.append("\t\tset sender to \(AppleScriptText.quote(from))") }
        lines += ["\tend tell", "\tif not (send m) then error \"Mail did not send\"", "end tell"]
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func send(draft: MailDraft, from: String?) throws {
        try NativeScript.run(script(draft: draft, from: from))
    }
}

enum NativeScript {
    @MainActor
    static func run(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else { throw NativeSendError.failed(L("스크립트를 만들지 못했어요")) }
        var info: NSDictionary?
        script.executeAndReturnError(&info)
        guard let info else { return }
        throw error(info)
    }

    static func error(_ info: NSDictionary) -> NativeSendError {
        let n = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        if n == -1743 || n == -1744 || n == 9001 { return .notAllowed }   // 9001: Mail has no account with that address
        return .failed((info[NSAppleScript.errorMessage] as? String) ?? L("보내지 못했어요 (오류 \(n))"))
    }
}
#endif

// MARK: - Absence mode

/// The owner is away: no input for 10 minutes, or the screen is locked. Cards wait and the phone gets a push.
enum Absence {
    static let idleLimit: TimeInterval = 600

    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func isAway(idle: TimeInterval, locked: Bool) -> Bool { locked || idle >= idleLimit }

    static var away: Bool { isAway(idle: idleSeconds(), locked: screenLocked()) }
}

// MARK: - Phone 거절/나중에

/// What the owner tapped under a card's push.
enum PhoneReply: String, Equatable { case reject, later }

extension Phone {
    private static let replyTopicKey = "assistant.phone.replyTopic"

    /// The topic the phone's buttons post to and the Mac polls. Made once; a leak only lets someone reject or delay.
    static var replyTopic: String {
        if let t = AppDefaults.store.string(forKey: replyTopicKey), !t.isEmpty { return t }
        let t = newTopic()
        AppDefaults.store.set(t, forKey: replyTopicKey)
        return t
    }

    /// A card push with [거절] [나중에]. Carries only `title` and `body` as given: never the card's content.
    static func cardRequest(topic: String, title: String, body: String, cardID: UUID, replyTopic: String) -> URLRequest? {
        guard let url = URL(string: ntfyServer), !topic.isEmpty, !replyTopic.isEmpty,
              replyTopic.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        func button(_ label: String, _ reply: PhoneReply) -> [String: Any] {
            ["action": "http", "label": label, "url": "\(ntfyServer)/\(replyTopic)", "method": "POST",
             "body": "\(reply.rawValue):\(cardID.uuidString)", "clear": true]
        }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "topic": topic, "title": title, "message": body, "tags": ["computer"],
            "actions": [button(L("거절"), .reject), button(L("나중에"), .later)],
        ])
        return r
    }

    /// ntfy's poll answer, one JSON object per line. Each message moves `since` on (even unknown bodies, so they are
    /// not read again); malformed lines are skipped.
    static func parseReplies(_ data: Data, since: inout String?) -> [(UUID, PhoneReply)] {
        var out: [(UUID, PhoneReply)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (o["event"] as? String ?? "message") == "message" else { continue }
            if let id = o["id"] as? String, !id.isEmpty { since = id }
            let parts = (o["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let reply = PhoneReply(rawValue: String(parts[0])),
                  let card = UUID(uuidString: String(parts[1])) else { continue }
            out.append((card, reply))
        }
        return out
    }

    /// One poll of the reply topic (every minute from the caller). No cursor yet: the last 10 minutes.
    static func pollReplies(since: String?) async -> (replies: [(UUID, PhoneReply)], newSince: String?) {
        let cursor = since ?? "10m"
        guard cursor.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let url = URL(string: "\(ntfyServer)/\(replyTopic)/json?poll=1&since=\(cursor)") else { return ([], since) }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return ([], since) }
            var next = since
            let replies = parseReplies(data, since: &next)
            return (replies, next)
        } catch {
            return ([], since)
        }
    }
}
