#if !MAS
import AppKit
import Foundation

// 다른 앱 알림 알려주기 (direct build only): Notification Center's own database, read-only, with 전체 디스크 접근.
// Not a public API: macOS can move or change it in an update (InboxAccess.missing then says so).
// Notification text stays in memory for the bubble: never saved, logged or sent anywhere.

struct NotificationsDB {
    /// macOS 15 and later (verified on 26 by nonja), then the 13-14 place.
    static var path: String {
        let group = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        if FileManager.default.fileExists(atPath: (group as NSString).deletingLastPathComponent) { return group }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else { return group }
        let old = String(cString: buf) + "com.apple.notificationcenter/db2/db"
        return FileManager.default.fileExists(atPath: old) ? old : group
    }
    var path = Self.path

    struct Row: Equatable {
        var recID: Int64
        var bundle: String
        var title: String?
        var body: String?
        var date = Date.distantPast

        /// A record with no title and no body is a badge or silent sync update (카카오톡 posts these when it
        /// reconnects or a chat is read on the phone), not news: saying it was "카카오톡 알림 왔어" with nothing there.
        var hasText: Bool { title != nil || body != nil }
        /// Same app and words: an app posting the same notification again (wake from sleep, reconnect).
        var key: Int { [bundle, title ?? "", body ?? ""].joined(separator: "\u{1F}").hashValue }
    }

    /// Drops rows said in the last `window` (same `key`) and remembers the rest. `seen` holds hashes only, in memory.
    /// ponytail: the same words twice from one sender inside 30 minutes ("ㅇㅇ") are said once; key on the record's
    /// uuid as well if that ever matters.
    static func unseen(_ rows: [Row], seen: inout [Int: Date], now: Date, window: TimeInterval = 30 * 60) -> [Row] {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        return rows.filter { r in
            guard seen[r.key] == nil else { return false }
            seen[r.key] = now
            return true
        }
    }

    func access() -> InboxAccess { ReadOnlyDB.access(path, table: "record") }

    func maxRecID() -> Int64? { ReadOnlyDB(path: path)?.scalar("select ifnull(max(rec_id), 0) from record") }

    /// Notifications delivered after `cursor` and since `since`, oldest first. Nil when unreadable.
    func records(after cursor: Int64, since: Date = Date(timeIntervalSinceReferenceDate: 0), limit: Int = 50) -> [Row]? {
        delivered("r.rec_id > ? and r.delivered_date > ? order by r.rec_id limit ?",
                  [cursor, Int64(max(0, since.timeIntervalSinceReferenceDate)), Int64(limit)])
    }

    /// The newest notifications (inside `period` when given), newest first, for the chat.
    func latest(limit: Int, in period: DateInterval? = nil) -> [Row]? {
        delivered("r.delivered_date >= ? and r.delivered_date <= ? order by r.delivered_date desc limit ?",
                  [Int64(period?.start.timeIntervalSinceReferenceDate ?? -1e9), Int64(period?.end.timeIntervalSinceReferenceDate ?? 1e12), Int64(limit)])
    }

    private func delivered(_ whereOrder: String, _ params: [Int64]) -> [Row]? {
        guard let db = ReadOnlyDB(path: path) else { return nil }
        var out: [Row] = []
        let ok = db.rows("""
            select r.rec_id, ifnull(a.identifier, ''), r.data, r.delivered_date from record r left join app a on a.app_id = r.app_id
            where r.delivered_date is not null and \(whereOrder)
            """, params) { r in
            var row = r.blob(2).flatMap(Self.parse) ?? Row(recID: 0, bundle: "")
            row.recID = r.int(0)
            row.date = Date(timeIntervalSinceReferenceDate: r.double(3))   // seconds since 2001
            if let id = r.text(1), !id.isEmpty { row.bundle = id }
            out.append(row)
        }
        return ok ? out : nil
    }

    /// The apps that notify most (bundle IDs only, never the text), for the 앱별 끄기 list.
    func topApps(limit: Int = 12) -> [String] {
        var out: [String] = []
        ReadOnlyDB(path: path)?.rows("""
            select a.identifier from record r join app a on a.app_id = r.app_id
            group by a.identifier order by count(*) desc limit ?
            """, [Int64(limit)]) { r in if let id = r.text(0), !id.isEmpty { out.append(id) } }
        return out
    }

    /// record.data: a binary plist {app, date, uuid, req: {titl, subt, body}}. A localized field comes as
    /// [format, resolved, args]: the resolved string first.
    static func parse(_ data: Data) -> Row? {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let req = root["req"] as? [String: Any] ?? [:]
        func field(_ k: String) -> String? {
            let s: String?
            if let v = req[k] as? String { s = v }
            else if let a = req[k] as? [Any] { s = (a.count > 1 ? a[1] as? String : nil) ?? a.first as? String }
            else { s = nil }
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return t?.isEmpty == false ? t : nil
        }
        let title = [field("titl"), field("subt")].compactMap { $0 }.joined(separator: " · ")
        return Row(recID: 0, bundle: root["app"] as? String ?? "", title: title.isEmpty ? nil : title, body: field("body"))
    }

    /// Apple's own apps worth saying; every other com.apple.* (system, 스크린 타임, Time Machine…) stays quiet.
    static let appleApps: Set<String> = ["com.apple.MobileSMS", "com.apple.mail", "com.apple.FaceTime"]

    /// Whether a notification is worth a bubble: not ours, not the system's, not switched off, not said elsewhere
    /// (`skip`: Messages and Mail while their own switches are on).
    static func shouldSay(_ bundle: String, off: Set<String>, skip: Set<String>, own: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard !bundle.isEmpty, bundle != own, bundle != "com.jelly.dogmonitor", !off.contains(bundle), !skip.contains(bundle) else { return false }
        return !bundle.hasPrefix("com.apple.") || appleApps.contains(bundle)
    }

    /// "카카오톡" for com.kakao.KakaoTalkMac: the installed app's shown name, else the last part of the ID.
    static func appName(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundle.split(separator: ".").last.map(String.init) ?? bundle
    }
}
#endif
