import AppKit
import CryptoKit
import Network
import Security

// 근처 친구 on the wire: Bonjour `_charamonitor._tcp`, TLS 1.2 ECDHE-PSK (TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256,
// so a key stolen later opens no recorded talk), frames of a 4-byte big-endian length and a JSON body. The key is the
// pair's 32-byte friend key, so a Mac that is not a friend never gets past the handshake. Each listener picks a new
// random salt; its TXT carries the salt and one tag per friend (HMAC of that friend's key over the salt), and the
// dialer's PSK identity is that tag, so neither the TXT nor the handshake says which install it is. The dialer's
// first frame then proves which key it holds (an HMAC over the TLS exporter), so the sender of every message is the
// key that opened the connection, never a field in it. The install id shows only in the TXT of 친구 추가.

/// 4-byte big-endian length + body, 64 KiB at most.
enum SocialWire {
    static let maxFrame = 64 * 1024

    static func frame(_ body: Data) -> Data {
        var n = UInt32(body.count).bigEndian
        return Data(bytes: &n, count: 4) + body
    }

    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }

    /// The length a 4-byte header says, nil when it is over the limit (the link closes).
    static func length(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { $0 << 8 | Int($1) }
        return n <= maxFrame ? n : nil
    }
}

enum SocialCrypto {
    static let pairIdentity = "pair"

    /// The pairing channel's PSK: HMAC-SHA256(key: code, "charamonitor-pair-v1").
    static func pairKey(_ code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("charamonitor-pair-v1".utf8), using: SymmetricKey(data: Data(code.utf8))))
    }

    /// The friend key both Macs derive from the pairing's X25519 exchange: HKDF-SHA256(secret, salt: code,
    /// info: both ids sorted and joined), 32 bytes.
    static func friendKey(_ secret: SharedSecret, code: String, ids: [String]) -> Data {
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                                 sharedInfo: Data(ids.sorted().joined(separator: ":").utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The dialer's first frame: proof that it holds `key`, bound to this TLS session.
    static func proof(_ key: Data, exporter: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: exporter + Data("charamonitor-client".utf8), using: SymmetricKey(data: key)))
    }

    /// Six digits, 000000 to 999999.
    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// The 확인 숫자 both Macs show before a pairing is saved, "123 456": from the new friend key, so a Mac in the
    /// middle (which ends up with two different keys) shows two different numbers.
    static func check(_ key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("charamonitor-check-v1".utf8), using: SymmetricKey(data: key))
        let s = String(format: "%06d", Data(mac).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000)
        return "\(s.prefix(3)) \(s.suffix(3))"
    }

    /// A friend's tag in one listener's TXT, and the PSK identity that dials it: HMAC(key, salt), 12 hex digits.
    static func tag(_ key: Data, salt: String) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: Data("charamonitor-tag-v1:\(salt)".utf8), using: SymmetricKey(data: key))).prefix(6))
    }

    static func newSalt() -> String { hex(Data((0..<8).map { _ in UInt8.random(in: 0...255) })) }

    /// What the joiner's first hello carries instead of its key, so neither end can pick its key after seeing the
    /// other's (that would let a Mac in the middle make the two 확인 숫자 match).
    static func commit(_ pub: Data) -> Data { Data(SHA256.hash(data: pub)) }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

/// Friend keys: Keychain items `com.jelly.charamonitor.friend` / friend id; tests use `memory()`.
struct FriendKeys {
    var load: (String) -> Data?
    /// false when the Keychain would not take it.
    var save: (Data, String) -> Bool
    var delete: (String) -> Void

    static let service = "com.jelly.charamonitor.friend"

    static let keychain: FriendKeys = {
        func query(_ id: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        }
        return FriendKeys(load: { id in
            var q = query(id)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
            return d
        }, save: { key, id in
            SecItemDelete(query(id) as CFDictionary)
            var item = query(id)
            item[kSecValueData as String] = key
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "캐릭모니터 근처 친구"
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }, delete: { id in SecItemDelete(query(id) as CFDictionary) })
    }()

