import AppKit
import Combine
import CommonCrypto
import CryptoKit
import SwiftUI

// 원격 모임: friends on other networks trade light events (상태, 이모트, 운세, 한마디) through the site's mailbox
// (web/api/relay.js). The room code never leaves the Mac: PBKDF2 turns it into the AES-GCM key and the room id, so the
// server sees only that id (hashed again there), a member id derived from a per-room secret, and ciphertext, kept 24 h after the last activity. 오늘 한마디·프로필 카드
// (.note) and 낙서 쪽지 (.doodle) ride the same way. Off by default; while on and in a room it polls every 20 to 30 s
// while a member's character (친구 상주) or the room is on screen and someone else is there, else every 2 to 5 min: a
// slow mailbox, so the relay stays in its free tier. When the relay's day is used up it says 'quota' and the app waits
// until it opens again (UTC midnight). Members stand in 친구 상주 by the look their hello carries; a 한마디 (200
// characters, 3 lines) shows over their head and 입력 중 rides the relay's live channel (never the text), at most every
// 30 s. 같이 놀기 and 무전기 stay 같은 와이파이 only.
// Keys: meet.on (OFF), meet.member. The code is in the Keychain. None of them go into the setup file.

/// Room codes and invite links.
enum MeetCode {
    /// 13 of 32 letters is 65 bits: the room id goes to the relay and checks a guess offline, so the code must not be
    /// guessable. Typed codes need 12 at least.
    static let length = 13, minLength = 12, maxLength = 24

    static func make() -> String { String((0..<length).map { _ in PluginRules.alphabet.randomElement()! }) }

    /// Upper case A-Z and 0-9 only, or nil when shorter than 12 or longer than 24.
    static func normalized(_ s: String) -> String? {
        let n = PluginRules.normalized(s)
        return (minLength...maxLength).contains(n.count) ? n : nil
    }

    /// https://<site>/meet.html#CODE: the code rides in the fragment, which a browser never sends to the site.
    static func link(_ code: String) -> URL { URL(string: "https://\(MeetRelay.host)/meet.html#\(code)")! }

    /// The code in an invite link or in charamonitor://meet?code=...
    static func code(in url: URL) -> String? {
        if url.scheme == "charamonitor" {
            guard url.host == "meet" else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value.flatMap(normalized)
        }
        guard url.scheme == "https", url.host == MeetRelay.host, url.path == "/meet.html" else { return nil }
        return url.fragment.flatMap(normalized)
    }

    /// What the user typed or pasted: a link, else a bare code.
    static func parse(_ typed: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://"), let u = URL(string: t) { return code(in: u) }
        return normalized(t)
    }
}

/// The room's AES-GCM key and id, both from the code: PBKDF2-HMAC-SHA256, 64 bytes, key = the first half.
struct MeetKeys {
    static let rounds: UInt32 = 100_000
    static let salt = Array("charamonitor-meet-v1".utf8)

    let key: SymmetricKey
    /// 64 hex characters (the second half). The server stores only its SHA-256.
    let room: String

