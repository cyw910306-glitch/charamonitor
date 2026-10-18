import Foundation
import Network

// 메일 계정 알림 (AI 비서, both builds): a minimal read-only IMAP client (RFC 3501 subset) over TLS.
// LOGIN, EXAMINE INBOX (read-only select), UID FETCH of From/Subject/Date with BODY.PEEK: nothing is ever marked
// read, no body is ever fetched. Sender and subject live in memory only, like every other inbox line.

/// One server response: the line text (literal bytes left out, their {n} marker kept) and the literals in order.
struct IMAPResponse: Equatable {
    var text: String
    var literals: [Data] = []

    /// "a3" for "a3 OK ...", nil for untagged ("*") and continuation ("+") lines.
    var tag: String? {
        let first = text.prefix { $0 != " " }
        return first == "*" || first == "+" || first.isEmpty ? nil : String(first)
    }
}

/// Cuts the byte stream into responses: a line ending in {n} carries n raw bytes, then the line goes on. Pure.
struct IMAPReader {
    private var buf: [UInt8] = []
    var size: Int { buf.count }

    mutating func feed(_ d: Data) { buf += d }

    /// The next complete response, nil while more bytes are needed.
    mutating func next() -> IMAPResponse? {
        var i = 0, text = "", literals: [Data] = []
        while true {
            guard let end = Self.crlf(buf, from: i) else { return nil }
            let line = String(decoding: buf[i..<end], as: UTF8.self)
            text += line
            i = end + 2
            if let n = Self.literalLength(line) {
                guard n <= buf.count - i else { return nil }   // no i + n: a huge n would overflow
                literals.append(Data(buf[i..<(i + n)]))
                i += n
                continue
            }
            buf.removeFirst(i)
            return IMAPResponse(text: text, literals: literals)
        }
    }

    private static func crlf(_ b: [UInt8], from: Int) -> Int? {
        var j = from
        while j + 1 < b.count {
            if b[j] == 13 && b[j + 1] == 10 { return j }
            j += 1
        }
        return nil
    }

    /// "... {123}" or "... {123+}" at the end of a line. Digits only and at most maxBuffer: "{-5}" or a 19-digit
    /// count from a hostile server is not a literal (the line then never ends well and the buffer limit stops it).
    static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.count <= 9,
              let n = Int(digits), n <= IMAPSession.maxBuffer else { return nil }
        return n
    }
}

/// What the mailbox looks like: UIDNEXT moves on with each new mail; UIDVALIDITY changing means every UID was renumbered.
struct IMAPMailbox: Equatable {
    var validity: Int
    var next: Int
}

/// One new mail, header fields only.
struct IMAPMail: Equatable {
    var uid: Int
    var sender: String
    var subject: String
    var date: Date?
    /// Already read somewhere else (phone, web) by the time it was found.
    var seen: Bool
}

enum IMAPError: Error, Equatable {
    /// LOGIN refused: wrong password, no app password, IMAP turned off in the mail settings.
    case login(String)
    /// No connection, TLS failure, timeout, connection dropped.
    case network(String)
    /// Anything else the server said no to.
    case server(String)
}

/// The bytes in and out. NWTransport for real; tests script a fake server.
protocol IMAPTransport: AnyObject {
    func send(_ data: Data) async throws
    /// The next bytes; empty when the server closed the connection.
    func receive() async throws -> Data
    func close()
}

/// One conversation with a server: tagged commands, untagged lines collected until the tagged answer.
final class IMAPSession {
    private let t: IMAPTransport
    private var reader = IMAPReader()
    private var count = 0
    /// Header fields of a handful of mails are a few KB: more than this is not a well-behaved server.
    static let maxBuffer = 4 << 20

    init(_ t: IMAPTransport) { self.t = t }

    private func read() async throws -> IMAPResponse {
        while true {
            if let r = reader.next() { return r }
            guard reader.size < Self.maxBuffer else { throw IMAPError.server("response too large") }
            let d = try await t.receive()
            guard !d.isEmpty else { throw IMAPError.network("connection closed") }
            reader.feed(d)
        }
    }

    /// The server's hello: "* OK" (or PREAUTH). "* BYE" is a refusal.
    func greeting() async throws {
        let r = try await read()
        guard r.text.hasPrefix("* OK") || r.text.hasPrefix("* PREAUTH") else { throw IMAPError.server(r.text) }
    }

    /// Sends one command, returns the untagged lines before its tagged OK. NO/BAD throw.
    @discardableResult
    func command(_ cmd: String, login: Bool = false) async throws -> [IMAPResponse] {
        count += 1
        let tag = "a\(count)"
        try await t.send(Data("\(tag) \(cmd)\r\n".utf8))
        var untagged: [IMAPResponse] = []
        while true {
            let r = try await read()
            guard r.tag == tag else {
                if r.text.hasPrefix("* BYE") && !cmd.hasPrefix("LOGOUT") { throw IMAPError.network(r.text) }
                untagged.append(r)
                continue
            }
            let status = r.text.dropFirst(tag.count + 1)
            if status.hasPrefix("OK") { return untagged }
            let why = String(status)
            guard login, status.hasPrefix("NO") else { throw IMAPError.server(why) }
            throw Self.refusedLogin(why) ? IMAPError.login(why) : IMAPError.network(why)
        }
    }

