import CryptoKit
import Foundation

// Design section 6 (frozen actions and execution) and the audit log of section 8. The card renders from a FrozenAction
// only, approval re-hashes and re-guards it, and Executor is the only code that runs an action. Nothing here talks to a
// model or the network: `perform` is injected by the integrator (MailSender, NativeActions, KoreanLinks).

/// Decision lives in the shared contract without Codable; a FrozenAction is persisted, so it needs one. Written by hand
/// because Swift cannot synthesize Codable in an extension outside the type's file.
extension Decision: Codable {
    private enum CodingKeys: String, CodingKey { case tier, needsReview, reasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tier: try c.decode(Tier.self, forKey: .tier),
                  needsReview: try c.decode(Bool.self, forKey: .needsReview),
                  reasons: try c.decodeIfPresent([String].self, forKey: .reasons) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tier, forKey: .tier)
        try c.encode(needsReview, forKey: .needsReview)
        try c.encode(reasons, forKey: .reasons)
    }
}

/// One proposal as the owner saw it. Never mutated in place except `state` and `finishedAt`: an edit is a new one.
struct FrozenAction: Codable, Equatable, Identifiable {
    enum State: Codable, Equatable {
        case proposed
        case approved
        case running
        case done(summary: String, undoID: String?)
        case failed(reason: String)
        /// The mail may or may not have left (a timeout after DATA). Never retried: the owner checks 보낸메일함.
        case unknown(reason: String)
        case cancelled
        case expired

        var label: String {
            switch self {
            case .proposed: return "proposed"
            case .approved: return "approved"
            case .running: return "running"
            case .done: return "done"
            case .failed: return "failed"
            case .unknown: return "unknown"
            case .cancelled: return "cancelled"
            case .expired: return "expired"
            }
        }

        var isFinished: Bool {
            switch self {
            case .proposed, .approved, .running: return false
            default: return true
            }
        }
    }

    /// Also the idempotency key and the Message-ID seed, so a resend of the same card is the same mail.
    let id: UUID
    let action: AgentAction
    let origin: Origin
    let decision: Decision
    /// AgentGuard's messages at proposal time, shown on the card.
    let concerns: [String]
    /// The reviewer model's line ("2차 검토 못 함" included), nil when it did not run.
    let reviewer: String?
    let createdAt: Date
    let expiresAt: Date
    let sha256: String
    var state: State = .proposed
    var finishedAt: Date?

    /// Chat cards are answered while the owner is there; goal cards wait for the owner to come back.
    static func lifetime(_ origin: Origin) -> TimeInterval { origin == .chat ? 30 * 60 : 12 * 3600 }

    init(id: UUID = UUID(), action: AgentAction, origin: Origin, decision: Decision, concerns: [String] = [],
         reviewer: String? = nil, createdAt: Date) {
        self.id = id
        self.action = action
        self.origin = origin
        self.decision = decision
        self.concerns = concerns
        self.reviewer = reviewer
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(Self.lifetime(origin))
        self.sha256 = Self.hash(action)
    }