    init(code: String) {
        var out = [UInt8](repeating: 0, count: 64)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), code, code.utf8.count, Self.salt, Self.salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), Self.rounds, &out, out.count)
        key = SymmetricKey(data: out[0..<32])
        room = out[32..<64].map { String(format: "%02x", $0) }.joined()
    }

    /// The seat's secret (32 hex): sent to the relay only, never shown to the room.
    static func newMember() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// The member id the room sees for a secret: the first 32 hex of its SHA-256, as web/api/relay.js memberId derives
    /// it. Only the holder of the secret can post, poll or leave as that id.
    static func memberID(_ secret: String) -> String {
        String(SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

/// One light event, sealed as a whole. The sender's name is inside, so the server never sees it; who sent it is the
/// relay's member id, which the box is bound to.
struct MeetEvent: Codable, Equatable {
    /// `.typing` goes only on the live channel. A build without a kind fails to decode the event and drops it.
    /// `.presence` is a hello sent again (every 20 min, or for a new face): a build without it, which would show each
    /// one as 들어왔어요, drops it.
    enum Kind: String, Codable { case hello, status, emote, fortune, line, bye, note, doodle, draw, hit, ko, typing, presence }
    var kind: Kind
    var name: String
    /// .status, and .hello (mine when I came in; older builds skip it).
    var status: OfficeStatus?
    var text: String?
    var note: FriendNote?
    var doodle: Doodle?
    /// 그룹 뽑기. A build without `.draw` fails to decode the event and drops it.
    var draw: DrawShare?
    /// 던지기 놀이: `.hit` carries the item's wire number and the member hit; `.ko` the seconds out. A build without
    /// them drops the event.
    var item: Int?
    var target: String?
    var seconds: Int?
    /// .hello: how I stand in 친구 상주 (built-in character by id only, FriendLook.received). Older builds skip it.
    var look: FriendLook?
    /// .line: the sender's UUID, so a line sent again after an unclear answer shows once.
    var id: String?
}

/// Sealing, opening and checking events, and the poll reply. Everything from the network is size-checked here.
enum MeetWire {
    static let emotes = ["👋", "🎉", "☕", "😴", "🔥", "💪", "🍚", "❤️"]
    /// maxLine: 운세. A 한마디 is `maxChat` characters in `maxChatLines` lines (a 200-character Korean line seals to
    /// about 1,100 of the relay's 2,048; older builds cut it to 60 on one line).
    static let maxLine = 60, maxChat = 200, maxChatLines = 3, maxPlain = 1400, maxData = 2048, maxReply = 262_144, maxEvents = 50, maxMembers = 12
    /// The relay protocol that keeps `live: true` posts out of the event list (web/api/relay.js `v`).
    static let liveVersion = 2

    /// A 한마디: each line cleaned, blank ones dropped, 3 lines and 200 characters at most.
    static func chat(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines).map { SocialText.clean($0, max: maxChat) }.filter { !$0.isEmpty }
        return String(lines.prefix(maxChatLines).joined(separator: "\n").prefix(maxChat))
    }

    /// The relay's free day used up (`{ error: "quota", retry }` on 503, or 429 for one address): seconds until it
    /// takes requests again (UTC midnight, a day at most) plus up to 2 min so the room does not all come at once.
    static func rest(_ data: Data?, status: Int?) -> TimeInterval? {
        guard status == 503 || status == 429, let data, data.count <= 1024,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], o["error"] as? String == "quota",
              let r = o["retry"] as? Double, r.isFinite else { return nil }
        return min(max(r, 1), 86_400) + .random(in: 0...120)
    }

    /// A line's id as sent: a UUID, upper case, or nil.
    static func lineID(_ s: String?) -> String? { s.flatMap(UUID.init(uuidString:))?.uuidString }

    /// Bound to the room and the sender's member id (AAD): a box posted again under another member id does not open.
    static func seal(_ e: MeetEvent, keys: MeetKeys, member: String) -> String? {
        guard let plain = try? JSONEncoder().encode(e), plain.count <= maxPlain,
              let box = try? AES.GCM.seal(plain, using: keys.key, authenticating: Data((keys.room + member).utf8)).combined else { return nil }
        return box.base64EncodedString()
    }

    static func open(_ b64: String, keys: MeetKeys, member: String) -> MeetEvent? {
        guard b64.count <= maxData, let d = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: d),
              let plain = try? AES.GCM.open(box, using: keys.key, authenticating: Data((keys.room + member).utf8)), plain.count <= maxPlain,
              let e = try? JSONDecoder().decode(MeetEvent.self, from: plain) else { return nil }
        return clean(e)
    }

    /// Only what each kind may carry: a known emote, one cleaned line, a status (퇴근한 척 as 퇴근), a checked note or
    /// doodle. Anything else is dropped.
    static func clean(_ e: MeetEvent) -> MeetEvent? {
        var out = MeetEvent(kind: e.kind, name: SocialText.nickname(e.name))
        switch e.kind {
        case .hello, .presence:
            out.status = e.status?.wire
            out.look = e.look.map(FriendLook.received)
        case .bye, .typing: break
        case .status:
            guard let s = e.status else { return nil }
            out.status = s.wire
        case .emote:
            guard let t = e.text, emotes.contains(t) else { return nil }
            out.text = t
        case .fortune:
            let t = SocialText.clean(e.text ?? "", max: maxLine)
            guard !t.isEmpty else { return nil }
            out.text = t
        case .line:
            let t = chat(e.text ?? "")
            guard !t.isEmpty else { return nil }
            out.text = t
            out.id = lineID(e.id)
        case .note:
            guard let n = e.note.flatMap(FriendNote.received) else { return nil }
            out.note = n
        case .doodle:
            guard let d = e.doodle.flatMap(Doodle.received) else { return nil }
            out.doodle = d
        case .draw:
            guard let d = e.draw.flatMap(DrawShare.received) else { return nil }
            out.draw = d
        case .hit:
            guard let i = e.item, ThrowRules.valid(i), let to = e.target, to.range(of: #"\A[0-9a-f]{32}\z"#, options: .regularExpression) != nil else { return nil }
            out.item = i
            out.target = to
        case .ko:
            guard let n = e.seconds, (1...10).contains(n) else { return nil }
            out.seconds = n
        }
        return out
    }

    /// The line shown for an event (without the name).
    static func describe(_ e: MeetEvent) -> String {
        switch e.kind {
        case .hello: return L("모임에 들어왔어요")
        case .presence: return ""
        case .bye: return L("모임에서 나갔어요")
        case .status: return e.status.map { "\($0.emoji) \($0.label)" } ?? ""
        case .emote, .line: return e.text ?? ""
        case .typing: return L("입력 중…")
        case .fortune: return L("오늘의 운세: \(e.text ?? "")")
        case .note: return e.note?.line.map { "💬 " + $0 } ?? ""
        case .doodle: return L("✏️ 낙서 쪽지")
        case .draw:
            guard let d = e.draw else { return "" }
            return "\(d.game.emoji) \(d.title ?? d.game.label): 👑 \(d.items[DrawRules.plan(d).winner])"
        case .hit:
            if e.item == ThrowRules.kiss { return L("💕 뽀뽀했어요") }
            return "🎯 " + (e.item.flatMap(Throwables.item)?.name ?? L("던지기"))
        case .ko: return L("💫 기절했어요")
        }
    }

    private struct Reply: Decodable {
        struct Item: Decodable { var s: Int; var m: String; var d: String }
        struct Live: Decodable { var m: String; var d: String; var a: Int }
        var seq: Int
        var members: Int
        var events: [Item]
        /// From a relay of `liveVersion` and up.
        var live: [Live]?
        var v: Int?
        var wait: Double?
    }

    /// Someone typing, `age` seconds ago at the relay.
    struct Typing: Equatable {
        var member: String
        var age: TimeInterval
    }

    struct Heard: Equatable {
        /// The relay's member id: what notes are kept by (a name is only what the sender says).
        var member: String
        var event: MeetEvent
    }

    struct Taken: Equatable {
        var events: [Heard]
        /// Ask after this next time.
        var seq: Int
        var members: Int
        var typing: [Typing] = []
        /// My own 한마디 ids the relay holds: sent for sure, even when the post's answer was lost.
        var mine: [String] = []
        /// The relay's protocol (1: before the live channel).
        var relay = 1
        /// Seconds the relay asks to wait before the next poll (0...300).
        var wait: TimeInterval = 0
    }

    /// Others' new events in a poll reply, oldest first. A seq below `after` means the room expired and started over.
    static func take(_ data: Data, me: String, after: Int, keys: MeetKeys) -> Taken? {
        guard data.count <= maxReply, let r = try? JSONDecoder().decode(Reply.self, from: data), r.seq >= 0 else { return nil }
        let from = r.seq < after ? 0 : after
        let items = r.events.prefix(maxEvents).filter { $0.s > from && $0.s <= r.seq }.sorted { $0.s < $1.s }
        let opened = items.compactMap { i in open(i.d, keys: keys, member: i.m).map { Heard(member: i.m, event: $0) } }
        // Live signals: typing only, one per member, never older than the relay keeps them.
        var typing: [Typing] = []
        for l in (r.live ?? []).prefix(maxMembers * 2) where l.m != me && !typing.contains(where: { $0.member == l.m }) {
            guard open(l.d, keys: keys, member: l.m)?.kind == .typing else { continue }
            typing.append(Typing(member: l.m, age: min(max(TimeInterval(l.a) / 1000, 0), SeatTalk.typingSeconds)))
        }
        return Taken(events: opened.filter { $0.member != me }, seq: max(from, r.seq), members: min(max(r.members, 0), maxMembers),
                     typing: typing, mine: opened.filter { $0.member == me && $0.event.kind == .line }.compactMap(\.event.id),
                     relay: max(1, min(r.v ?? 1, 99)), wait: min(max(r.wait ?? 0, 0), 300))
    }
}