    /// A LOGIN "NO" that means the password: [AUTHENTICATIONFAILED], [AUTHORIZATIONFAILED], [EXPIRED] or no code.
    /// [UNAVAILABLE], [INUSE], [ALERT] ("Too many simultaneous connections", web login needed) pass: try again later.
    static func refusedLogin(_ status: String) -> Bool {
        guard let open = status.firstIndex(of: "["), let close = status[open...].firstIndex(of: "]") else { return true }
        let code = status[status.index(after: open)..<close].split(separator: " ").first.map { $0.uppercased() } ?? ""
        return ["AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED"].contains(code)
    }

    /// A quoted string ("a\"b"). Nil for what a quoted string cannot carry (line breaks, non-ASCII): app passwords
    /// and addresses never need a literal.
    static func quoted(_ s: String) -> String? {
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func login(user: String, password: String) async throws {
        guard let u = Self.quoted(user), let p = Self.quoted(password) else { throw IMAPError.login("unsupported characters") }
        try await command("LOGIN \(u) \(p)", login: true)
    }

    /// EXAMINE: the read-only SELECT, so not even the \Recent flags change.
    func examine() async throws -> IMAPMailbox {
        let lines = try await command("EXAMINE INBOX")
        func code(_ name: String) -> Int? { lines.lazy.compactMap { IMAPParse.code(name, in: $0.text) }.first }
        guard let validity = code("UIDVALIDITY"), let next = code("UIDNEXT") else { throw IMAPError.server("no UIDNEXT") }
        return IMAPMailbox(validity: validity, next: next)
    }

    /// Header fields of the mails with UIDs lo...hi, oldest first. BODY.PEEK: the \Seen flag stays as it is.
    func fetch(_ lo: Int, _ hi: Int) async throws -> [IMAPMail] {
        let lines = try await command("UID FETCH \(lo):\(hi) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        var out: [Int: IMAPMail] = [:]
        for r in lines { if let m = IMAPParse.mail(r), (lo...hi).contains(m.uid) { out[m.uid] = m } }
        return out.values.sorted { $0.uid < $1.uid }
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        t.close()
    }
}

enum IMAPCheck {
    /// At most this many new mails are looked at per check (a burst becomes "메일 20통" anyway).
    static let maxFetch = 20

    /// One check of INBOX. No baseline yet, or UIDVALIDITY changed: only learns where the mailbox ends (mail that was
    /// already there is never news). Otherwise the mails that arrived since `since`.
    static func run(_ t: IMAPTransport, user: String, password: String, since: IMAPMailbox?) async throws -> (IMAPMailbox, [IMAPMail]) {
        let s = IMAPSession(t)
        do {
            try await s.greeting()
            try await s.login(user: user, password: password)
            let box = try await s.examine()
            var mails: [IMAPMail] = []
            if let since, since.validity == box.validity, box.next > since.next {
                mails = try await s.fetch(max(since.next, box.next - maxFetch), box.next - 1)
            }
            await s.logout()
            return (box, mails)
        } catch {
            t.close()
            throw error
        }
    }
}

/// Response and header parsing. Pure.
enum IMAPParse {
    /// "* OK [UIDNEXT 4392] Predicted next UID" -> 4392.
    static func code(_ name: String, in text: String) -> Int? {
        guard let r = text.range(of: "[\(name) ") else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    /// "* 12 FETCH (UID 345 FLAGS (\Seen) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {80}" + the header bytes.
    /// Nil for a FETCH without the header (a flags update) and for any other line.
    static func mail(_ r: IMAPResponse) -> IMAPMail? {
        guard r.text.range(of: #"^\* \d+ FETCH "#, options: .regularExpression) != nil,
              let u = r.text.range(of: #"UID \d+"#, options: .regularExpression),
              let uid = Int(r.text[u].dropFirst(4)), let raw = r.literals.first else { return nil }
        let flags = r.text.range(of: #"FLAGS \([^)]*\)"#, options: .regularExpression).map { String(r.text[$0]) } ?? ""
        let h = headers(raw)
        return IMAPMail(uid: uid, sender: sender(h["from"] ?? ""), subject: h["subject"] ?? "",
                        date: h["date"].flatMap(date), seen: flags.contains("\\Seen"))
    }

    /// Header block -> lowercased name: decoded, unfolded value. Raw 8-bit headers: UTF-8, else EUC-KR.
    static func headers(_ d: Data) -> [String: String] {
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: encoding("euc-kr") ?? .isoLatin1)
            ?? String(decoding: d, as: UTF8.self)
        var out: [String: String] = [:]
        var name: String?
        for line in s.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if let f = line.first, f == " " || f == "\t", let n = name {
                out[n, default: ""] += line   // folded: CRLF dropped, the white space kept
            } else if let colon = line.firstIndex(of: ":") {
                let n = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                name = n
                out[n] = String(line[line.index(after: colon)...])
            }
        }
        return out.mapValues { words($0).trimmingCharacters(in: .whitespaces) }
    }

    /// "\"=?UTF-8?B?6rmA7LKg7IiY?=\" <kim@x.com>" -> "김철수"; "news@x.com" -> "news". Names only, never addresses.
    static func sender(_ from: String) -> String {
        let s = from.trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name.replacingOccurrences(of: "\\\"", with: "\"") }
            return local(String(s[lt...]))
        }
        return local(s)
    }

    private static func local(_ addr: String) -> String {
        let a = addr.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return a.split(separator: "@").first.map(String.init) ?? a
    }

    /// RFC 2822 date: "Sat, 4 Oct 2026 14:05:00 +0900 (KST)", weekday and seconds optional.
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var t = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let comma = t.firstIndex(of: ",") { t = t[t.index(after: comma)...].trimmingCharacters(in: .whitespaces) }
        for p in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = p
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// Korean mail labelled EUC-KR often carries CP949's extra syllables (똠, 햏, 뷁): read every Korean label as CP949.
    static func encoding(_ charset: String) -> String.Encoding? {
        if ["euc-kr", "ks_c_5601-1987", "cp949", "x-windows-949", "windows-949"].contains(charset.lowercased()) {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// MIME encoded-words (RFC 2047): "=?UTF-8?B?...?=", "=?EUC-KR?Q?...?=". Neighbours with only white space between
    /// are one run: the space goes, and their bytes are joined before decoding (a character may be split across two).
    static func words(_ s: String) -> String {
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        var run: (charset: String, bytes: Data, raw: String)?
        func flush() {
            guard let r = run else { return }
            out += encoding(r.charset).flatMap { String(data: r.bytes, encoding: $0) } ?? r.raw
            run = nil
        }
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1)).split(separator: "*", omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""   // RFC 2231 language; "*" alone is no charset (raw stays)
            let bytes = ns.substring(with: m.range(at: 2)).uppercased() == "B" ? b64(ns.substring(with: m.range(at: 3)))
                                                                               : q(ns.substring(with: m.range(at: 3)))
            let raw = ns.substring(with: m.range)
            if let r = run, gap.allSatisfy(\.isWhitespace) {   // the space between two encoded-words goes
                if r.charset.lowercased() == charset.lowercased() { run = (r.charset, r.bytes + bytes, r.raw + gap + raw) }
                else { flush(); run = (charset, bytes, raw) }
            } else {
                flush()
                out += gap
                run = (charset, bytes, raw)
            }
            last = m.range.location + m.range.length
        }
        flush()
        return out + ns.substring(from: last)
    }

    private static func b64(_ s: String) -> Data {
        let padded = s + String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: padded) ?? Data()
    }

    /// Q encoding: "_" is a space, "=XX" a byte.
    private static func q(_ s: String) -> Data {
        var out = Data(), b = Array(s.utf8), i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "_") { out.append(0x20) }
            else if b[i] == UInt8(ascii: "="), i + 2 < b.count, let v = UInt8(String(bytes: b[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                out.append(v); i += 2
            } else { out.append(b[i]) }
            i += 1
        }
        return out
    }
}

/// TLS over Network.framework (no URLSession: IMAP is not HTTP). Every step gives up after `timeout`.
final class NWTransport: IMAPTransport, @unchecked Sendable {   // `opened` is touched on `q` only
    private let c: NWConnection
    private let q = DispatchQueue(label: "dogmonitor.imap")
    private var opened = false

    private init(_ c: NWConnection) { self.c = c }

    static func open(host: String, port: Int, timeout: TimeInterval = 30) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { throw IMAPError.network("bad server") }
        let t = NWTransport(NWConnection(host: NWEndpoint.Host(host), port: p, using: .tls))
        t.q.asyncAfter(deadline: .now() + timeout) { [weak t] in t?.c.cancel() }   // a hung server ends here
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            t.c.stateUpdateHandler = { state in
                guard !t.opened else { return }
                switch state {
                case .ready: t.opened = true; k.resume()
                case .failed(let e), .waiting(let e): t.opened = true; t.c.cancel(); k.resume(throwing: IMAPError.network("\(e)"))
                case .cancelled: t.opened = true; k.resume(throwing: IMAPError.network("timeout"))
                default: break
                }
            }
            t.c.start(queue: t.q)
        }
        return t
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e { k.resume(throwing: IMAPError.network("\(e)")) } else { k.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, e in
                if let data, !data.isEmpty { k.resume(returning: data) }
                else if let e { k.resume(throwing: IMAPError.network("\(e)")) }
                else { k.resume(returning: Data()) }   // closed
            }
        }
    }

    func close() { c.cancel() }
}