    /// Sorted keys and ISO 8601 dates, so the same action always hashes the same, before and after a trip to disk.
    static func canonical() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func hash(_ action: AgentAction) -> String {
        let data = (try? canonical().encode(action)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Proof that the owner tapped this exact card. Only PendingStore.approve can make one (fileprivate init), and only
/// the card's button handler calls approve.
struct ApprovalToken: Equatable {
    let id: UUID
    let hash: String
    fileprivate init(id: UUID, hash: String) {
        self.id = id
        self.hash = hash
    }
}

/// What `perform` reports back. `summary` reaches the audit log (dropped for outbound actions) and the model.
struct PerformResult: Equatable {
    var summary: String
    /// EventKit eventIdentifier/calendarItemIdentifier, kept 10 minutes for 되돌리기.
    var undoID: String?
}

/// `perform` throws this when the mail may already have left (a timeout or drop after DATA). The card becomes
/// `.unknown` and is never retried.
struct MailUnknown: Error, Equatable {
    var reason: String
}

/// Append-only `actions.jsonl`: one line per state change. Outbound actions log recipient domains only, never the
/// subject, body or any summary that could carry them.
final class AuditLog {
    let url: URL
    let maxBytes: Int

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ f: FrozenAction, state: String, summary: String, undoID: String? = nil, now: Date) {
        var line: [String: String] = [
            "time": ISO8601DateFormatter().string(from: now),
            "id": f.id.uuidString,
            "type": f.action.type.rawValue,
            "origin": f.origin.rawValue,
            "tier": "\(f.decision.tier)",
            "state": state,
            "summary": f.action.outboundTexts.isEmpty ? summary : Self.domains(f.action),
        ]
        if let undoID { line["undo"] = undoID }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// "받는 곳: example.com, naver.com" (KakaoTalk has none). Addresses stay out, like the reviewer input.
    static func domains(_ a: AgentAction) -> String {
        var seen: [String] = []
        for r in a.recipients {
            let d = r.address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
            if !d.isEmpty, !seen.contains(d) { seen.append(d) }
        }
        return seen.isEmpty ? "" : "to: " + seen.joined(separator: ", ")
    }
}

/// The approval queue, persisted as `pending.json`. Only Executor (same file) moves a card past `approved`.
@MainActor
final class PendingStore: ObservableObject {
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Agent", isDirectory: true)
    }
    static let undoWindow: TimeInterval = 10 * 60
    /// Finished cards stay on disk this long (the 행동 기록 list reads actions.jsonl for older ones).
    static let keepFinished: TimeInterval = 24 * 3600

    let root: URL
    let audit: AuditLog
    @Published private(set) var actions: [FrozenAction] = []
    private var file: URL { root.appendingPathComponent("pending.json") }

    init(root: URL = PendingStore.defaultRoot) {
        self.root = root
        self.audit = AuditLog(url: root.appendingPathComponent("actions.jsonl"))
        load()
    }

    @discardableResult
    func add(_ action: AgentAction, origin: Origin, decision: Decision, concerns: [Concern] = [],
             reviewer: String? = nil, now: Date = Date()) -> FrozenAction {
        let f = FrozenAction(action: action, origin: origin, decision: decision, concerns: concerns.map(\.message),
                             reviewer: reviewer, createdAt: now)
        actions.append(f)
        save(now: now)
        audit.append(f, state: "proposed", summary: decision.reasons.joined(separator: "; "), now: now)
        return f
    }

    func get(_ id: UUID) -> FrozenAction? { actions.first { $0.id == id } }

    /// Cards still waiting for the owner.
    func pending(now: Date = Date()) -> [FrozenAction] {
        actions.filter { $0.state == .proposed && now < $0.expiresAt }
    }

    func cancel(_ id: UUID, now: Date = Date()) {
        guard let f = get(id), !f.state.isFinished, f.state != .running else { return }
        set(id, .cancelled, now: now)
    }

    func expireSweep(now: Date = Date()) {
        for f in actions where f.state == .proposed && now >= f.expiresAt { set(f.id, .expired, now: now) }
    }

    /// [고치기]: the caller re-ran the guard (and the reviewer if outbound fields changed) on `action`. The old card is
    /// cancelled and a new one with a new id, hash and expiry takes its place. nil when the old one is not proposed.
    func edit(_ id: UUID, to action: AgentAction, decision: Decision, concerns: [Concern] = [],
              reviewer: String? = nil, now: Date = Date()) -> FrozenAction? {
        guard let old = get(id), old.state == .proposed else { return nil }
        set(id, .cancelled, now: now)
        return add(action, origin: old.origin, decision: decision, concerns: concerns, reviewer: reviewer, now: now)
    }

    /// The owner's tap. nil when the card is gone, expired, already answered, or no longer hashes to what was frozen.
    func approve(_ id: UUID, now: Date = Date()) -> ApprovalToken? {
        guard let f = get(id), f.state == .proposed else { return nil }
        if now >= f.expiresAt {
            set(id, .expired, now: now)
            return nil
        }
        guard FrozenAction.hash(f.action) == f.sha256 else {
            set(id, .failed(reason: L("카드 내용이 바뀌었어요. 다시 계획할게요")), now: now)
            return nil
        }
        set(id, .approved, now: now)
        return ApprovalToken(id: id, hash: f.sha256)
    }

    /// Done actions that can still be undone (EventKit ids are kept 10 minutes).
    func undoable(now: Date = Date()) -> [FrozenAction] {
        actions.filter {
            guard case .done(_, let undo?) = $0.state, !undo.isEmpty, let t = $0.finishedAt else { return false }
            return now.timeIntervalSince(t) < Self.undoWindow
        }
    }

    /// Every state change goes through here: saved, then audited.
    fileprivate func set(_ id: UUID, _ state: FrozenAction.State, now: Date) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[i].state = state
        if state.isFinished { actions[i].finishedAt = now }
        save(now: now)
        let summary: String, undo: String?
        switch state {
        case .done(let s, let u): (summary, undo) = (s, u)
        case .failed(let r), .unknown(let r): (summary, undo) = (r, nil)
        default: (summary, undo) = ("", nil)
        }
        audit.append(actions[i], state: state.label, summary: summary, undoID: undo, now: now)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              var list = try? Self.decoder().decode([FrozenAction].self, from: data) else { return }
        for i in list.indices {
            // Tokens live in memory only, so an approved card from the last run can never run: back to the owner.
            if list[i].state == .approved { list[i].state = .proposed }
            // The app quit mid-perform: whether it happened is not known, and it is never retried.
            if list[i].state == .running { list[i].state = .unknown(reason: L("실행 중에 앱이 꺼졌어요. 결과를 확인해 주세요")) }
        }
        actions = list
    }

    /// ponytail: rewrites the whole file per change; a few dozen cards a day, append-only log if that ever grows.
    private func save(now: Date) {
        actions.removeAll { $0.state.isFinished && now.timeIntervalSince($0.finishedAt ?? $0.createdAt) > Self.keepFinished }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? FrozenAction.canonical().encode(actions) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The only code that performs actions. Every path re-checks: token, hash, origin, tier, and the guard right now.
@MainActor
final class Executor: ObservableObject {
    static let mailCountdown: TimeInterval = 10

    let store: PendingStore
    private let delay: (TimeInterval) async throws -> Void
    private let now: () -> Date
    /// Mail cards inside their 10-second countdown, for the [취소] button.
    @Published private(set) var countingDown: Set<UUID> = []
    private var cancelRequested: Set<UUID> = []

    init(store: PendingStore,
         delay: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.delay = delay
        self.now = now
    }

    /// A tapped card. Refuses without a token for this exact id and hash, whatever the tier or origin.
    func run(_ id: UUID, token: ApprovalToken?, recheck: (AgentAction) -> [Concern],
             perform: (AgentAction, UUID) async throws -> PerformResult) async -> FrozenAction.State {
        guard let f = store.get(id) else { return .failed(reason: L("카드를 찾지 못했어요")) }
        guard let token, token.id == id, token.hash == f.sha256, f.state == .approved else {
            return refuse(f, L("확인 버튼으로만 실행할 수 있어요"))
        }
        return await execute(f, recheck: recheck, perform: perform)
    }

    /// Tier auto or preapproved from the chat, without a card tap. Never a `.background` action (dots: read-only while
    /// the owner may be away), never confirm or above.
    func runAuto(_ id: UUID, recheck: (AgentAction) -> [Concern],
                 perform: (AgentAction, UUID) async throws -> PerformResult) async -> FrozenAction.State {
        guard let f = store.get(id) else { return .failed(reason: L("카드를 찾지 못했어요")) }
        guard f.origin == .chat, f.decision.tier <= .preapproved, f.state == .proposed, now() < f.expiresAt else {
            return refuse(f, L("확인 버튼으로만 실행할 수 있어요"))
        }
        return await execute(f, recheck: recheck, perform: perform)
    }

    /// The owner's [취소] during the mail countdown (or on a card still waiting).
    func cancel(_ id: UUID) {
        if countingDown.contains(id) { cancelRequested.insert(id) }
        store.cancel(id, now: now())
    }

    /// A refusal for a missing or wrong token leaves the card as it was, so a stray call cannot void the owner's card.
    private func refuse(_ f: FrozenAction, _ reason: String) -> FrozenAction.State {
        store.audit.append(f, state: "refused", summary: reason, now: now())
        return .failed(reason: reason)
    }

    private func execute(_ f: FrozenAction, recheck: (AgentAction) -> [Concern],
                         perform: (AgentAction, UUID) async throws -> PerformResult) async -> FrozenAction.State {
        let id = f.id
        func finish(_ s: FrozenAction.State) -> FrozenAction.State {
            store.set(id, s, now: now())
            return s
        }
        guard FrozenAction.hash(f.action) == f.sha256 else { return finish(.failed(reason: L("카드 내용이 바뀌었어요. 다시 계획할게요"))) }
        guard f.decision.tier != .blocked else { return finish(.failed(reason: L("이 일은 하지 않아요"))) }
        // The guard again, right now: the date may have passed, a cap may be full, a rule may have changed.
        let blocking = recheck(f.action).filter(\.blocking)
        guard blocking.isEmpty else { return finish(.failed(reason: blocking.map(\.message).joined(separator: " "))) }

        if f.action.type.isOutbound {
            countingDown.insert(id)
            let slept: Bool
            do { try await delay(Self.mailCountdown); slept = true } catch { slept = false }
            countingDown.remove(id)
            let cancelled = cancelRequested.remove(id) != nil
            if cancelled || !slept {
                if store.get(id)?.state != .cancelled { store.set(id, .cancelled, now: now()) }
                return .cancelled
            }
            // Again after the countdown: a card tapped in the same 10 seconds may have filled today's cap (review 2026-10-06).
            let late = recheck(f.action).filter(\.blocking)
            guard late.isEmpty else { return finish(.failed(reason: late.map(\.message).joined(separator: " "))) }
        }

        store.set(id, .running, now: now())
        do {
            let r = try await perform(f.action, id)
            return finish(.done(summary: r.summary, undoID: r.undoID))
        } catch let e as MailUnknown {
            return finish(.unknown(reason: e.reason))
        } catch {
            return finish(.failed(reason: error.localizedDescription))
        }
    }
}