/// Line ids already shown, per member: the last 200, so a resent line shows once.
struct MeetSeen {
    static let keep = 200
    private var order: [String] = []
    private var set: Set<String> = []

    /// True the first time `id` from `member` comes (a line without an id always counts as new).
    mutating func first(_ id: String?, from member: String) -> Bool {
        guard let id else { return true }
        let k = member + "|" + id
        guard set.insert(k).inserted else { return false }
        order.append(k)
        if order.count > Self.keep { set.remove(order.removeFirst()) }
        return true
    }
}

/// Someone else in the room as 친구 상주 shows them, by the relay's member id.
struct MeetMember: Equatable {
    var id: String
    var name: String
    var look: FriendLook
    var status: OfficeStatus
    /// System uptime of the last event from them.
    var heard: TimeInterval
}

/// Who stands in the room. Pure, tested (RemoteMeetTests).
enum MeetSeats {
    /// A member without an event for this long leaves the row (a build that never says hello again leaves it too).
    static let seatSeconds: TimeInterval = 45 * 60
    /// My hello goes again this often, so a member who came later (or whose list lost it) gets my look.
    static let helloEvery: TimeInterval = 20 * 60
    /// ...and when a new face says something, at most this often.
    static let helloAgain: TimeInterval = 60

    /// The members after `events`: a hello sets the name, look and status, a status its status, anything else the
    /// name; bye takes them out. `newFace`: someone not in the row spoke.
    static func heard(_ all: [String: MeetMember], _ events: [MeetWire.Heard], now: TimeInterval) -> (members: [String: MeetMember], newFace: Bool) {
        var m = all, newFace = false
        for h in events {
            let e = h.event
            guard e.kind != .bye else { m[h.member] = nil; continue }
            var x = m[h.member] ?? {
                newFace = true
                return MeetMember(id: h.member, name: e.name, look: .fallback, status: .working, heard: now)
            }()
            x.name = e.name
            x.heard = now
            if e.kind == .hello || e.kind == .presence, let look = e.look { x.look = look }
            if [.hello, .presence, .status].contains(e.kind), let s = e.status { x.status = s.wire }
            m[h.member] = x
        }
        return (m, newFace)
    }

    /// The row: heard from within `seatSeconds`, by name, `maxMembers - 1` at most (I am the last seat).
    static func row(_ all: [String: MeetMember], now: TimeInterval) -> [MeetMember] {
        Array(all.values.filter { now - $0.heard < seatSeconds }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }.prefix(MeetWire.maxMembers - 1))
    }
}

/// What a room member's head shows: their 한마디 for as long as it takes to read, else 입력 중 for 5.5 s after the
/// last signal (the relay keeps one 6 s; the sender sends one every 30 s at most, so a slow poll often misses it). Pure, tested.
struct SeatTalk: Equatable {
    static let typingSeconds: TimeInterval = 5.5
    enum Show: Equatable { case line(String), typing }

    private(set) var line: String?
    private(set) var lineUntil: TimeInterval = 0
    private(set) var typingUntil: TimeInterval = 0

    /// A line ends their typing.
    mutating func said(_ text: String, at now: TimeInterval) {
        line = text
        lineUntil = now + SpeechBubbleWindow.duration(text)
        typingUntil = 0
    }

    /// `age`: how old the signal already was at the relay.
    mutating func typing(at now: TimeInterval, age: TimeInterval = 0) {
        typingUntil = max(typingUntil, now + Self.typingSeconds - max(0, age))
    }

    func show(at now: TimeInterval) -> Show? {
        if let line, now < lineUntil { return .line(line) }
        return now < typingUntil ? .typing : nil
    }

    /// When `show` next changes, or nil when nothing shows.
    func next(after now: TimeInterval) -> TimeInterval? { [lineUntil, typingUntil].filter { $0 > now }.min() }
}

enum MeetPhase: Equatable {
    case off, noRoom, waiting, live(members: Int), full
    /// The relay's free day is used up (MeetWire.rest): back after UTC midnight.
    case resting

    /// The relay's answer: 200 live, 403 the room is full, anything else (no server yet, 503, offline) 연결 중.
    static func from(status: Int?, members: Int) -> MeetPhase {
        switch status {
        case 200: return .live(members: members)
        case 403: return .full
        default: return .waiting
        }
    }

    var label: String {
        switch self {
        case .off: return L("꺼짐")
        case .noRoom: return L("아직 모임이 없어요")
        case .waiting: return L("연결 중")
        case .live(let n): return L("연결됨 · \(n)명")
        case .full: return L("모임이 꽉 찼어요 (12명)")
        case .resting: return L("원격 모임 서버가 오늘 쓸 양을 다 써서 잠시 쉬어요. 하루 안에 다시 이어져요")
        }
    }
}

enum MeetRelay {
    static let host = "jelly-monitor.vercel.app"
    /// QA (`--qa-relay <url>`) points these at a local relay and polls faster; the app never changes them.
    static var endpoint = URL(string: "https://\(host)/api/relay")!
    static var pollSeconds: ClosedRange<TimeInterval> = 120...300
    /// While watched (a member's character or the room on screen) with someone else there. A poll with nothing new is
    /// 5 of the relay's 5,000 commands a day and of one address's 1,000 (web/api/relay.js), so not faster.
    static var fastSeconds: ClosedRange<TimeInterval> = 20...30

    /// The next poll: fast only while watched with others in the room, never sooner than the relay's `wait` (a day at
    /// most: the relay's quota retry).
    static func nextPoll(watched: Bool = false, members: Int = 0, wait: TimeInterval = 0) -> TimeInterval {
        max(.random(in: watched && members >= 2 ? fastSeconds : pollSeconds), min(max(wait, 0), 86_520))
    }
}

/// The room code in the Keychain (`com.jelly.charamonitor.meet`); tests and QA use `memory()`.
struct MeetCodeStore {
    var load: () -> String?
    var save: (String) -> Void
    var delete: () -> Void

