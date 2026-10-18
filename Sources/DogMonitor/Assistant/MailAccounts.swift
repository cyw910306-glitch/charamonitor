import Foundation
import Security

// 메일 계정 알림 (AI 비서, both builds): Gmail, 네이버, 다음, iCloud or any IMAP server, without Apple Mail.
// IMAP + an app password (no OAuth). The password lives in the keychain only; the account list (server, address)
// in AppDefaults.store; where each inbox ended (UIDNEXT) in memory only, so a relaunch learns again instead of
// reading out what came while the app was closed. New mail goes through InboxCenter like every other inbox line.

enum MailPreset: String, CaseIterable, Codable, Identifiable {
    case gmail, naver, daum, icloud, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .naver: return L("네이버 메일")
        case .daum: return L("다음 메일")
        case .icloud: return L("iCloud 메일")
        case .custom: return L("직접 입력")
        }
    }

    /// Incoming IMAP server, all on 993 with TLS (each provider's own help page, see notes in the commit).
    var host: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .naver: return "imap.naver.com"
        case .daum: return "imap.daum.net"
        case .icloud: return "imap.mail.me.com"
        case .custom: return ""
        }
    }

    /// Where the app password is made.
    var passwordURL: URL? {
        switch self {
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .naver: return URL(string: "https://nid.naver.com/")
        case .daum: return URL(string: "https://accounts.kakao.com/")
        case .icloud: return URL(string: "https://account.apple.com/")
        case .custom: return nil
        }
    }

    /// What to do before adding the account.
    var help: String {
        switch self {
        case .gmail:
            return L("Google 계정에서 2단계 인증을 켠 뒤, '발급 페이지 열기'에서 앱 비밀번호(16자리)를 만들어 넣어 주세요. 평소 비밀번호로는 연결되지 않아요.")
        case .naver:
            return L("네이버 메일 > 환경설정 > POP3/IMAP 설정에서 'IMAP/SMTP 사용'을 켜 주세요. 2단계 인증을 쓰고 있으면 네이버 ID > 보안설정 > 2단계 인증 관리 > 애플리케이션 비밀번호 관리에서 만든 비밀번호를 넣어요.")
        case .daum:
            return L("다음 메일 > 설정 > IMAP/POP3에서 '사용함'으로 켜 주세요. 카카오계정 > 계정 보안 > 2단계 인증 > 앱 비밀번호에서 만든 비밀번호를 넣어요 (평소 비밀번호는 안 돼요).")
        case .icloud:
            return L("Apple 계정(account.apple.com) > 로그인 및 보안 > 앱 암호에서 만든 암호를 넣어 주세요. 2단계 인증이 켜져 있어야 만들 수 있어요.")
        case .custom:
            return L("메일 서비스의 도움말에서 IMAP 서버 주소를 확인해 넣어 주세요. 보안 연결(SSL/TLS) 포트만 돼요 (보통 993).")
        }
    }
}

struct MailAccount: Codable, Equatable, Identifiable {
    var preset: MailPreset
    var host: String
    var port: Int
    /// The login: the address (네이버·iCloud also take the ID alone).
    var user: String
    var on: Bool
    /// What LOGIN takes when it is not `user`: 네이버·다음 may want only the ID before the @. The id stays the address,
    /// so the keychain item does not move.
    var login: String?
    /// What every LOGIN / AUTH sends (IMAP check, agent reads, SMTP, the sent copy).
    var loginName: String { login ?? user }

    var id: String { "\(user.lowercased())@\(host.lowercased())" }
}

/// The app password, one keychain item per account: service "com.jelly.dogmonitor.mail.<address>", account the server.
enum MailKeychain {
    /// Tests use their own prefix and delete what they made.
    static var prefix = "com.jelly.dogmonitor.mail."

    private static func query(_ a: MailAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: prefix + a.user.lowercased(),
         kSecAttrAccount as String: a.host.lowercased()]
    }

    @discardableResult
    static func save(_ password: String, for a: MailAccount) -> Bool {
        SecItemDelete(query(a) as CFDictionary)
        var item = query(a)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly   // stays on this Mac
        item[kSecAttrLabel as String] = "캐릭모니터 메일 (\(a.user))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(for a: MailAccount) -> String? {
        var q = query(a)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(for a: MailAccount) { SecItemDelete(query(a) as CFDictionary) }
}

enum MailStatus: Equatable {
    case checking
    case ok(Date)
    /// Login refused: polling stops until a new password is put in (repeated failures can lock the account).
    case login(String)
    case network(String)
}

final class MailAccounts: ObservableObject {
    static let shared = MailAccounts()
    static let interval: TimeInterval = 2 * 60
    /// A new UID with a Date older than this was moved into the inbox (from the archive, a filter), not received.
    static let oldMail: TimeInterval = 24 * 60 * 60