    static func memory() -> FriendKeys {
        final class Box { var keys: [String: Data] = [:] }
        let box = Box()
        return FriendKeys(load: { box.keys[$0] }, save: { box.keys[$1] = $0; return true }, delete: { box.keys[$0] = nil })
    }
}

/// Who I am and my half of the key exchange, in the pairing channel.
struct PairHello: Codable, Equatable {
    var id: String
    var nickname: String
    var look: FriendLook
    /// X25519 public key, 32 bytes; in the joiner's hello its `SocialCrypto.commit` instead (the key follows in `reveal`).
    var pub: Data
}

/// The pairing channel, in this order only: the joiner's hello, the host's hello, the joiner's `reveal`, then a `yes`
/// from each side once its owner saw the same 확인 숫자 on both Macs. Anything else closes the link.
enum PairStep: Codable, Equatable {
    case hello(PairHello)
    case reveal(Data)
    case yes
}

/// One pairing in progress, kept on its link.
final class PairSession {
    let code: String
    let priv = Curve25519.KeyAgreement.PrivateKey()
    /// Joiner: the id the picked Mac's TXT showed; the host's hello must say the same.
    var expect: String?
    var peer: PairHello?
    /// Host: the joiner's commitment, from its hello.
    var commit: Data?
    var key: Data?
    var mine = false, theirs = false, done = false

    init(code: String, expect: String? = nil) {
        self.code = code
        self.expect = expect
    }

    var pub: Data { priv.publicKey.rawRepresentation }
}

/// Chat text as it may show: no control, bidi or zero-width characters, 200 characters at most.
enum SocialText {
    static let maxChat = 200

    static func clean(_ s: String, max: Int = maxChat) -> String {
        let hidden: Set<UInt32> = [0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF, 0x00AD]
        let scalars = s.unicodeScalars.filter { u in
            if hidden.contains(u.value) || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value) { return false }
            if u == " " { return true }
            return !CharacterSet.controlCharacters.contains(u) && !CharacterSet.newlines.contains(u)
        }
        var t = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        if t.count > max { t = String(t.prefix(max)) }
        return t
    }

    /// A nickname: the same, 16 characters, never empty.
    static func nickname(_ s: String) -> String {
        let t = clean(s, max: 16)
        return t.isEmpty ? L("친구") : t
    }
}

/// Per link: chat 1 a second, voice 60, 같이 놀기 30, a look (or hello, which carries one) 2 in 4 s since each one
/// rewrites the friend list, everything else 10 a second. Over that the message is dropped.
struct SocialRateLimit {
    enum Kind { case chat, voice, play, look, other }
    private var window: [Kind: (start: TimeInterval, count: Int)] = [:]

    static func kind(_ m: SocialMessage) -> Kind {
        switch m {
        case .chat: return .chat
        case .voice: return .voice
        case .play: return .play
        case .look, .hello: return .look
        default: return .other
        }
    }

    static func limit(_ k: Kind) -> (count: Int, per: TimeInterval) {
        switch k {
        case .chat: return (1, 1)
        case .voice: return (60, 1)
        case .play: return (30, 1)
        case .look: return (2, 4)
        case .other: return (10, 1)
        }
    }

    mutating func allow(_ m: SocialMessage, now: TimeInterval) -> Bool {
        let k = Self.kind(m), rule = Self.limit(k)
        var w = window[k] ?? (now, 0)
        if now - w.start >= rule.per { w = (now, 0) }
        w.count += 1
        window[k] = w
        return w.count <= rule.count
    }
}

/// One TLS connection to another Mac. A friend link, or a pairing link (identity "pair"). Runs on the main queue.
final class SocialLink {
    enum Role { case dialer, listener }
    let conn: NWConnection
    let role: Role
    /// The friend on the other end, once proven (a dialer knows it from the start).
    private(set) var friendID: String?
    private(set) var isPairing: Bool
    private(set) var ready = false
    /// When a listener accepted it, so a full handshake queue drops the oldest.
    var since: TimeInterval = 0
    private var limit = SocialRateLimit()
    private(set) var isClosed = false