    static let keychain: MeetCodeStore = {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jelly.charamonitor.meet",
                                kSecAttrAccount as String: "room"]
        return MeetCodeStore(load: {
            var r = q
            r[kSecReturnData as String] = true
            r[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(r as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8).flatMap(MeetCode.normalized)
        }, save: { code in
            SecItemDelete(q as CFDictionary)
            var item = q
            item[kSecValueData as String] = Data(code.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "캐릭모니터 원격 모임"
            SecItemAdd(item as CFDictionary, nil)
        }, delete: { SecItemDelete(q as CFDictionary) })
    }()

    static func memory(_ code: String? = nil) -> MeetCodeStore {
        final class Box { var code: String? }
        let box = Box()
        box.code = code
        return MeetCodeStore(load: { box.code }, save: { box.code = $0 }, delete: { box.code = nil })
    }
}

// MARK: The center

final class RemoteMeet: ObservableObject {
    static let shared = RemoteMeet()
    static let keep = 20
    /// 입력 중 goes at most this often while typing: each costs the relay's day 4 commands, and a slow poll sees it only
    /// when it lands within the relay's 6 s, so it is a rare hint, not a live one.
    static let typingEvery: TimeInterval = 30
    /// A 한마디 at most this often.
    static let lineEvery: TimeInterval = 1
    /// A sent 한마디 whose answer never came is 못 보냄 after this, unless a poll shows it in the room.
    static let pendingSeconds: TimeInterval = 20

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var text: String
        var mine: Bool
    }

    @Published private(set) var isOn = false
    @Published private(set) var phase: MeetPhase = .off
    @Published private(set) var code: String?
    /// The last 20 lines, in memory only.
    @Published private(set) var log: [Entry] = []
    /// Each member's last name and note by the relay's member id, in memory only.
    @Published private(set) var notes: [String: FriendCard] = [:]
    /// Who else is in the room, by the relay's member id (MeetSeats), in memory only.
    @Published private(set) var members: [String: MeetMember] = [:]
    /// QA: 입력 중 signals heard from others.
    private(set) var heardTyping = 0