    private let d: UserDefaults
    private static let key = "assistant.mail.accounts"

    @Published private(set) var accounts: [MailAccount] {
        didSet { d.set(try? JSONEncoder().encode(accounts), forKey: Self.key) }
    }
    @Published private(set) var status: [String: MailStatus] = [:]

    private var boxes: [String: IMAPMailbox] = [:]
    private var lastCheck: [String: Date] = [:]
    private var polling = false
    /// Read from the keychain once per account and run (a re-signed build asks for each read), never off this Mac.
    private var passwords: [String: String] = [:]
    /// Bumped by retry, remove and switching off: a check that started before lands nowhere.
    private var generation: [String: Int] = [:]

    /// Opens a connection; tests script a server instead (no real connection in tests).
    var connect: (MailAccount) async throws -> IMAPTransport = { try await NWTransport.open(host: $0.host, port: $0.port) }
    /// Where new mail goes: InboxCenter's batching, mute, preview and screen-share rules.
    var deliver: ([InboxItem]) -> Void = { items in Task { @MainActor in InboxCenter.shared.mailArrived(items) } }

    init(defaults: UserDefaults = AppDefaults.store) {
        d = defaults
        accounts = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MailAccount].self, from: $0) } ?? []
    }

    var anyOn: Bool { accounts.contains(where: \.on) }
    func isOn(_ id: String) -> Bool { accounts.contains { $0.id == id && $0.on } }

    /// "네이버 메일"; with two accounts of one kind, "네이버 메일 (kim)"; a custom server goes by its host.
    func label(_ a: MailAccount) -> String {
        let base = a.preset == .custom ? a.host : a.preset.title
        let twins = accounts.filter { $0.preset == a.preset && (a.preset != .custom || $0.host == a.host) }.count
        return twins > 1 ? "\(base) (\(a.user.split(separator: "@").first.map(String.init) ?? a.user))" : base
    }

    // MARK: Changing the list

    /// Connects once with the password (so a typo shows right away), then saves. Returns what went wrong, nil on success.
    @MainActor
    func add(preset: MailPreset, user: String, password: String, host: String? = nil, port: Int = 993) async -> String? {
        var user = user.trimmingCharacters(in: .whitespaces)
        if preset == .naver, user.lowercased().hasSuffix("@naver.com") { user = String(user.dropLast(10)) }   // IMAP login is the ID
        let host = (host ?? preset.host).trimmingCharacters(in: .whitespaces).lowercased()
        guard !user.isEmpty, !password.isEmpty else { return L("주소와 앱 비밀번호를 넣어 주세요.") }
        guard !host.isEmpty, (1...65535).contains(port) else { return L("IMAP 서버 주소와 포트를 넣어 주세요.") }
        var a = MailAccount(preset: preset, host: host, port: port, user: user, on: true)
        guard !accounts.contains(where: { $0.id == a.id }) else { return L("이미 추가한 계정이에요.") }
        var result = await check(a, password: password, since: nil)
        // 네이버·다음 sometimes take only the ID: the address refused, the part before the @ once more.
        if case .failure(IMAPError.login) = result, let id = Self.idLogin(preset, user) {
            var b = a
            b.login = id
            let again = await check(b, password: password, since: nil)
            if case .success = again { a = b; result = again }
        }
        switch result {
        case .failure(let e): return Self.words(e, preset)
        case .success(let (box, _)):
            guard MailKeychain.save(password, for: a) else { return L("키체인에 비밀번호를 저장하지 못했어요.") }
            accounts.append(a)
            boxes[a.id] = box
            lastCheck[a.id] = Date()
            status[a.id] = .ok(Date())
            passwords[a.id] = password
            return nil
        }
    }

    /// A new password for an account whose login failed.
    @MainActor
    func retry(_ id: String, password: String) async -> String? {
        guard let a = accounts.first(where: { $0.id == id }) else { return nil }
        let g = bump(id)
        status[id] = .checking
        let result = await check(a, password: password, since: nil)
        guard generation[id] == g, accounts.contains(where: { $0.id == id }) else { return nil }   // removed meanwhile
        switch result {
        case .failure(let e):
            let why = Self.words(e, a.preset)
            status[id] = Self.status(e, why)
            return why
        case .success(let (box, _)):
            MailKeychain.save(password, for: a)
            passwords[id] = password
            boxes[id] = box
            lastCheck[id] = Date()
            status[id] = .ok(Date())
            return nil
        }
    }

    @MainActor
    func remove(_ id: String) {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        MailKeychain.delete(for: a)
        accounts.removeAll { $0.id == id }
        forget(id)
    }

    @MainActor
    func setOn(_ id: String, _ on: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].on = on
        if !on { forget(id) }
    }

    /// Off or gone: where it ended is forgotten (on again later: learns first, no flood), and so is what it said.
    @MainActor
    private func forget(_ id: String) {
        bump(id)
        passwords[id] = nil
        boxes[id] = nil
        lastCheck[id] = nil
        status[id] = nil
        InboxCenter.forget(.mail) { $0.account == id }
    }

    @MainActor @discardableResult
    private func bump(_ id: String) -> Int {
        generation[id, default: 0] += 1
        return generation[id]!
    }

    /// QA render only (its own defaults suite): made-up accounts and states, no keychain, no connection.
    func showForQA(_ list: [MailAccount], _ states: [String: MailStatus]) {
        accounts = list
        status = states
    }

    // MARK: Checking

    /// InboxCenter's tick: each switched-on account every `interval`, one check at a time.
    /// ponytail: accounts are checked one after another; a dead server holds the rest up to its 30 s timeout.
    @MainActor
    func poll(now: Date = Date()) async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        for a in accounts where a.on {
            switch status[a.id] { case .login, .checking: continue; default: break }   // waiting for a password, or retry runs
            if let last = lastCheck[a.id], now.timeIntervalSince(last) < Self.interval - 5 { continue }
            lastCheck[a.id] = now
            let g = generation[a.id, default: 0]
            // Off the main thread: a keychain prompt (re-signed build) must not freeze the menu bar.
            let cached = passwords[a.id]
            let loaded = cached != nil ? cached : await Task.detached { MailKeychain.load(for: a) }.value
            guard generation[a.id, default: 0] == g, isOn(a.id) else { continue }   // retried, switched off or removed
            guard let password = loaded else {
                fail(a, .login(L("키체인에서 비밀번호를 찾지 못했어요. 앱 비밀번호를 다시 넣어 주세요.")))
                continue
            }
            passwords[a.id] = password
            let result = await check(a, password: password, since: boxes[a.id])
            guard generation[a.id, default: 0] == g, isOn(a.id) else { continue }   // same, while checking
            switch result {
            case .failure(let e):
                let why = Self.words(e, a.preset)
                fail(a, Self.status(e, why))
            case .success(let (box, mails)):
                boxes[a.id] = box
                status[a.id] = .ok(now)
                let subject = InboxSettings.shared.mailSubject
                let items = mails.filter { m in !m.seen && m.date.map { now.timeIntervalSince($0) < Self.oldMail } ?? true }
                    .map { InboxItem(kind: .mail, who: $0.sender.isEmpty ? L("모르는 사람") : $0.sender,
                                     preview: subject && !$0.subject.isEmpty ? $0.subject : nil, date: now,
                                     via: label(a), account: a.id) }
                if !items.isEmpty { deliver(items) }
            }
        }
    }

    /// A login that stops working (password changed, app password revoked) is said once: bubble and 비서 설정.
    @MainActor
    private func fail(_ a: MailAccount, _ s: MailStatus) {
        let was = status[a.id]
        status[a.id] = s
        if case .login = s, was != s {
            let why = L("\(label(a)) 로그인이 안 돼요. 비서 설정 > 메일 계정에서 앱 비밀번호를 확인해 주세요.")
            AssistantSettings.shared.integrationNotice = why
            SpeechBubbleCenter.shared.say(text: why, source: .system, aloud: false)
        }
    }

    @MainActor
    private func check(_ a: MailAccount, password: String, since: IMAPMailbox?) async -> Result<(IMAPMailbox, [IMAPMail]), Error> {
        do {
            let t = try await connect(a)
            return .success(try await IMAPCheck.run(t, user: a.loginName, password: password, since: since))
        } catch {
            return .failure(error)
        }
    }

    /// The ID to try when 네이버·다음 refused the full address, nil for other mail or a login without an @. Pure.
    static func idLogin(_ preset: MailPreset, _ user: String) -> String? {
        guard preset == .naver || preset == .daum, let at = user.firstIndex(of: "@"), at > user.startIndex else { return nil }
        return String(user[..<at])
    }

    private static func status(_ e: Error, _ why: String) -> MailStatus {
        if case .login = e as? IMAPError { return .login(why) }
        return .network(why)
    }

    /// An error in words for 비서 설정. Pure.
    static func words(_ e: Error, _ preset: MailPreset) -> String {
        switch e as? IMAPError {
        case .login:
            return L("로그인에 실패했어요. ") + preset.help
        case .server(let s):
            return L("메일 서버가 거절했어요: \(String(s.prefix(80)))")
        case .network, .none:
            return L("메일 서버에 연결하지 못했어요. 인터넷 연결과 서버 주소를 확인해 주세요. 다음 확인 때 다시 시도해요.")
        }
    }
}
