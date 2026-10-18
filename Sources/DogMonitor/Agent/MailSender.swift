import Foundation

// 비서가 행동하기 (agent v1): sends one approved mail in the owner's name. SMTP over implicit TLS on 465 (RFC 5321 subset,
// RFC 4954 AUTH PLAIN or LOGIN) with the same app password the IMAP check already uses, on the same NWTransport. No
// third-party code, no server of ours. Only the Executor calls this, and only with a FrozenAction the owner approved.
// Mail rules (design sections 2 and 6): the FrozenAction id seeds the Message-ID, so a resend is the same message; a drop
// once DATA went out is `.unknown` and is never retried by the app; the sent copy is APPENDed only after the final 250.

/// What happened to one send. Only `.failed(_, retryable: true)` may be tried again without asking the owner.
enum MailSendResult: Equatable {
    /// The server took it (250 after the final dot). The Message-ID, with angle brackets.
    case sent(String)
    /// Never accepted. `retryable`: a network failure or a 4xx before the message could have gone out.
    case failed(String, retryable: Bool)
    /// The connection died after DATA: it may have gone out. The owner checks the sent folder; no automatic retry.
    case unknown(String)
}

struct MailSender {
    /// Opens the SMTP connection; tests script a server instead. 60 s, not 30: NWTransport's timeout is for the whole
    /// connection, and a slow upload of a long mail must not be cut into an `.unknown`.
    var connect: (_ host: String, _ port: Int) async throws -> IMAPTransport = { try await NWTransport.open(host: $0, port: $1, timeout: 60) }
    /// Opens the account's IMAP server for the sent copy.
    var connectIMAP: (MailAccount) async throws -> IMAPTransport = { try await NWTransport.open(host: $0.host, port: $0.port) }

    /// Submission over implicit TLS. iCloud offers only STARTTLS on 587 (prepare-only in v1, the compose sheet instead);
    /// a custom IMAP server says nothing about its SMTP server.
    static func smtpEndpoint(for preset: MailPreset) -> (host: String, port: Int)? {
        switch preset {
        case .gmail: return ("smtp.gmail.com", 465)
        case .naver: return ("smtp.naver.com", 465)
        case .daum: return ("smtp.daum.net", 465)
        case .icloud, .custom: return nil
        }
    }

    /// Gmail files every SMTP-sent mail under 보낸편지함 itself (an APPEND would make a second copy). 네이버 and 다음:
    /// unverified (no provider page says either way, 2026-10), so the app APPENDs; a duplicate beats a missing copy.
    static func appendsSentCopy(_ preset: MailPreset) -> Bool { preset == .naver || preset == .daum }

    /// The sending address. 네이버 accounts are stored by ID alone (MailAccounts.add strips @naver.com); 다음 may be too.
    static func address(of a: MailAccount) -> String {
        if a.user.contains("@") { return a.user }
        switch a.preset {
        case .naver: return a.user + "@naver.com"
        case .daum: return a.user + "@daum.net"
        case .icloud: return a.user + "@icloud.com"
        case .gmail: return a.user + "@gmail.com"
        case .custom: return a.user + "@" + a.host
        }
    }

    /// Sends `draft` from `account`. `seed` is the FrozenAction id (same id, same Message-ID); `inReplyTo` is the
    /// original's Message-ID for a reply. `fromName` is the display name (the owner's name, if the app knows it).
    func send(draft: MailDraft, from account: MailAccount, password: String, messageID seed: UUID, inReplyTo: String?,
              now: Date, fromName: String? = nil) async -> MailSendResult {
        guard let end = Self.smtpEndpoint(for: account.preset) else {
            return .failed(L("이 메일 계정은 앱에서 바로 보낼 수 없어요. 메일 앱에서 보내 주세요."), retryable: false)
        }
        let from = Self.address(of: account)
        let rcpts = (draft.to + draft.cc).map(\.address)
        guard MailMessage.isPlainAddress(from) else { return .failed(L("보내는 주소를 확인해 주세요."), retryable: false) }
        if draft.to.isEmpty { return .failed(L("받는 주소를 확인해 주세요."), retryable: false) }
        if let bad = rcpts.first(where: { !MailMessage.isPlainAddress($0) }) {
            return .failed(L("받는 주소를 확인해 주세요: \(bad)"), retryable: false)
        }
        let id = MailMessage.messageID(seed: seed, from: from)
        let message = MailMessage.build(from: from, fromName: fromName, to: draft.to, cc: draft.cc, subject: draft.subject,
                                        body: draft.body, messageID: id, inReplyTo: inReplyTo, date: now)
        let t: IMAPTransport
        do { t = try await connect(end.host, end.port) } catch { return .failed(Self.offline, retryable: true) }
        let result = await SMTPSession(t).deliver(user: account.loginName, password: password, from: from, to: rcpts,
                                                  message: message, id: id)
        t.close()
        if case .sent = result, Self.appendsSentCopy(account.preset), let imap = try? await connectIMAP(account) {
            // ponytail: a failed APPEND is silent (the mail did go out); surface it if owners miss sent copies.
            _ = await SentCopy.append(imap, user: account.loginName, password: password, message: message)
        }
        return result
    }

