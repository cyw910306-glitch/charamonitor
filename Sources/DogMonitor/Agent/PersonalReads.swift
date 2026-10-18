import EventKit
import Foundation

// 비서가 행동하기 v2, the personal read tools (calendar_list, reminders_list, inbox_recent, contacts_find, memory_read,
// mail_search, mail_read). Each answers with short text lines for the model; the tool host wraps them as data. Sources
// are closures so tests run on fakes. Mail is read with EXAMINE and BODY.PEEK: nothing on the server changes.

@MainActor
struct PersonalReads {
    struct Event: Equatable {
        var start: Date, end: Date
        var title: String
        var location: String? = nil
        var allDay = false
    }

    struct Reminder: Equatable {
        var id: String
        var title: String
        var due: Date? = nil
    }

    static let maxLines = 40

    /// nil = calendar access is off.
    var events: (Date, Date) -> [Event]?
    /// nil = reminders access is off.
    var reminders: () async -> [Reminder]?
    var inbox: () -> [InboxItem]
    /// nil = contacts access is off.
    var cards: () async -> [ContactsFinder.Card]?
    var mailAccounts: () -> [MailAccount]
    var password: (MailAccount) async -> String?
    var connect: (MailAccount) async throws -> IMAPTransport

    static var live: PersonalReads {
        PersonalReads(
            events: { from, to in
                guard CalendarLink.authorized(.event) else { return nil }
                let s = CalendarLink.shared.store
                return s.events(matching: s.predicateForEvents(withStart: from, end: to, calendars: nil)).map {
                    Event(start: $0.startDate, end: $0.endDate, title: $0.title ?? "", location: $0.location, allDay: $0.isAllDay)
                }
            },
            reminders: {
                guard CalendarLink.authorized(.reminder) else { return nil }
                let s = CalendarLink.shared.store
                return await withCheckedContinuation { k in
                    s.fetchReminders(matching: s.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { list in
                        k.resume(returning: (list ?? []).map {
                            Reminder(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date)
                        })
                    }
                }
            },
            inbox: { InboxCenter.memory() },
            cards: {
                guard await ContactsFinder.requestIfNeeded() else { return nil }
                return await Task.detached { ContactsFinder.cards() }.value
            },
            mailAccounts: { MailAccounts.shared.accounts.filter(\.on) },
            password: { a in await Task.detached { MailKeychain.load(for: a) }.value },   // a keychain prompt must not block the menu bar
            connect: { a in try await MailAccounts.shared.connect(a) })
    }

    // MARK: Calendar, reminders, inbox, contacts, memory

    /// Soonest first (a range ahead reads best in order).
    func calendarList(from: Date, to: Date) -> String {
        guard let list = events(from, to) else { return L("캘린더 접근이 꺼져 있어요. 설정에서 캘린더를 허용하면 읽을 수 있어요.") }
        guard !list.isEmpty else { return L("이 기간에는 일정이 없어요.") }
        return Self.cap(list.sorted { $0.start < $1.start }.map { e in
            let when = e.allDay ? Self.day(e.start) + " " + L("종일")
                : Self.stamp(e.start) + "~" + (Calendar.current.isDate(e.start, inSameDayAs: e.end) ? Self.time(e.end) : Self.stamp(e.end))
            let place = e.location.map { $0.isEmpty ? "" : " @ " + Self.line($0, 60) } ?? ""
            return "\(when) \(Self.line(e.title, 80))\(place)"
        })
    }

    /// Due soonest first, undated last.
    func remindersList() async -> String {
        guard let list = await reminders() else { return L("미리알림 접근이 꺼져 있어요. 설정에서 미리알림을 허용하면 읽을 수 있어요.") }
        guard !list.isEmpty else { return L("끝나지 않은 미리알림이 없어요.") }
        let sorted = list.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return Self.cap(sorted.map { r in
            "[\(r.id)] \(Self.line(r.title, 80))" + (r.due.map { " (" + L("마감") + " \(Self.stamp($0)))" } ?? "")
        })
    }

    /// Newest first. Memory holds only what came in since the app started.
    func inboxRecent() -> String {
        let items = inbox()
        guard !items.isEmpty else { return L("앱이 켜진 뒤로 받은 문자·메일·알림이 없어요.") }
        return Self.cap(items.sorted { $0.date > $1.date }.map { i in
            let kind = i.kind == .message ? L("문자") : i.kind == .mail ? L("메일") : L("알림")
            let via = i.via.map { " (\($0))" } ?? ""
            return "\(Self.stamp(i.date)) \(kind)\(via) \(Self.line(i.who, 40))" + (i.preview.map { ": " + Self.line($0, 120) } ?? "")
        })
    }

    func contactsFind(_ name: String) async -> String {
        guard let all = await cards() else { return L("연락처 접근이 꺼져 있어요. 설정에서 연락처를 허용하면 찾을 수 있어요.") }
        let found = ContactsFinder.rank(name, all).prefix(5)
        guard !found.isEmpty else { return L("연락처에서 '\(name)'을(를) 찾지 못했어요.") }
        return found.map { c in
            let full = [c.family, c.given].joined().isEmpty ? c.nickname : c.family + c.given
            let extra = [c.organization, c.jobTitle].filter { !$0.isEmpty }.joined(separator: ", ")
            let addrs = (c.emails + c.phones).joined(separator: ", ")
            return full + (extra.isEmpty ? "" : " (\(extra))") + ": " + (addrs.isEmpty ? L("주소 없음") : addrs)
        }.joined(separator: "\n")
    }

    func memoryRead(_ memory: OwnerMemory) -> String {
        let lines = memory.linesForAI
        return lines.isEmpty ? L("기억해 둔 게 없어요.") : Self.cap(lines)
    }

    // MARK: Mail (IMAP, read-only)

    /// The newest 10 matches across switched-on accounts, newest first. Id: "<accountID>:<uid>".
    func mailSearch(_ query: String) async -> String {
        // Scalars, not Characters: "\r\n" is one Character equal to neither "\r" nor "\n" (review 2026-10-06).
        let flat = String(String.UnicodeScalarView(query.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        let q = String(flat.trimmingCharacters(in: .whitespaces).prefix(100))
        guard !q.isEmpty else { return L("찾을 말을 넣어 주세요.") }
        let accounts = mailAccounts()
        guard !accounts.isEmpty else { return L("연결된 메일 계정이 없어요. 비서 설정 > 메일 계정에서 추가할 수 있어요.") }
        var hits: [(account: MailAccount, mail: IMAPMail)] = []
        var problems: [String] = []
        for a in accounts {
            do {
                hits += try await session(a) { s in try await MailRead.search(s, q) }.map { (account: a, mail: $0) }
            } catch {
                problems.append(L("\(a.user): 메일함을 읽지 못했어요"))
            }
        }
        let lines = hits.sorted { ($0.mail.date ?? .distantPast, $0.mail.uid) > ($1.mail.date ?? .distantPast, $1.mail.uid) }
            .prefix(MailRead.maxHits).map { h in
                "[\(h.account.id):\(h.mail.uid)] " + (h.mail.date.map(Self.stamp) ?? "") + " \(Self.line(h.mail.sender, 40)): \(Self.line(h.mail.subject, 120))"
            }
        if lines.isEmpty && problems.isEmpty { return L("'\(q)'에 맞는 메일이 없어요.") }
        return (lines + problems).joined(separator: "\n")
    }

    /// One mail's sender, subject, date and text (cut at 4,000 characters).
    func mailRead(_ id: String) async -> String {
        guard let colon = id.lastIndex(of: ":"), let uid = Int(id[id.index(after: colon)...]), uid > 0,
              let a = mailAccounts().first(where: { $0.id == String(id[..<colon]) }) else {
            return L("그 id의 메일을 찾지 못했어요. mail_search로 다시 찾아 주세요.")
        }
        do {
            guard let m = try await session(a, { s in try await MailRead.read(s, uid: uid) }) else {
                return L("그 id의 메일을 찾지 못했어요. mail_search로 다시 찾아 주세요.")
            }
            return [L("보낸 사람") + ": " + m.sender, L("제목") + ": " + m.subject,
                    L("날짜") + ": " + (m.date.map(Self.stamp) ?? ""), "", m.text].joined(separator: "\n")
        } catch {
            return L("\(a.user): 메일을 읽지 못했어요")
        }
    }

    private func session<T>(_ a: MailAccount, _ body: (IMAPSession) async throws -> T) async throws -> T {
        guard let p = await password(a) else { throw IMAPError.login("no password") }
        let t = try await connect(a)
        let s = IMAPSession(t)
        do {
            try await s.greeting()
            try await s.login(user: a.loginName, password: p)
            _ = try await s.examine()
            let out = try await body(s)
            await s.logout()
            return out
        } catch {
            t.close()
            throw error
        }
    }

    // MARK: Formatting

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }
    static func stamp(_ d: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: d) }
    static func day(_ d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    static func time(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// One line, at most `n` characters.
    static func line(_ s: String, _ n: Int) -> String {
        String(s.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(n))
    }

    static func cap(_ lines: [String]) -> String {
        guard lines.count > maxLines else { return lines.joined(separator: "\n") }
        return (lines.prefix(maxLines) + [L("…외 \(lines.count - maxLines)개")]).joined(separator: "\n")
    }
}

/// IMAP commands for mail_search and mail_read, on an examined INBOX session.
enum MailRead {
    static let maxHits = 10
    static let maxText = 4000

    struct Mail: Equatable {
        var sender: String
        var subject: String
        var date: Date?
        var text: String
    }

    /// UID SEARCH OR SUBJECT q FROM q, the newest `maxHits`, then their header fields.
    static func search(_ s: IMAPSession, _ q: String) async throws -> [IMAPMail] {
        let lines = try await s.command("UID SEARCH " + searchArgs(q))
        let uids = lines.flatMap { r -> [Int] in
            guard r.text.hasPrefix("* SEARCH") else { return [] }
            return r.text.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }.sorted().suffix(maxHits)
        guard !uids.isEmpty else { return [] }
        let fetched = try await s.command("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        return fetched.compactMap(IMAPParse.mail)
    }

    /// ASCII as a quoted string; anything else as UTF-8 literals with CHARSET.
    /// ponytail: the literal goes out without waiting for the server's "+" (IMAPSession sends whole lines); servers
    /// that enforce the wait answer BAD and the search reports failure. Add continuation support to IMAPSession if one does.
    static func searchArgs(_ q: String) -> String {
        if let quoted = IMAPSession.quoted(q) { return "OR SUBJECT \(quoted) FROM \(quoted)" }
        let lit = "{\(q.utf8.count)}\r\n\(q)"
        return "CHARSET UTF-8 OR SUBJECT \(lit) FROM \(lit)"
    }

    /// Header fields and up to 200 KB of the text, BODY.PEEK so \Seen stays as it is.
    static func read(_ s: IMAPSession, uid: Int) async throws -> Mail? {
        let lines = try await s.command("UID FETCH \(uid) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.200000>)")
        guard let r = lines.first(where: { $0.text.range(of: #"^\* \d+ FETCH "#, options: .regularExpression) != nil && $0.literals.count >= 2 }),
              let h = r.text.range(of: "HEADER.FIELDS"), let b = r.text.range(of: "BODY[TEXT]") else { return nil }
        // Literals arrive in the order of their markers in the line.
        let (head, body) = h.lowerBound < b.lowerBound ? (r.literals[0], r.literals[1]) : (r.literals[1], r.literals[0])
        let fields = IMAPParse.headers(head)
        return Mail(sender: IMAPParse.sender(fields["from"] ?? ""), subject: fields["subject"] ?? "",
                    date: fields["date"].flatMap(IMAPParse.date), text: String(MIMEText.extract(fields, body).prefix(maxText)))
    }
}

/// The readable text of a mail body: transfer decoding, charset, multipart (text/plain preferred, else html stripped). Pure.
enum MIMEText {
    /// text/plain anywhere in the tree wins; html only when there is none.
    static func extract(_ headers: [String: String], _ body: Data) -> String {
        (part(headers, body, html: false) ?? part(headers, body, html: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func part(_ h: [String: String], _ body: Data, html: Bool) -> String? {
        let type = (h["content-type"] ?? "text/plain").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.hasPrefix("multipart/") {
            guard let boundary = param("boundary", h["content-type"] ?? "") else { return nil }
            for (ph, pb) in split(body, boundary: boundary) {
                if let t = part(ph, pb, html: html), !t.isEmpty { return t }
            }
            return nil
        }
        guard type == "text/plain" || (html && type == "text/html") else { return nil }
        let raw = decode(body, (h["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        let charset = param("charset", h["content-type"] ?? "") ?? "utf-8"
        let text = IMAPParse.encoding(charset).flatMap { String(data: raw, encoding: $0) } ?? String(decoding: raw, as: UTF8.self)
        return type == "text/html" ? stripHTML(text) : text
    }

    /// A Content-Type parameter: boundary="abc", charset=utf-8.
    static func param(_ name: String, _ value: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*(?:"([^"]*)"|([^;\s]+))"#, options: .caseInsensitive),
              let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for i in [1, 2] { if let r = Range(m.range(at: i), in: value) { return String(value[r]) } }
        return nil
    }

    /// The parts between "--boundary" lines, each as (headers, body). Latin-1 keeps every byte as one character.
    private static func split(_ body: Data, boundary: String) -> [([String: String], Data)] {
        let s = String(data: body, encoding: .isoLatin1) ?? ""
        let chunks = s.components(separatedBy: "--" + boundary).dropFirst()
        return chunks.compactMap { c in
            if c.hasPrefix("--") { return nil }   // the closing delimiter
            let text = c.first?.isNewline == true ? String(c.dropFirst()) : c   // "\r\n" is one Character
            let sep = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
            let head = sep.map { String(text[..<$0.lowerBound]) } ?? ""
            let rest = sep.map { String(text[$0.upperBound...]) } ?? text
            return (IMAPParse.headers(head.data(using: .isoLatin1) ?? Data()), rest.data(using: .isoLatin1) ?? Data())
        }
    }

    static func decode(_ d: Data, _ encoding: String) -> Data {
        switch encoding {
        case "base64":
            let clean = String(decoding: d, as: UTF8.self).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }
            let usable = clean.prefix(clean.count / 4 * 4)   // a partial fetch may cut the last group
            return Data(base64Encoded: String(usable)) ?? Data()
        case "quoted-printable": return quotedPrintable(d)
        default: return d
        }
    }

    /// "=XX" bytes, "=" at a line end joins lines.
    static func quotedPrintable(_ d: Data) -> Data {
        let b = [UInt8](d)
        var out = Data(), i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == UInt8(ascii: "=") {
                if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(b[i])
            i += 1
        }
        return out
    }

    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
    }
}