    /// Listener side: which key the first frame proves (a friend id, or `SocialCrypto.pairIdentity`).
    var identify: (_ proof: Data, _ exporter: Data) -> String? = { _, _ in nil }
    var onReady: (SocialLink) -> Void = { _ in }
    var onMessage: (SocialLink, SocialMessage) -> Void = { _, _ in }
    var onPair: (SocialLink, PairStep) -> Void = { _, _ in }
    /// `wrongKey`: the TLS handshake failed on the key itself (a wrong code), not a scan, a timeout or an unknown tag.
    var onClose: (SocialLink, _ wrongKey: Bool) -> Void = { _, _ in }

    private let key: Data?
    /// A pairing dialer's hello, sent right after the proof.
    var firstPair: PairStep?
    /// The pairing this link carries.
    var pairing: PairSession?

    /// Dial `endpoint` with a friend's key and the tag its TXT shows, or with `pairKey` (friendID nil) for pairing.
    init(dial endpoint: NWEndpoint, identity: String, friendID: String?, key: Data) {
        role = .dialer
        self.friendID = friendID
        isPairing = friendID == nil
        self.key = key
        conn = NWConnection(to: endpoint, using: SocialNode.parameters([(key, friendID == nil ? SocialCrypto.pairIdentity : identity)]))
    }

    init(accepted conn: NWConnection) {
        role = .listener
        isPairing = false
        key = nil
        self.conn = conn
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.opened()
            case .failed(let e): self.close(wrongKey: !self.ready && Self.wrongKey(e))
            case .cancelled, .waiting: self.close()   // waiting: nobody there; the browser dials again later
            default: break
            }
        }
        conn.start(queue: .main)
    }

    /// The PSK did not match (bad record MAC): what a wrong code looks like. A port scan, an unknown identity (a
    /// friend's old tag) or a timeout fails otherwise.
    static func wrongKey(_ e: NWError) -> Bool {
        if case .tls(let status) = e { return status == errSSLBadRecordMac }
        return false
    }

    private func opened() {
        guard let exporter = Self.exporter(conn) else { close(); return }
        if role == .dialer, let key {
            conn.send(content: SocialWire.frame(SocialCrypto.proof(key, exporter: exporter)), completion: .idempotent)
            ready = true
            if let p = firstPair { sendPair(p) }
            if !isPairing { onReady(self) }
            receive()
        } else {
            readFrame { [weak self] proof in
                guard let self else { return }
                guard let who = self.identify(proof, exporter) else { self.close(); return }
                self.isPairing = who == SocialCrypto.pairIdentity
                self.friendID = self.isPairing ? nil : who
                self.ready = true
                if !self.isPairing { self.onReady(self) }
                self.receive()
            }
        }
    }

    static func exporter(_ conn: NWConnection) -> Data? {
        guard let m = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = "EXPORTER-charamonitor-v1"
        guard let secret = sec_protocol_metadata_create_secret(m.securityProtocolMetadata, label.utf8.count, label, 32) else { return nil }
        return Data(secret as DispatchData)
    }

    func send(_ m: SocialMessage) {
        guard ready, !isPairing, let body = SocialWire.encode(m) else { return }
        conn.send(content: SocialWire.frame(body), completion: .idempotent)
    }

    func sendPair(_ step: PairStep) {
        guard isPairing, let body = SocialWire.encode(step) else { return }
        conn.send(content: SocialWire.frame(body), completion: .idempotent)
    }

    private func readFrame(_ got: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, error in
            guard let self, error == nil, let head, let n = SocialWire.length(head) else { self?.close(); return }
            guard n > 0 else { got(Data()); return }
            self.conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] body, _, _, error in
                guard error == nil, let body, body.count == n else { self?.close(); return }
                got(body)
            }
        }
    }

    private func receive() {
        readFrame { [weak self] body in
            guard let self, !self.isClosed else { return }
            if self.isPairing {
                guard let step = SocialWire.decode(PairStep.self, body) else { self.close(); return }
                self.onPair(self, step)
            } else {
                guard let m = SocialWire.decode(SocialMessage.self, body) else { self.close(); return }   // a bad frame closes the link
                if self.limit.allow(m, now: ProcessInfo.processInfo.systemUptime) { self.onMessage(self, m) }
            }
            self.receive()
        }
    }

    func close(wrongKey: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        conn.stateUpdateHandler = nil
        conn.cancel()
        onClose(self, wrongKey)
    }

    /// The other Mac's address as Screen Sharing wants it, from the live connection only.
    var remoteHost: NWEndpoint.Host? {
        if case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint { return host }
        if case .hostPort(let host, _) = conn.endpoint { return host }
        return nil
    }
}

