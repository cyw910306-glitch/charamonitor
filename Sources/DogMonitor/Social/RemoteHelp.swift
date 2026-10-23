import AppKit
import Network

// 원격 지원: a paired friend asks, the owner says yes, then the friend's Mac opens macOS Screen Sharing to this one,
// which asks the owner once more. The app never turns Screen Sharing on, never captures the screen, never sends
// input. Mac to Mac by construction (both ends are this app). Key: social.remoteHelp = 받기 허용, OFF.

/// One pending ask per friend, 3 asks per 10 minutes; an ask stays answerable for 90 s.
struct RemoteAskLimit {
    static let perWindow = 3
    static let window: TimeInterval = 600
    static let answerable: TimeInterval = 90
    private var asks: [String: [TimeInterval]] = [:]
    private var pending: [String: TimeInterval] = [:]

    mutating func ask(_ id: String, now: TimeInterval) -> Bool {
        if let at = pending[id], now - at < Self.answerable { return false }
        let recent = (asks[id] ?? []).filter { now - $0 < Self.window }
        guard recent.count < Self.perWindow else { return false }
        asks[id] = recent + [now]
        pending[id] = now
        return true
    }

    /// Whether an answer from `id` is one we asked for. `final` false keeps it pending (Screen Sharing was off and the
    /// owner may send again).
    mutating func answered(_ id: String, now: TimeInterval, final: Bool) -> Bool {
        guard let at = pending[id], now - at < Self.answerable else { pending[id] = nil; return false }
        pending[id] = final ? nil : at   // the ask's own time: answers never keep it open past 90 s
        return true
    }
}

final class RemoteHelp {
    static let shared = RemoteHelp()
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!
    private var limit = RemoteAskLimit()
    /// Owner side: the same limit on asks that come in (one alert per 90 s, 3 per 10 minutes per friend), so a
    /// friend's Mac cannot keep an alert up.
    private var incoming = RemoteAskLimit()
    /// Owner side: friends whose ask is on screen now.
    private var asking: Set<String> = []

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func name(_ id: String) -> String { SocialBus.shared.friend(id)?.nickname ?? L("친구") }
    private func say(_ text: String) { SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true) }

    /// Requester: 원격 지원 요청.
    func ask(_ id: String) {
        guard PluginGate.isOpen(.remoteHelp), SocialBus.shared.online.contains(id) else { return }
        guard limit.ask(id, now: now) else { say(L("원격 지원 요청은 잠시 뒤에 다시 보내 주세요.")); return }
        SocialBus.shared.send(.remoteAsk, to: id)
        say(L("\(name(id))에게 원격 지원을 요청했어요."))
    }

    func receive(_ m: SocialMessage, from id: String) {
        switch m {
        case .remoteAsk: asked(by: id)
        case let .remoteAnswer(accept, on): answered(by: id, accept: accept, screenSharingOn: on)
        default: break
        }
    }

    // MARK: Owner

    private func asked(by id: String) {
        guard PluginGate.isOpen(.remoteHelp), SocialBus.shared.defaults.bool(forKey: "social.remoteHelp") else {
            SocialBus.shared.send(.remoteAnswer(accept: false, screenSharingOn: false), to: id)   // silently
            return
        }
        guard incoming.ask(id, now: now), asking.insert(id).inserted else { return }   // over the limit: no answer at all
        DispatchQueue.main.async { [self] in
            let n = name(id)
            let yes = SocialAlerts.ask(L("\(n)가 내 화면을 보고 도와주려 해요."),
                                       L("수락하면 \(n)의 맥에서 화면 공유가 열리고, 이 맥이 한 번 더 허락을 물어요."),
                                       [L("수락"), L("거절")], timeout: 60, safe: 1) == .alertFirstButtonReturn
            asking.remove(id)
            guard yes else { SocialBus.shared.send(.remoteAnswer(accept: false, screenSharingOn: false), to: id); return }
            reply(to: id)
        }
    }

    /// Accepted: tells the friend whether Screen Sharing is on here; when it is off, shows how to turn it on.
    private func reply(to id: String) {
        Self.screenSharingOn { [self] on in
            SocialBus.shared.send(.remoteAnswer(accept: true, screenSharingOn: on), to: id)
            if !on { DispatchQueue.main.async { self.guide(id) } }
        }
    }

    private func guide(_ id: String) {
        let r = SocialAlerts.ask(L("화면 공유가 꺼져 있어요"), L("시스템 설정 > 일반 > 공유 > 화면 공유를 켜 주세요. 켠 다음 다시 보내기를 누르면 친구 맥에서 열려요."),
                                 [L("시스템 설정 열기"), L("다시 보내기"), L("닫기")], timeout: 120)
        switch r {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(Self.settingsURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.guide(id) }
        case .alertSecondButtonReturn:
            reply(to: id)
        default:
            break
        }
    }

    /// Screen Sharing listens on 5900 when it is on. 1 s at most.
    static func screenSharingOn(_ done: @escaping (Bool) -> Void) {
        let c = NWConnection(host: "127.0.0.1", port: 5900, using: .tcp)
        var answered = false
        let finish = { (on: Bool) in
            guard !answered else { return }
            answered = true
            c.cancel()
            done(on)
        }
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(false) }
    }

    // MARK: Requester

    private func answered(by id: String, accept: Bool, screenSharingOn on: Bool) {
        guard limit.answered(id, now: now, final: !accept || on) else { return }
        guard accept else { say(L("\(name(id))가 지금은 원격 지원을 받지 않아요.")); return }
        guard on else { say(L("상대 맥에서 화면 공유가 꺼져 있어요, 켜는 방법을 보냈어요")); return }
        guard let url = SocialBus.shared.remoteHost(id).flatMap(Self.vncURL) else { say(L("\(name(id)) 맥의 주소를 찾지 못했어요")); return }
        NSWorkspace.shared.open(url)
    }

    /// vnc:// to the address the connection really reaches: IPv4 (also when mapped into IPv6), or IPv6 in brackets
    /// with its %25 zone. nil for a name, which could say anything.
    static func vncURL(_ host: NWEndpoint.Host) -> URL? {
        switch host {
        case .ipv4(let a):
            return ntop(AF_INET, a.rawValue).flatMap { URL(string: "vnc://\($0)") }
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return ntop(AF_INET, v4.rawValue).flatMap { URL(string: "vnc://\($0)") } }
            guard var s = ntop(AF_INET6, a.rawValue) else { return nil }
            if let zone = a.interface?.name, a.isLinkLocal { s += "%25" + zone }
            return URL(string: "vnc://[\(s)]")
        default:
            return nil
        }
    }

    private static func ntop(_ family: Int32, _ raw: Data) -> String? {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) != nil }
        return ok ? String(cString: buf) : nil
    }
}
