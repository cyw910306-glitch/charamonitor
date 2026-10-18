#if !MAS
import Contacts
import Foundation
import SQLite3

// 문자 알려주기 (direct build only): new messages in Messages' chat.db, read-only, with 전체 디스크 접근.
// Message text stays in memory for the bubble: never saved, logged or sent anywhere.

/// Whether a protected database can be read.
enum InboxAccess: Equatable {
    case ok
    /// 전체 디스크 접근 is off (TCC: EPERM, SQLITE_AUTH or CANTOPEN on a file that is there).
    case denied
    /// The file is not where this macOS keeps it (moved by an OS update, or the app never ran).
    case missing
}

/// One read-only SQLite connection. Never immutable=1: that skips the WAL, where the newest rows wait.
/// Opened per poll and closed with the object, so Messages' own writes are never in the way.
final class ReadOnlyDB {
    private var db: OpaquePointer?

    init?(path: String) {
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
    }

    deinit { sqlite3_close(db) }

    struct Row {
        let s: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(s, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
    }

    /// Runs `sql` with integer parameters. False when it could not run (no permission shows up here, on the first query).
    @discardableResult
    func rows(_ sql: String, _ params: [Int64] = [], _ each: (Row) -> Void) -> Bool {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { sqlite3_finalize(s); return false }
        defer { sqlite3_finalize(s) }
        for (i, p) in params.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), p) }
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: each(Row(s: s))
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    func scalar(_ sql: String) -> Int64? {
        var v: Int64?
        return rows(sql) { v = $0.int(0) } ? (v ?? 0) : nil
    }

    /// Access to a database file: opens it and checks `table` (nonja's Store.check, plus the open).
    static func access(_ path: String, table: String) -> InboxAccess {
        if let db = ReadOnlyDB(path: path), let n = db.scalar("select count(*) from sqlite_master where type='table' and name='\(table)'") {
            return n > 0 ? .ok : .missing
        }
        // Reading the folder is what TCC refuses; a folder that lists without the file means it moved.
        let dir = (path as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return FileManager.default.fileExists(atPath: dir) ? .denied : .missing
        }
        return names.contains((path as NSString).lastPathComponent) ? .denied : .missing
    }
}

/// Messages' chat.db (macOS 13 to 26: message, handle, chat, chat_message_join).
struct MessagesDB {
    static var path: String { NSHomeDirectory() + "/Library/Messages/chat.db" }
    var path = Self.path

    struct Row: Equatable {
        var rowID: Int64
        var handle: String
        var text: String?
        var date: Date
    }

    /// message.date: nanoseconds since 2001 (seconds in very old rows).
    static func date(_ v: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: v > 1_000_000_000_000 ? Double(v) / 1e9 : Double(v))
    }

    func access() -> InboxAccess { ReadOnlyDB.access(path, table: "message") }

    func maxRowID() -> Int64? { ReadOnlyDB(path: path)?.scalar("select ifnull(max(ROWID), 0) from message") }

    /// Received messages after `cursor` and newer than `since` (no reactions, no group events), oldest first, at most
    /// `limit`. Nil when unreadable.
    func messages(after cursor: Int64, since: Date = Date(timeIntervalSinceReferenceDate: 0), limit: Int = 50) -> [Row]? {
        received("m.ROWID > ? and m.date > ? order by m.ROWID limit ?", [cursor, Self.ns(since), Int64(limit)])
    }

    /// The newest received messages (inside `period` when given), newest first, for the chat's "가장 최근 문자".
    func latest(limit: Int, in period: DateInterval? = nil) -> [Row]? {
        received("m.date >= ? and m.date <= ? order by m.date desc limit ?",
                 [period.map { Self.ns($0.start) } ?? 0, period.map { Self.ns($0.end) } ?? Int64.max, Int64(limit)])
    }

    private static func ns(_ d: Date) -> Int64 { Int64(max(0, d.timeIntervalSinceReferenceDate) * 1e9) }

    private func received(_ whereOrder: String, _ params: [Int64]) -> [Row]? {
        guard let db = ReadOnlyDB(path: path) else { return nil }
        var out: [Row] = []
        let ok = db.rows("""
            select m.ROWID, ifnull(h.id, ''), m.text, m.attributedBody, m.date from message m
            left join handle h on h.ROWID = m.handle_id
            where m.is_from_me = 0 and m.item_type = 0 and m.associated_message_type = 0 and \(whereOrder)
            """, params) { r in
            let text = r.text(2).flatMap { $0.isEmpty ? nil : $0 } ?? r.blob(3).flatMap(AttributedBody.text)
            out.append(Row(rowID: r.int(0), handle: r.text(1) ?? "", text: text, date: Self.date(r.int(4))))
        }
        return ok ? out : nil
    }
}

/// message.attributedBody: an NSAttributedString in NSArchiver's typedstream (text is NULL there since Ventura).
/// Read by hand with bounds checks: NSUnarchiver throws an Objective-C exception on a bad blob, which Swift cannot
/// catch, and the blob comes from whoever sent the message.
enum AttributedBody {
    static func text(_ blob: Data) -> String? {
        let b = [UInt8](blob)
        guard let at = find(Array("NSString".utf8), in: b) else { return nil }
        var i = at + 8 + 5   // past "NSString" and the class header that follows it
        guard i < b.count else { return nil }
        var length = Int(b[i]); i += 1
        if length == 0x81 || length == 0x82 {
            let n = length == 0x81 ? 2 : 4
            guard i + n <= b.count else { return nil }
            length = (0..<n).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) }
            i += n
        }
        guard length > 0, i + length <= b.count, let s = String(bytes: b[i..<(i + length)], encoding: .utf8) else { return nil }
        return s
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        return (0...(hay.count - needle.count)).first { hay[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// Sender names: the contact's name with 연락처 permission, else the number partly hidden.
enum ContactNames {
    static var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    /// A bare build (no Info.plist) would be killed by the system on the request.
    static var canAsk: Bool { Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil }
    /// macOS would show its prompt (never answered yet).
    static var wouldAsk: Bool { canAsk && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }

    static func request() async -> Bool {
        guard canAsk else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Lets the system match +82 10 and 010 forms. Slow-ish: call off the main thread and cache.
    static func name(_ handle: String, store: CNContactStore) -> String? {
        guard authorized, !handle.isEmpty else { return nil }
        let predicate = handle.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: handle)
                                             : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactNicknameKey as CNKeyDescriptor]
        guard let c = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first else { return nil }
        let full = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        return full.isEmpty ? (c.nickname.isEmpty ? nil : c.nickname) : full
    }

    /// "+821012345678" -> "010-****-5678", "kim@x.com" -> "ki***". Short service numbers stay as they are.
    static func mask(_ handle: String) -> String {
        if let at = handle.firstIndex(of: "@") { return String(handle[..<at].prefix(2)) + "***" }
        var d = handle.filter(\.isNumber)
        if handle.hasPrefix("+82") { d = "0" + d.dropFirst(2) }
        guard d.count >= 8 else { return handle.isEmpty ? L("모르는 번호") : handle }
        return "\(d.prefix(3))-****-\(d.suffix(4))"
    }
}
#endif