/// A Mac nearby in 친구 추가 mode, from its Bonjour TXT.
struct NearbyMac: Identifiable, Hashable {
    var id: String
    var nickname: String
    var endpoint: NWEndpoint
}

/// Listener, browser and links of one install. SocialBus runs one; tests run two over loopback (`bonjour` false).
final class SocialNode {
    static let serviceType = "_charamonitor._tcp"
    static let pairSeconds: TimeInterval = 120
    /// Wrong codes before a new code shows; twice that ends 친구 추가.
    static let pairTries = 3
    /// Connections not past the handshake: at most this many (the oldest goes for a new one), 2 per address,
    /// each for at most `handshakeSeconds`.
    static let maxPending = 8
    static let maxPendingPerAddress = 2
    static let handshakeSeconds: TimeInterval = 10

    let myID: String
    let keys: FriendKeys
    let bonjour: Bool
    /// The ids of my friends right now.
    var friendIDs: () -> [String] = { [] }
    /// For the pairing channel and its TXT.
    var me: () -> (nickname: String, look: FriendLook) = { (L("친구"), .fallback) }
    /// Seconds an address waits after each wrong code from it, while 친구 추가 is on (tests 0).
    var backoff: TimeInterval = 2

    var onOnline: (String, Bool) -> Void = { _, _ in }
    var onMessage: (String, SocialMessage) -> Void = { _, _ in }
    /// Both sides, once the other Mac's key is in: show the 확인 숫자 and ask. Answer true to become friends; it is saved
    /// only when the other side says yes too.
    var onPairRequest: (PairHello, _ check: String, @escaping (Bool) -> Void) -> Void = { _, _, answer in answer(false) }
    /// Both sides: the key is saved; add the friend.
    var onPaired: (SocialFriend) -> Void = { _ in }
    /// Joiner: it did not work (wrong code, declined, gone, or the Keychain said no).
    var onPairFailed: () -> Void = {}
    /// Host: too many wrong codes, 친구 추가 ended.
    var onPairGuessed: () -> Void = {}
    var onNearby: ([NearbyMac]) -> Void = { _ in }
    /// My code while 친구 추가 shows it, nil after (2 minutes, or 6 wrong codes; every 3 make a new one).
    var onCode: (String?) -> Void = { _ in }

    private(set) var running = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private(set) var links: [String: SocialLink] = [:]
    private var pending: [ObjectIdentifier: SocialLink] = [:]
    private var dialing: Set<NWEndpoint> = []
    private var results: Set<NWBrowser.Result> = []
    /// This listener's salt (its TXT `s`); new with each listener.
    private(set) var salt = SocialCrypto.newSalt()
    private var serviceName = SocialNode.newServiceName()
    /// Every service name this node used, so its own adverts are never taken for a friend's.
    private var myNames: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private(set) var code: String?
    private var codeTries = 0
    private var codeTimer: DispatchWorkItem?
    /// Per remote address while 친구 추가 is on: wrong codes and when it may connect again.
    private var strikes: [String: (count: Int, until: TimeInterval)] = [:]
    /// Joiner: the pairing link.
    private var joining: SocialLink?

    init(myID: String, keys: FriendKeys, bonjour: Bool = true) {
        self.myID = myID
        self.keys = keys
        self.bonjour = bonjour
    }

    var port: NWEndpoint.Port? { listener?.port }
    var online: Set<String> { Set(links.keys) }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func newServiceName() -> String { String(UUID().uuidString.prefix(8)) }