    static var offline: String { L("메일 서버에 연결하지 못했어요. 인터넷 연결을 확인하고 다시 보내 주세요.") }
}

/// One SMTP reply: the three-digit code and every line's text (multi-line "250-" replies joined).
struct SMTPReply: Equatable {
    var code: Int
    var lines: [String]
}

/// Cuts the byte stream into replies: "250-a" lines go on until a "250 b" line. Pure.
struct SMTPReader {
    private var buf: [UInt8] = []
    private var lines: [String] = []
    var size: Int { buf.count }

    mutating func feed(_ d: Data) { buf += d }

    /// The next complete reply, nil while more bytes are needed. A line without a code reads as code 0 (an error).
    mutating func next() -> SMTPReply? {
        while let lf = buf.firstIndex(of: 10) {
            var line = String(decoding: buf[..<lf], as: UTF8.self)
            buf.removeFirst(lf + 1)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            let more = line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
            if !more {
                defer { lines = [] }
                return SMTPReply(code: Int(line.prefix(3)) ?? 0, lines: lines)
            }
        }
        return nil
    }
}

/// One submission: greeting, EHLO, AUTH, MAIL, RCPT per recipient, DATA, QUIT.
final class SMTPSession {
    private let t: IMAPTransport
    private var reader = SMTPReader()
    /// EHLO and a reply or two: a few KB. More than this is not a mail server.
    static let maxBuffer = 1 << 16

    init(_ t: IMAPTransport) { self.t = t }

    private func read() async throws -> SMTPReply {
        while true {
            if let r = reader.next() { return r }
            guard reader.size < Self.maxBuffer else { throw IMAPError.server("reply too large") }
            let d = try await t.receive()
            guard !d.isEmpty else { throw IMAPError.network("connection closed") }
            reader.feed(d)
        }
    }

    private func command(_ line: String) async throws -> SMTPReply {
        try await t.send(Data((line + "\r\n").utf8))
        return try await read()
    }

    /// The whole conversation. Every early return is a reply the server gave; a thrown error is the network.
    func deliver(user: String, password: String, from: String, to: [String], message: Data, id: String) async -> MailSendResult {
        // Set once the DATA command is out. Conservative: until the body's final dot the server cannot have taken it,
        // but the design rule is "after DATA, never retry", and a needless "check your sent folder" costs little.
        var dataSent = false
        do {
            var r = try await read()
            guard r.code == 220 else { return Self.refused(r) }
            r = try await command("EHLO [127.0.0.1]")
            guard r.code == 250 else { return Self.refused(r) }
            let auth = Self.authMethods(r)
            if auth.contains("PLAIN") {
                r = try await command("AUTH PLAIN " + Data("\0\(user)\0\(password)".utf8).base64EncodedString())
            } else if auth.contains("LOGIN") {
                r = try await command("AUTH LOGIN")
                guard r.code == 334 else { return Self.loginRefused(r) }
                r = try await command(Data(user.utf8).base64EncodedString())
                guard r.code == 334 else { return Self.loginRefused(r) }
                r = try await command(Data(password.utf8).base64EncodedString())
            } else {
                return .failed(L("메일 서버가 앱 비밀번호 로그인을 받지 않아요."), retryable: false)
            }
            guard r.code == 235 else { return Self.loginRefused(r) }
            r = try await command("MAIL FROM:<\(from)>")
            guard r.code == 250 else { return Self.refused(r) }
            for a in to {
                r = try await command("RCPT TO:<\(a)>")
                guard r.code == 250 || r.code == 251 else {
                    if (500..<600).contains(r.code) { return .failed(L("받는 주소를 확인해 주세요: \(a)"), retryable: false) }
                    return Self.refused(r)
                }
            }
            dataSent = true
            r = try await command("DATA")
            guard r.code == 354 else { return Self.refused(r) }
            try await t.send(MailMessage.dotStuffed(message) + Data(".\r\n".utf8))
            r = try await read()
            guard r.code == 250 else { return Self.refused(r) }   // a clear no: not sent
            _ = try? await command("QUIT")
            return .sent(id)
        } catch {
            return dataSent ? .unknown(L("보냈는지 확실하지 않아요. 보낸메일함을 확인해 주세요."))
                            : .failed(MailSender.offline, retryable: true)
        }
    }