    var defaults: UserDefaults = AppDefaults.store
    var codeStore: MeetCodeStore = .keychain
    var talk: TalkLog = .shared
    private var keys: MeetKeys?
    private var after = 0
    /// The first poll after a launch or a join only fills the log: no bubbles for what came before.
    private var primed = false
    private var polling = false
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var seen = MeetSeen()
    private var relay = 1, wait: TimeInterval = 0, roomSize = 0
    private var lastHello: TimeInterval = -.infinity, lastTyping: TimeInterval = -.infinity, lastLine: TimeInterval = -.infinity
    /// My 한마디 waiting for an answer: id to when it went.
    private var pending: [String: TimeInterval] = [:]
    /// The 대화 모아보기 window or the settings card showing the room (with the seats on screen: `watched`).
    private var watchers: Set<String> = []
    private var asleep = false
    private lazy var session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return c
    }())
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The seat's secret; what the room sees is `memberID`.
    private var member: String {
        if let m = defaults.string(forKey: "meet.secret"), m.count == 32 { return m }
        let m = MeetKeys.newMember()
        defaults.set(m, forKey: "meet.secret")
        return m
    }
    private var memberID: String { MeetKeys.memberID(member) }

    /// Call once at launch.
    func start() {
        guard bag.isEmpty else { return }
        isOn = defaults.bool(forKey: "meet.on")
        code = codeStore.load()
        refresh()
        SocialBus.shared.$myStatus.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.send(MeetEvent(kind: .status, name: "", status: s.wire)) }.store(in: &bag)
        let nc = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSWorkspace.screensDidSleepNotification).merge(with: nc.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.asleep = true }.store(in: &bag)
        nc.publisher(for: NSWorkspace.screensDidWakeNotification).merge(with: nc.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.asleep = false; self?.hurry() }.store(in: &bag)
    }

    func setOn(_ on: Bool) {
        defaults.set(on, forKey: "meet.on")
        isOn = on
        primed = false
        refresh()
    }

    /// Stops or (re)starts polling for the current switch and room.
    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard isOn else { phase = .off; members = [:]; return }
        guard let code else { phase = .noRoom; keys = nil; members = [:]; return }
        if keys == nil { keys = MeetKeys(code: code) }   // ponytail: ~50 ms of PBKDF2 on the main thread, once per room
        if phase == .off || phase == .noRoom { phase = .waiting }
        poll()
    }

    /// Fast polling is worth it only while someone could see what comes: a member's character on screen or the
    /// room open, and the screen awake.
    var watched: Bool { !asleep && (!watchers.isEmpty || FriendRoom.shared.showsRemote) }

    /// The 대화 모아보기 window or settings card (`who`) showing the room or not.
    func watch(_ who: String, _ on: Bool) {
        if on { watchers.insert(who); hurry() } else { watchers.remove(who) }
    }

    /// Polls soon when the next one is a slow one away (the room just came on screen).
    func hurry() {
        guard watched, roomSize >= 2, let t = timer, t.fireDate.timeIntervalSinceNow > MeetRelay.fastSeconds.upperBound, !polling else { return }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let fast = watched && roomSize >= 2
        let t = Timer(timeInterval: MeetRelay.nextPoll(watched: watched, members: roomSize, wait: wait), repeats: false) { [weak self] _ in self?.poll() }
        t.tolerance = fast ? 0.5 : 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func create() { join(MeetCode.make()) }

    func join(_ newCode: String) {
        guard let c = MeetCode.normalized(newCode) else { return }
        if code != nil { leave() }
        defaults.set(MeetKeys.newMember(), forKey: "meet.secret")   // a fresh seat id per room
        codeStore.save(c)
        code = c
        keys = nil
        after = 0
        primed = false
        log = []
        notes = [:]
        members = [:]
        refresh()
        hello(.hello)
        sendNote(SocialBus.shared.myNote())
    }

    func leave() {
        send(MeetEvent(kind: .bye, name: ""))
        codeStore.delete()
        code = nil
        keys = nil
        log = []
        notes = [:]
        members = [:]
        refresh()
    }

    /// My look and status for 친구 상주: `.hello` once when I join, `.presence` after that.
    private func hello(_ kind: MeetEvent.Kind = .presence) {
        // Only once it went: a hello dropped while resting goes again on the first poll after.
        if send(MeetEvent(kind: kind, name: "", status: SocialBus.shared.myStatus.wire, look: FriendLook.mine())) { lastHello = now }
    }

    func sendEmote(_ e: String) {
        send(MeetEvent(kind: .emote, name: "", text: e))
        SeasonCenter.shared.emoted()
    }

    /// A 한마디 (one a second at most). It shows in 대화 모아보기 as 보내는 중 until the relay answers, then 보냄 or 못 보냄;
    /// `again` sends a 못 보냄 one under its id again. False when nothing went.
    @discardableResult
    func sendLine(_ t: String, again id: String? = nil) -> Bool {
        let text = MeetWire.chat(t), t0 = now
        guard !text.isEmpty, t0 - lastLine >= Self.lineEvery || id != nil else { return false }
        let lineID = id ?? UUID().uuidString
        guard send(MeetEvent(kind: .line, name: "", text: text, id: lineID), lineID: lineID) else { return false }
        lastLine = t0
        lastTyping = -.infinity
        return true
    }

    func sendFortune() { send(MeetEvent(kind: .fortune, name: "", text: Fortune.today().headline)) }
    func sendNote(_ n: FriendNote) { send(MeetEvent(kind: .note, name: "", note: n)) }
    @discardableResult
    func sendDoodle(_ d: Doodle) -> Bool { send(MeetEvent(kind: .doodle, name: "", doodle: d)) }
    @discardableResult
    func sendDraw(_ d: DrawShare) -> Bool { send(MeetEvent(kind: .draw, name: "", draw: d)) }
    /// 던지기 놀이: the chosen item (or 고유행동) at a member by their relay id.
    func sendHit(_ wire: Int, to member: String) {
        var e = MeetEvent(kind: .hit, name: "")
        e.item = wire
        e.target = member
        send(e)
    }
    func sendKO(_ seconds: Int) {
        var e = MeetEvent(kind: .ko, name: "")
        e.seconds = seconds
        send(e)
    }

    /// The composer changed: 입력 중 to the room every `typingEvery` s, only through a relay that keeps it apart (an
    /// older one would put it in the event list, which keeps only the last 50).
    func typed() {
        guard relay >= MeetWire.liveVersion, now - lastTyping >= Self.typingEvery else { return }
        if send(MeetEvent(kind: .typing, name: ""), live: true) { lastTyping = now }
    }

    /// Mine goes in the log right away (not notes or typing). A 한마디 (`lineID`) is also tracked to 보냄 or 못 보냄.
    /// False when off, out of a room, the relay is resting (a bye still goes: it frees the seat) or the event does not seal.
    @discardableResult
    private func send(_ draft: MeetEvent, lineID: String? = nil, live: Bool = false) -> Bool {
        var draft = draft
        draft.name = SocialBus.shared.nickname
        guard isOn, phase != .resting || draft.kind == .bye, let keys, let e = MeetWire.clean(draft), let data = MeetWire.seal(e, keys: keys, member: memberID) else { return false }
        var fields: [String: Any] = ["room": keys.room, "member": member, "data": data]
        if e.kind == .bye { fields["leave"] = true }   // the relay frees the seat
        if live { fields["live"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return false }
        if let lineID {
            pending[lineID] = now
            if talk.has(lineID) { talk.mark(lineID, .pending) } else { append(e.name, MeetWire.describe(e), mine: true, lineID: lineID) }
        } else if ![.hello, .presence, .bye, .note, .typing].contains(e.kind) {
            append(e.name, MeetWire.describe(e), mine: true)
        }
        var req = URLRequest(url: MeetRelay.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { [weak self] _, response, _ in
            guard let lineID else { return }
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async { self?.posted(lineID, status: status) }
        }.resume()
        return true
    }

    /// 200 is 보냄; any other answer 못 보냄. No answer (a timeout) stays 보내는 중: the next polls look for it.
    private func posted(_ id: String, status: Int?) {
        guard let status, pending[id] != nil else { return }
        pending[id] = nil
        talk.mark(id, status == 200 ? .sent : .failed)
    }

    private func poll() {
        guard isOn, let keys, !polling else { return }
        polling = true
        // Room and member in headers, not the query: request logs keep the path.
        var u = URLComponents(url: MeetRelay.endpoint, resolvingAgainstBaseURL: false)!
        u.queryItems = [.init(name: "after", value: String(after))]
        var req = URLRequest(url: u.url!)
        req.setValue(keys.room, forHTTPHeaderField: "X-Room")
        req.setValue(member, forHTTPHeaderField: "X-Member")
        let me = memberID, from = after
        session.dataTask(with: req) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let taken = status == 200 ? data.flatMap { MeetWire.take($0, me: me, after: from, keys: keys) } : nil
            let rest = MeetWire.rest(data, status: status)
            DispatchQueue.main.async { self?.answered(status: taken == nil && status == 200 ? nil : status, taken, rest: rest, room: keys.room) }
        }.resume()
    }

    private func answered(status: Int?, _ taken: MeetWire.Taken?, rest: TimeInterval? = nil, room: String) {
        polling = false
        guard isOn, let keys else { return }
        guard keys.room == room else { poll(); return }   // switched rooms meanwhile: that room's poll was skipped
        phase = rest != nil ? .resting : .from(status: status, members: taken?.members ?? 0)
        wait = rest ?? (status == 429 || status == 503 ? 60 : taken?.wait ?? 0)   // quota: not before the relay's day opens
        if let taken {
            after = taken.seq
            relay = taken.relay
            roomSize = taken.members
            for id in taken.mine where talk.state(id) != .sent {   // in the room for sure, whatever the post's answer said
                pending[id] = nil
                talk.mark(id, .sent)
            }
            receive(taken.events, typing: taken.typing)
            primed = true
        }
        for (id, at) in pending where now - at > Self.pendingSeconds {
            pending[id] = nil
            talk.mark(id, .failed)
        }
        schedule()
    }

    private func receive(_ all: [MeetWire.Heard], typing: [MeetWire.Typing] = []) {
        let t = now, before = members
        let (m, newFace) = MeetSeats.heard(members, all, now: t)
        let row = Set(MeetSeats.row(m, now: t).map(\.id))
        let kept = m.filter { row.contains($0.key) }   // gone quiet for 45 min: out of the row
        if kept != members { members = kept }
        // Presence: a new face gets my look soon, everyone again every 20 min.
        if t - lastHello >= MeetSeats.helloEvery || (primed && newFace && t - lastHello >= MeetSeats.helloAgain) { hello() }
        for x in typing where members[x.member] != nil {
            heardTyping += 1
            FriendRoom.shared.typing("m:" + x.member, age: x.age)
        }
        for h in all where h.event.kind == .note { notes[h.member] = FriendCard(name: h.event.name, status: nil, note: h.event.note) }
        if notes.count > MeetWire.maxMembers * 4 { notes = [:] }   // seats change; never let it grow
        // 그룹 뽑기 goes in the record either way; it plays (panel open) only for a live one. The bubble below says it.
        for h in all where h.event.kind == .draw {
            h.event.draw.map { GroupDraw.shared.received($0, from: h.event.name, sender: "m:" + h.member, bubble: false) }
        }
        // 던지기 놀이: hits on me count, a few a poll at most; the first poll only fills the log.
        if primed {
            let me = memberID
            all.filter { $0.event.kind == .hit && $0.event.target == me }.prefix(ThrowCenter.maxPerPoll)
                .forEach { ThrowCenter.shared.hit($0.event.item ?? -1, by: $0.event.name) }
            // A member out cold: the stars over their seat in 친구 상주.
            for h in all where h.event.kind == .ko { FriendRoom.shared.knockedOut("m:" + h.member, seconds: h.event.seconds ?? 1) }
        }
        // A hello only from a new face (older builds send their 20-minute ones as hellos too); a 한마디 sent again (its
        // answer was lost) once.
        var greeted = Set<String>()
        let heard = all.filter { h in
            switch h.event.kind {
            case .note, .typing, .presence: return false
            case .hello: return before[h.member] == nil && greeted.insert(h.member).inserted
            case .line: return seen.first(h.event.id, from: h.member)
            default: return true
            }
        }
        let events = heard.map(\.event)
        heard.forEach { append($0.event.name, MeetWire.describe($0.event), mine: false) }
        guard !events.isEmpty else { return }
        if primed, events.contains(where: { $0.kind == .emote }) { SeasonCenter.shared.emoted() }   // once a poll at most
        // In a call or a recording: the log only, no bubble, doodle or wave.
        guard primed, !FriendVisit.quiet() else { return }
        // One doodle a poll at most: the last one.
        if let d = events.last(where: { $0.kind == .doodle }), let doodle = d.doodle {
            DoodleCenter.received(doodle, from: d.name, seat: nil)
        }
        // A 한마디 from someone standing in 친구 상주 shows over their head; the rest go in one bubble.
        let rest = heard.filter { !($0.event.kind == .line && FriendRoom.shared.said("m:" + $0.member, $0.event.text ?? "")) }.map(\.event)
        if let last = rest.last {
            let more = rest.count > 1 ? L(" (외 \(rest.count - 1)개)") : ""
            SpeechBubbleCenter.shared.say(text: "🌏 \(last.name): \(MeetWire.describe(last))" + more, source: .system, aloud: false, repeats: true)
        }
        if events.contains(where: { $0.kind == .emote && $0.text == "🎉" }) { DesktopKit.celebrate.send(.wave) }
    }

    private func append(_ name: String, _ text: String, mine: Bool, lineID: String? = nil) {
        log.append(Entry(name: name, text: text, mine: mine))
        if log.count > Self.keep { log.removeFirst(log.count - Self.keep) }
        talk.add(TalkEntry(thread: TalkEntry.meet, name: name, text: text, mine: mine, msgID: lineID, state: lineID == nil ? nil : .pending))
    }

    /// charamonitor://meet?code=... (the invite page's button). Any page can open the link, so it always asks first.
    func openLink(_ url: URL) {
        guard let c = MeetCode.code(in: url) else { return }
        guard isOn else {
            SpeechBubbleCenter.shared.say(text: L("원격 모임은 설정 > 플러그인에서 먼저 켜 주세요"), source: .system, aloud: false, repeats: true)
            FriendMenu.openSettings?()
            return
        }
        guard c != code else { return }
        let a = NSAlert()
        a.messageText = L("원격 모임에 들어갈까요?")
        a.informativeText = L("코드 \(c) 모임에 들어가요. 지금 모임이 있으면 거기서는 나가요.")
        a.addButton(withTitle: L("들어가기"))
        a.addButton(withTitle: L("취소"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { join(c) }
    }

    /// 한마디 보내기: up to 200 characters in a small dialog; typing in it tells the room 입력 중.
    func askLine() {
        let a = NSAlert()
        a.messageText = L("원격 모임에 한마디")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("200자까지")
        a.accessoryView = field
        a.addButton(withTitle: L("보내기"))
        a.addButton(withTitle: L("취소"))
        a.window.initialFirstResponder = field
        let typing = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { [weak self] _ in
            self?.typed()
        }
        defer { NotificationCenter.default.removeObserver(typing) }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { sendLine(field.stringValue) }
    }

    /// 데스크톱 친구 ▸ 원격 모임 ▸ (only while on and in a room).
    static func menuItems() -> [NSMenuItem] {
        guard shared.isOn, shared.code != nil else { return [] }
        let emotes = MeetWire.emotes.map { e in FriendMenu.item(e) { shared.sendEmote(e) } }
        return [FriendMenu.submenu(L("원격 모임"), emotes + [
            .separator(),
            FriendMenu.item(L("오늘 운세 보내기")) { shared.sendFortune() },
            FriendMenu.item(L("한마디 보내기…")) { shared.askLine() },
            FriendMenu.item(L("낙서 쪽지 보내기…")) { DoodleCenter.open(.meet, name: L("원격 모임")) },
            GroupDraw.menuItem(),
            FriendMenu.item(L("오늘 한마디…")) { SocialBus.shared.askLine() },
            FriendMenu.item(L("대화 모아보기…")) { RecentLog.open() },
        ] + throwItems())]
    }

    /// 던지기 ▸ each member with a card (while 던지기 놀이 is on): the chosen item, or 고유행동 at once.
    private static func throwItems() -> [NSMenuItem] {
        let c = ThrowCenter.shared
        guard c.isOn, !shared.notes.isEmpty else { return [] }
        let wire = c.move?.wire ?? c.item.wire
        return [FriendMenu.submenu(L("던지기"), shared.notes.sorted { $0.value.name < $1.value.name }.map { member, card in
            FriendMenu.item(card.name) { shared.sendHit(wire, to: member) }
        })]
    }

    #if !MAS
    /// QA renders (--render-meet) only: a state without the network.
    func qaShow(on: Bool, code: String?, phase: MeetPhase, log: [Entry]) {
        isOn = on
        self.code = code
        self.phase = phase
        self.log = log
    }

    /// QA (--render-remote, relay-e2e): events as a poll would bring them, members included.
    func qaHear(_ events: [MeetWire.Heard], typing: [MeetWire.Typing] = []) {
        primed = true
        receive(events, typing: typing)
    }
    #endif
}

// MARK: 설정 > 플러그인 > 원격 모임

struct RemoteMeetSettings: View {
    @ObservedObject private var meet = RemoteMeet.shared
    @ObservedObject private var bus = SocialBus.shared
    @State private var typed = ""
    @State private var line = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("원격 모임 켜기"), isOn: Binding(get: { meet.isOn }, set: meet.setOn)).toggleStyle(.switch).controlSize(.small)
            note(L("켜면 상태·이모트·운세·한마디·입력 중 표시·캐릭터 모습·프로필·낙서 쪽지만 종단간 암호화해서 중계 서버를 거쳐 보내요. 서버는 내용을 읽지 못하고 모임의 마지막 활동 24시간 뒤 지워요. 모임 친구는 친구 상주 자리에 캐릭터로 서고, 한마디는 머리 위 말풍선으로 떠요."))
            if meet.isOn {
                HStack {
                    Text(L("상태"))
                    Text(verbatim: meet.phase.label).foregroundStyle(.secondary)
                }
                if let code = meet.code { room(code) } else { joinRow }
                ThrowSettings()
                note(L("같이 놀기와 무전기는 계속 같은 와이파이에서만 돼요."))
            }
        }
        .font(.system(size: 12))
        .onAppear { meet.watch("settings", true) }
        .onDisappear { meet.watch("settings", false) }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var joinRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(L("새 모임 만들기")) { meet.create() }.controlSize(.small)
            HStack {
                TextField(L("받은 코드나 링크"), text: $typed).textFieldStyle(.roundedBorder).onSubmit(join)
                Button(L("들어가기"), action: join).controlSize(.small).disabled(MeetCode.parse(typed) == nil)
            }
            note(L("최대 12명까지 함께해요. 초대 링크나 코드를 친구에게 보내 주세요."))
        }
    }

    private func join() {
        guard let c = MeetCode.parse(typed) else { return }
        typed = ""
        meet.join(c)
    }

    private func room(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("모임 코드"))
                Text(verbatim: code).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied ? L("복사했어요") : L("초대 링크 복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetCode.link(code).absoluteString, forType: .string)
                    copied = true
                }.controlSize(.small)
                Button(L("나가기")) { meet.leave() }.controlSize(.small)
            }
            HStack(spacing: 4) {
                ForEach(MeetWire.emotes, id: \.self) { e in
                    Button { meet.sendEmote(e) } label: { Text(verbatim: e).font(.system(size: 15)) }.buttonStyle(.borderless)
                }
            }
            .disabled(meet.phase == .resting)   // send() drops all of these while the relay rests
            HStack {
                TextField(L("한마디 (200자까지)"), text: $line).textFieldStyle(.roundedBorder).onSubmit(sendLine)
                    .onChange(of: line) { t in if !t.isEmpty { meet.typed() } }
                Button(L("보내기"), action: sendLine).controlSize(.small).disabled(line.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(meet.phase == .resting)
            HStack {
                // Through OfficeCenter like the menu: a picked status is not overwritten by the 가상 오피스 auto rule.
                Picker(L("내 상태"), selection: Binding(get: { bus.myStatus }, set: { OfficeCenter.shared.set($0) })) {
                    ForEach(OfficeStatus.allCases, id: \.self) { s in Text(verbatim: "\(s.emoji) \(s.label)").tag(s) }
                }.fixedSize()
                Spacer(minLength: 0)
            }
            // Own row: next to the picker the English labels were cut to "Sen…".
            HStack {
                Group {
                    Button(L("오늘 운세 보내기")) { meet.sendFortune() }.controlSize(.small).fixedSize()
                    Button(L("낙서 쪽지")) { DoodleCenter.open(.meet, name: L("원격 모임")) }.controlSize(.small).fixedSize()
                }
                .disabled(meet.phase == .resting)
                Button(L("그룹 뽑기")) { GroupDraw.shared.show() }.controlSize(.small).fixedSize()   // also for friends nearby
            }
            Text(L("사진은 근처 친구 대화에서만 보낼 수 있어요. 원격 모임은 중계 서버를 거치고 한 번에 2KB까지라 사진을 싣지 않아요."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !meet.notes.isEmpty {
                HStack(spacing: 4) {
                    Text(L("프로필")).font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(meet.notes.sorted { $0.value.name < $1.value.name }, id: \.key) { _, card in
                        Button(card.name) { FriendCardPanel.show(card) }.controlSize(.small)
                    }
                }
            }
            if !meet.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(meet.log.suffix(6)) { e in
                        Text(verbatim: "\(e.mine ? L("나") : e.name): \(e.text)").font(.system(size: 11))
                            .foregroundStyle(e.mine ? .secondary : .primary).lineLimit(1)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func sendLine() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if meet.sendLine(line) { line = "" }
    }
}

#if !MAS
/// --render-meet <폴더>: the settings card in each state, light and dark.
enum MeetQA {
    static func render(to dir: URL) throws {
        let m = RemoteMeet.shared
        m.codeStore = .memory()
        let log = [RemoteMeet.Entry(name: "보리", text: L("모임에 들어왔어요"), mine: false),
                   RemoteMeet.Entry(name: "보리", text: "🎉", mine: false),
                   RemoteMeet.Entry(name: "나", text: "☕", mine: true),
                   RemoteMeet.Entry(name: "콩이", text: L("오늘의 운세: \(Fortune.headlines[1])"), mine: false),
                   RemoteMeet.Entry(name: "콩이", text: "🍚 \(OfficeStatus.meal.label)", mine: false),
                   RemoteMeet.Entry(name: "보리", text: L("오늘 저녁 7시 게임 어때?"), mine: false)]
        let states: [(String, Bool, String?, MeetPhase, [RemoteMeet.Entry])] = [
            ("off", false, nil, .off, []), ("noroom", true, nil, .noRoom, []), ("waiting", true, "K7QZ2MPAW4RHN", .waiting, []),
            ("live", true, "K7QZ2MPAW4RHN", .live(members: 3), log), ("full", true, "K7QZ2MPAW4RHN", .full, []),
            ("resting", true, "K7QZ2MPAW4RHN", .resting, log),
        ]
        for (name, on, code, phase, entries) in states {
            m.qaShow(on: on, code: code, phase: phase, log: entries)
            try DashboardSnapshot.snapshot(RemoteMeetSettings().frame(width: 360).padding(), appearance: .aqua,
                                           to: dir.appendingPathComponent("meet-\(name).png"))
        }
        m.qaShow(on: true, code: "K7QZ2MPAW4RHN", phase: .live(members: 3), log: log)
        try DashboardSnapshot.snapshot(RemoteMeetSettings().frame(width: 360).padding(), appearance: .darkAqua,
                                       to: dir.appendingPathComponent("meet-live-dark.png"))
        try DashboardSnapshot.snapshot(PluginsSection().frame(width: 400).padding(), appearance: .aqua,
                                       to: dir.appendingPathComponent("meet-plugins.png"))
    }
}
#endif

#if !MAS
/// --render-remote <폴더>: 원격 모임 members in 친구 상주 with a 3-line 한마디, 입력 중 and two bubbles stacked apart, on
/// the bottom and the top edge; 대화 모아보기 with 보내는 중·보냄·못 보냄; the settings card at 12. Light and dark.
enum RemoteRoomQA {
    static func render(to dir: URL) throws {
        let cat = FriendLook(character: .cat, id: CatCatalog.all.first?.id, profile: nil, colors: nil, cat: nil, outfit: nil)
        let friends = [SocialFriend(id: "qa-a", nickname: "콩이", look: .fallback, status: .working, pairedAt: Date()),
                       SocialFriend(id: "m:b", nickname: "보리", look: cat, status: .working, pairedAt: .distantPast),
                       SocialFriend(id: "m:c", nickname: "두부", look: .fallback, status: .meal, pairedAt: .distantPast),
                       SocialFriend(id: "m:d", nickname: "호두", look: cat, status: .off, pairedAt: .distantPast)]
        let seats = friends.map(RoomSeat.init)
        let long = MeetWire.chat("오늘 저녁 7시에 다같이 게임 어때? 지난번에 하던 거 이어서 하자\n늦으면 먼저 시작해도 돼\n간식은 내가 챙겨 갈게 🍪")
        let shows: [SeatTalk.Show?] = [nil, .line(long), .typing, .line(L("나 먼저 퇴근!"))]
        for edge in [RoomEdge.bottom, .top] {
            for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(scene(seats, shows, edge: edge), appearance: a,
                                               to: dir.appendingPathComponent("room-\(edge.rawValue)-\(suffix).png"))
            }
        }

        let talk = TalkLog()
        let t0 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        talk.qaShow([
            TalkEntry(date: t0.addingTimeInterval(-86400), thread: TalkEntry.meet, name: "보리", text: L("모임에 들어왔어요"), mine: false),
            TalkEntry(date: t0.addingTimeInterval(-86000), thread: "qa-a", name: "", text: "내일 회의 몇 시죠?", mine: false),
            TalkEntry(date: t0, thread: TalkEntry.meet, name: "보리", text: long, mine: false),
            TalkEntry(date: t0.addingTimeInterval(40), thread: TalkEntry.meet, name: "", text: "좋아! 8시까지 갈게", mine: true, msgID: UUID().uuidString, state: .sent),
            TalkEntry(date: t0.addingTimeInterval(70), thread: TalkEntry.meet, name: "", text: "치킨도 시킬까?", mine: true, msgID: UUID().uuidString, state: .failed),
            TalkEntry(date: t0.addingTimeInterval(75), thread: "qa-a", name: "", text: "3시요", mine: true),
            TalkEntry(date: t0.addingTimeInterval(80), thread: TalkEntry.meet, name: "", text: "아니면 피자", mine: true, msgID: UUID().uuidString, state: .pending),
        ])
        let meet = RemoteMeet()
        meet.qaShow(on: true, code: "K7QZ2MPAW4RHN", phase: .live(members: 4), log: [])
        let suite = "qa.dogmonitor.remote.talk"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        for (a, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            d.set(suffix == "dark", forKey: TalkLog.keepKey)   // the switch both ways
            talk.defaults = d
            try DashboardSnapshot.snapshot(RecentLogView(log: talk, meet: meet, name: { $0 == "qa-a" ? "콩이" : "?" }, draft: "그럼 피자로")
                .frame(width: 360, height: 520), appearance: a, to: dir.appendingPathComponent("recent-\(suffix).png"))
        }
        let shared = RemoteMeet.shared
        shared.codeStore = .memory()
        for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            shared.qaShow(on: true, code: "K7QZ2MPAW4RHN", phase: .full, log: [])
            try DashboardSnapshot.snapshot(RemoteMeetSettings().frame(width: 360).padding(), appearance: look, to: dir.appendingPathComponent("settings-full-\(name).png"))
            shared.qaShow(on: true, code: nil, phase: .noRoom, log: [])
            try DashboardSnapshot.snapshot(RemoteMeetSettings().frame(width: 360).padding(), appearance: look, to: dir.appendingPathComponent("settings-noroom-\(name).png"))
        }
    }

    /// The seats along `edge` of a 760-wide desktop, bubbles placed and stacked as FriendRoom does.
    private static func scene(_ seats: [RoomSeat], _ shows: [SeatTalk.Show?], edge: RoomEdge) -> some View {
        let vf = CGRect(x: 0, y: 0, width: 760, height: 300)
        let panels = seats.indices.map { i in CGRect(origin: RoomRules.origin(i, edge: edge, size: seats[i].size, in: vf), size: seats[i].size) }
        let bubbled = seats.indices.filter { shows[$0] != nil }
        let sizes = bubbled.map { NSHostingView(rootView: SeatBubbleView(show: shows[$0]!, tailUp: edge == .top, t: 0.3)).fittingSize }
        let frames = RoomBubbles.stacked(zip(bubbled, sizes).map { i, s in
            RoomBubbles.frame(seat: panels[i], sprite: seats[i].cache.imageSize, size: s, edge: edge, in: vf)
        }, down: edge == .top)
        // AppKit frames (y up) to SwiftUI positions (y down).
        func at(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: vf.height - r.midY) }
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.93), Color(red: 0.55, green: 0.72, blue: 0.48)], startPoint: .top, endPoint: .bottom)
            ForEach(seats.indices, id: \.self) { i in
                RoomFriendView(seat: seats[i], t: 0.45).frame(width: panels[i].width, height: panels[i].height).position(at(panels[i]))
            }
            ForEach(Array(zip(bubbled, frames).enumerated()), id: \.offset) { _, p in
                SeatBubbleView(show: shows[p.0]!, tailUp: edge == .top, t: 0.3).frame(width: p.1.width, height: p.1.height).position(at(p.1))
            }
        }
        .frame(width: vf.width, height: vf.height)
    }
}
#endif