    static func parameters(_ psks: [(Data, String)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let o = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(o, .TLSv12)
        for (key, identity) in psks {
            let k = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let i = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(o, k as __DispatchData, i as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(o, tls_ciphersuite_t(rawValue: suite)!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 5
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905).
    static let suite: UInt16 = 0xCCAC

    // MARK: Up and down

    func start() {
        guard !running else { return }
        running = true
        relisten()
        if bonjour {
            browse()
            // A new salt and name each day and after each sleep (a Mac that moved networks), so the advert never follows it.
            let renew: (Notification) -> Void = { [weak self] _ in self?.relisten() }
            observers = [NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: renew),
                         NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: renew)]
        }
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        endPairing()
        joining?.close()
        joining = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        results = []
        (Array(links.values) + Array(pending.values)).forEach { $0.close() }
        links = [:]; pending = [:]; dialing = []
    }

    /// A new listener with the current keys, salt and name (friends changed, pairing began or ended). Open links stay.
    func relisten() {
        listener?.cancel(); listener = nil
        guard running else { return }
        salt = SocialCrypto.newSalt()
        serviceName = Self.newServiceName()
        var txt = NWTXTRecord(["v": "2", "s": salt])
        var psks: [(Data, String)] = []
        for id in friendIDs() {
            guard let key = keys.load(id) else { continue }
            let tag = SocialCrypto.tag(key, salt: salt)
            psks.append((key, tag))
            txt[tag] = "1"
        }
        if let code {
            psks.append((SocialCrypto.pairKey(code), SocialCrypto.pairIdentity))
            txt["pair"] = "1"; txt["id"] = myID; txt["nick"] = me().nickname
        }
        guard !psks.isEmpty, let l = try? NWListener(using: Self.parameters(psks), on: .any) else { return }
        if bonjour {
            myNames.insert(serviceName)
            l.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil, txtRecord: txt)
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            if case .failed = state, let self, l === self.listener { self.listener = nil }
        }
        l.start(queue: .main)
        listener = l
    }

    /// Waits until the listener has a port (tests).
    func whenListening(_ then: @escaping (NWEndpoint.Port?) -> Void) {
        guard let l = listener else { then(nil); return }
        if l.state == .ready, let p = l.port, p.rawValue != 0 { then(p); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.whenListening(then) }
    }

    /// The remote address of a connection, for the wrong-code wait.
    private static func address(_ e: NWEndpoint) -> String {
        if case .hostPort(let host, _) = e { return "\(host)" }
        return "\(e)"
    }

    private func accept(_ c: NWConnection) {
        let from = Self.address(c.endpoint)
        if code != nil && (strikes[from]?.until ?? 0) > now { c.cancel(); return }
        let waiting = pending.values.filter { $0.role == .listener && !$0.ready }
        if waiting.filter({ Self.address($0.conn.endpoint) == from }).count >= Self.maxPendingPerAddress { c.cancel(); return }
        // Evicted while a code shows: counted as a wrong code, so flooding can't hide a guess's failure.
        if waiting.count >= Self.maxPending { waiting.min { $0.since < $1.since }?.close(wrongKey: true) }
        let link = SocialLink(accepted: c)
        link.since = now
        let pairing = code
        link.identify = { [weak self] proof, exporter in
            guard let self else { return nil }
            if let pairing, SocialCrypto.proof(SocialCrypto.pairKey(pairing), exporter: exporter) == proof { return SocialCrypto.pairIdentity }
            return self.friendIDs().first { id in self.keys.load(id).map { SocialCrypto.proof($0, exporter: exporter) == proof } ?? false }
        }
        wire(link)
        pending[ObjectIdentifier(link)] = link
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeSeconds) { [weak link] in
            if let link, !link.ready { link.close() }
        }
    }

    private func wire(_ link: SocialLink) {
        link.onReady = { [weak self] l in self?.linked(l) }
        link.onMessage = { [weak self] l, m in
            guard let self, let id = l.friendID, self.links[id] === l else { return }
            self.onMessage(id, m)
        }
        link.onPair = { [weak self] l, step in
            guard let self else { return }
            if l.role == .dialer { self.joinerGot(l, step) } else { self.hostGot(l, step) }
        }
        link.onClose = { [weak self] l, wrong in self?.closed(l, wrongKey: wrong) }
    }