    /// "250-AUTH LOGIN PLAIN XOAUTH2" (and the old "250-AUTH=LOGIN") -> ["LOGIN", "PLAIN", "XOAUTH2"].
    static func authMethods(_ r: SMTPReply) -> Set<String> {
        var out = Set<String>()
        for line in r.lines {
            let words = line.dropFirst(4).uppercased().split(whereSeparator: { $0 == " " || $0 == "=" })
            if words.first == "AUTH" { words.dropFirst().forEach { out.insert(String($0)) } }
        }
        return out
    }

    /// 535 is the password; Gmail's 534 is "use an app password". 454 is the server's own trouble: later.
    static func loginRefused(_ r: SMTPReply) -> MailSendResult {
        if r.code == 535 || r.code == 534 {
            return .failed(L("로그인에 실패했어요. 앱 비밀번호를 확인해 주세요."), retryable: false)
        }
        return refused(r)
    }

    /// 4xx: try again later. 5xx (or nonsense): no.
    static func refused(_ r: SMTPReply) -> MailSendResult {
        let text = r.lines.last.map { String($0.prefix(80)) } ?? ""
        return .failed(L("메일 서버가 거절했어요: \(text)"), retryable: (400..<500).contains(r.code))
    }
}

/// The message itself (RFC 5322 + MIME). Pure: the same inputs give the same bytes.
enum MailMessage {
    /// 39 bytes -> 52 base64 chars -> "=?UTF-8?B?" + 52 + "?=" = 64: under RFC 2047's 75, and "Subject: " plus one
    /// word stays under RFC 5322's 78-character line.
    static let wordBytes = 39

    static func build(from: String, fromName: String?, to: [Recipient], cc: [Recipient], subject: String, body: String,
                      messageID: String, inReplyTo: String?, date: Date, timeZone: TimeZone = .current) -> Data {
        var h = ["Date: " + dateHeader(date, timeZone), "From: " + mailbox(fromName, from),
                 "To: " + to.map { mailbox($0.name, $0.address) }.joined(separator: ",\r\n ")]
        if !cc.isEmpty { h.append("Cc: " + cc.map { mailbox($0.name, $0.address) }.joined(separator: ",\r\n ")) }
        h.append("Subject: " + text(subject))
        h.append("Message-ID: " + messageID)
        // ponytail: References holds only the parent, not its own References chain; threading still works in
        // Gmail, Naver and Apple Mail. Carry the chain if a client splits threads.
        if let parent = inReplyTo.flatMap(bracketed) { h += ["In-Reply-To: " + parent, "References: " + parent] }
        h += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        let crlf = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let b64 = Data(crlf.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + b64 + "\r\n").utf8)
    }

    /// "<uuid@domain>": the same FrozenAction id always gives the same id, so a resend is recognisably one message.
    static func messageID(seed: UUID, from: String) -> String {
        "<\(seed.uuidString.lowercased())@\(from.split(separator: "@").last.map(String.init) ?? "localhost")>"
    }

    /// RFC 5322 date, English names whatever the Mac's language.
    static func dateHeader(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }

    /// A header text: short printable ASCII as it is, anything else as RFC 2047 words. Line breaks never get through
    /// (no header injection from a subject or a name).
    static func text(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let plain = flat.count <= 60 && !flat.contains("=?") && flat.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        return plain ? flat : words(flat)
    }

    /// UTF-8 base64 encoded-words, folded one per line. Cut on scalar boundaries, so every word decodes on its own.
    static func words(_ s: String) -> String {
        var chunks: [Data] = [], cur = Data()
        for sc in s.unicodeScalars {
            let b = Data(String(sc).utf8)
            if cur.count + b.count > wordBytes { chunks.append(cur); cur = Data() }
            cur += b
        }
        chunks.append(cur)
        return chunks.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    /// "\"Kim\" <kim@x.com>", "=?UTF-8?B?...?= <kim@x.com>", or the bare address.
    static func mailbox(_ name: String?, _ address: String) -> String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return address }
        let ascii = n.count <= 60 && n.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        let phrase = ascii ? "\"" + n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                           : text(n)
        return "\(phrase) <\(address)>"
    }

    /// "abc@x" or "<abc@x>" -> "<abc@x>"; nil for anything that is not one plain id (spaces, line breaks, non-ASCII).
    static func bracketed(_ id: String) -> String? {
        let t = id.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "<" && $0 != ">" }) else { return nil }
        return "<\(t)>"
    }

    /// One ASCII address with one @ and no spaces, brackets or line breaks: safe inside "RCPT TO:<...>" and a header.
    /// ponytail: no SMTPUTF8, so a Korean local part is refused; add it if owners mail such addresses.
    static func isPlainAddress(_ a: String) -> Bool {
        let parts = a.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".")
            && a.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !"<>(),;:\\\"[]".unicodeScalars.contains($0) }
    }

    /// DATA transparency (RFC 5321 4.5.2): a line starting with "." gets one more. The base64 body never has one,
    /// but a header line could, and the wire must never see a lone "." line before the end.
    static func dotStuffed(_ d: Data) -> Data {
        var out = Data(capacity: d.count + 8)
        var lineStart = true
        for b in d {
            if lineStart && b == UInt8(ascii: ".") { out.append(b) }
            out.append(b)
            lineStart = b == 10
        }
        return out
    }
}

/// The sent copy, for servers that do not file SMTP mail themselves: LOGIN, LIST to find the \Sent folder (RFC 6154),
/// APPEND with a synchronizing literal and \Seen, LOGOUT. Its own little loop: IMAPSession cannot wait for the "+".
enum SentCopy {
    /// True once the server said OK to the APPEND. Never throws: the mail already went out.
    static func append(_ t: IMAPTransport, user: String, password: String, message: Data) async -> Bool {
        var reader = IMAPReader()
        var count = 0
        defer { t.close() }

        func read() async throws -> IMAPResponse {
            while true {
                if let r = reader.next() { return r }
                guard reader.size < IMAPSession.maxBuffer else { throw IMAPError.server("response too large") }
                let d = try await t.receive()
                guard !d.isEmpty else { throw IMAPError.network("connection closed") }
                reader.feed(d)
            }
        }
        /// Sends a tagged command; returns the untagged lines once its OK comes. `literal` goes after the "+".
        func command(_ cmd: String, literal: Data? = nil) async throws -> [IMAPResponse] {
            count += 1
            let tag = "a\(count)"
            try await t.send(Data("\(tag) \(cmd)\r\n".utf8))
            var lines: [IMAPResponse] = []
            var pending = literal
            while true {
                let r = try await read()
                if r.text.hasPrefix("+"), let l = pending {
                    pending = nil
                    try await t.send(l + Data("\r\n".utf8))
                } else if r.tag == tag {
                    guard r.text.dropFirst(tag.count + 1).hasPrefix("OK") else { throw IMAPError.server(r.text) }
                    return lines
                } else {
                    lines.append(r)
                }
            }
        }

        do {
            guard try await read().text.hasPrefix("* OK"),
                  let u = IMAPSession.quoted(user), let p = IMAPSession.quoted(password) else { return false }
            _ = try await command("LOGIN \(u) \(p)")
            guard let box = sentFolder(try await command("LIST \"\" \"*\"")), let q = IMAPSession.quoted(box) else { return false }
            _ = try await command("APPEND \(q) (\\Seen) {\(message.count)}", literal: message)
            _ = try? await command("LOGOUT")
            return true
        } catch {
            return false
        }
    }

    /// The folder flagged \Sent, else one named like a sent folder. Quoted or atom names only.
    /// ponytail: a literal or modified-UTF-7 (Korean) name is skipped; read those if a provider uses one.
    static func sentFolder(_ lines: [IMAPResponse]) -> String? {
        var named: String?
        for r in lines {
            guard let m = r.text.range(of: #"^\* LIST \(([^)]*)\) (?:"(?:[^"\\]|\\.)*"|NIL) "#, options: .regularExpression) else { continue }
            var name = String(r.text[m.upperBound...])
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            } else if name.contains(" ") || name.hasSuffix("}") { continue }
            if r.text[m].contains("\\Sent") { return name }
            if named == nil, ["sent messages", "sent", "sent items", "sent mail"].contains(name.lowercased()) { named = name }
        }
        return named
    }
}