    private func linked(_ link: SocialLink) {
        guard let id = link.friendID else { return }
        pending[ObjectIdentifier(link)] = nil
        dialing.remove(link.conn.endpoint)
        let old = links[id]
        links[id] = link
        if let old, old !== link { old.onClose = { _, _ in }; old.close() }
        if old == nil { onOnline(id, true) }
    }

    private func closed(_ link: SocialLink, wrongKey: Bool) {
        pending[ObjectIdentifier(link)] = nil
        if link.role == .listener, wrongKey, code != nil { wrongTry(from: Self.address(link.conn.endpoint)) }
        if joining === link { joining = nil; onPairFailed() }
        if link.role == .dialer { dialing.remove(link.conn.endpoint) }
        guard let id = link.friendID else { return }
        if links[id] === link {
            links[id] = nil
            onOnline(id, false)
            if running { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dialFound() } }
        }
    }

    // MARK: Friends

    /// Dials a friend at `endpoint` with the salt its TXT shows (the browser does this by itself; tests call it with a
    /// loopback port and the other node's `salt`). Every advert that shows the friend's tag is tried, so a copied
    /// advert pointing elsewhere cannot hold the real one back.
    func dial(_ friendID: String, at endpoint: NWEndpoint, salt: String) {
        guard running, links[friendID] == nil, !dialing.contains(endpoint), let key = keys.load(friendID) else { return }
        dialing.insert(endpoint)
        let link = SocialLink(dial: endpoint, identity: SocialCrypto.tag(key, salt: salt), friendID: friendID, key: key)
        wire(link)
        pending[ObjectIdentifier(link)] = link
        link.start()
    }

    func send(_ m: SocialMessage, to id: String) { links[id]?.send(m) }

    func drop(_ id: String) { links[id]?.close() }

    func remoteHost(_ id: String) -> NWEndpoint.Host? { links[id]?.remoteHost }

    // MARK: Bonjour

    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] all, _ in
            self?.results = all
            self?.dialFound()
        }
        b.start(queue: .main)
        browser = b
    }

    private static func txt(_ r: NWBrowser.Result) -> NWTXTRecord? {
        if case .bonjour(let t) = r.metadata { return t }
        return nil
    }

    /// The lower id dials, so two friends make one link.
    private func dialFound() {
        guard running else { return }
        let friends = friendIDs().compactMap { id in keys.load(id).map { (id, $0) } }
        var nearby: [NearbyMac] = []
        for r in results {
            if case .service(let name, _, _, _) = r.endpoint, myNames.contains(name) { continue }
            guard let t = Self.txt(r), t["v"] == "2" else { continue }
            if t["pair"] == "1", let id = t["id"], id != myID {
                nearby.append(NearbyMac(id: id, nickname: SocialText.nickname(t["nick"] ?? ""), endpoint: r.endpoint))
            }
            guard let salt = t["s"] else { continue }
            for (id, key) in friends where myID < id && t[SocialCrypto.tag(key, salt: salt)] != nil {
                dial(id, at: r.endpoint, salt: salt)
            }
        }
        onNearby(nearby.sorted { $0.nickname < $1.nickname })
    }

    // MARK: Pairing

    /// Host: shows a new 6-digit code for 2 minutes (its TXT says so meanwhile).
    @discardableResult
    func showCode() -> String {
        let c = SocialCrypto.newCode()
        code = c
        codeTries = 0
        strikes = [:]
        codeTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.endPairing() }
        codeTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairSeconds, execute: t)
        relisten()
        onCode(c)
        return c
    }

    func endPairing() {
        codeTimer?.cancel(); codeTimer = nil
        guard code != nil else { return }
        code = nil
        strikes = [:]
        pending.values.filter { $0.isPairing && !($0.pairing?.done ?? false) }.forEach { $0.close() }
        relisten()
        onCode(nil)
    }

    /// Every 3 wrong codes a new one shows, keeping the old one's end (failing never buys time); 6 end 친구 추가.
    private func wrongTry(from: String) {
        let n = (strikes[from]?.count ?? 0) + 1
        strikes[from] = (n, now + backoff * Double(n))
        codeTries += 1
        if codeTries >= Self.pairTries * 2 {
            endPairing()
            onPairGuessed()
        } else if codeTries % Self.pairTries == 0 {
            let c = SocialCrypto.newCode()
            code = c
            relisten()
            onCode(c)
        }
    }

    /// Joiner: dial the Mac showing its code (`id` from its TXT), with the code typed.
    func join(_ endpoint: NWEndpoint, id: String, code: String) {
        joining?.close()
        let link = SocialLink(dial: endpoint, identity: SocialCrypto.pairIdentity, friendID: nil, key: SocialCrypto.pairKey(code))
        let s = PairSession(code: code, expect: id)
        link.pairing = s
        joining = link
        wire(link)
        let mine = me()
        link.firstPair = .hello(PairHello(id: myID, nickname: mine.nickname, look: mine.look, pub: SocialCrypto.commit(s.pub)))
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairSeconds) { [weak self, weak link] in
            if let link, self?.joining === link { link.close() }
        }
    }

    /// An id a pairing may add: not mine, not empty, and not a friend already (that would replace their key).
    private func newFriend(_ id: String) -> Bool {
        id != myID && !id.isEmpty && id.count <= 64 && !friendIDs().contains(id)
    }

    private func agree(_ s: PairSession, _ pub: Data, with id: String) -> Data? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
              let secret = try? s.priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return SocialCrypto.friendKey(secret, code: s.code, ids: [myID, id])
    }

    /// Host: the joiner's hello gets mine, its key then the question.
    private func hostGot(_ link: SocialLink, _ step: PairStep) {
        switch step {
        case .hello(let h) where link.pairing == nil:
            guard let c = code, newFriend(h.id), h.pub.count == 32 else { link.close(); return }
            let s = PairSession(code: c)
            s.peer = h
            s.commit = h.pub
            link.pairing = s
            let mine = me()
            link.sendPair(.hello(PairHello(id: myID, nickname: mine.nickname, look: mine.look, pub: s.pub)))
        case .reveal(let pub):
            guard let s = link.pairing, s.key == nil, let h = s.peer, SocialCrypto.commit(pub) == s.commit,
                  let key = agree(s, pub, with: h.id) else { link.close(); return }
            s.key = key
            ask(link, s)
        case .yes:
            theirYes(link)
        default:
            link.close()
        }
    }

    /// Joiner: the host's hello (it must be the Mac picked) gets my key, then the question.
    private func joinerGot(_ link: SocialLink, _ step: PairStep) {
        guard joining === link, let s = link.pairing else { link.close(); return }
        switch step {
        case .hello(let h) where s.peer == nil:
            guard h.id == s.expect, newFriend(h.id), let key = agree(s, h.pub, with: h.id) else { link.close(); return }
            s.peer = h
            s.key = key
            link.sendPair(.reveal(s.pub))
            ask(link, s)
        case .yes:
            theirYes(link)
        default:
            link.close()
        }
    }

    private func theirYes(_ link: SocialLink) {
        guard let s = link.pairing, s.key != nil, !s.theirs else { link.close(); return }
        s.theirs = true
        finish(link, s)
    }

    private func ask(_ link: SocialLink, _ s: PairSession) {
        guard let h = s.peer, let key = s.key else { return }
        onPairRequest(h, SocialCrypto.check(key)) { [weak self, weak link] yes in
            guard let self, let link, !link.isClosed else { return }
            guard yes else { link.close(); return }
            s.mine = true
            link.sendPair(.yes)
            self.finish(link, s)
        }
    }

    /// Both owners said yes: save. The host's code is used up; the link closes once the last yes is across.
    private func finish(_ link: SocialLink, _ s: PairSession) {
        guard s.mine, s.theirs, !s.done, let h = s.peer, let key = s.key else { return }
        s.done = true
        if joining === link { joining = nil }
        if link.role == .listener { endPairing() }
        guard save(h, key: key) else { link.close(); onPairFailed(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak link] in link?.close() }
    }

    private func save(_ hello: PairHello, key: Data) -> Bool {
        guard keys.save(key, hello.id) else { return false }
        onPaired(SocialFriend(id: hello.id, nickname: SocialText.nickname(hello.nickname), look: FriendLook.received(hello.look),
                              status: .working, pairedAt: Date()))
        relisten()
        dialFound()
        return true
    }
}
