import AppKit
import Foundation

// 비서가 행동하기, the hub: one chat turn becomes plan -> guard -> policy -> reviewer -> frozen card; the card's buttons
// approve, cancel, retype or undo; the Executor runs the frozen copy through `perform`, the only place an action touches
// mail, calendars, contacts or the web. Goals run here every minute and only ever leave cards. Design: docs/AGENT-DESIGN.md.

@MainActor
final class AgentCenter: ObservableObject {
    static let shared = AgentCenter()

    // MARK: Settings (AppDefaults "assistant.agent.*")

    private let d: UserDefaults
    /// 비서가 행동하기 on. Needs 내 AI 연결 and the consent sheet.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "assistant.agent.enabled") } }
    /// The consent sheet was accepted (App Review 5.1.2(i): which provider, what leaves the Mac).
    @Published var consented: Bool { didSet { d.set(consented, forKey: "assistant.agent.consent") } }
    /// The owner's tiers and structured rules (AgentPolicy clamps them to floors).
    @Published var policy: AgentPolicy.Settings { didSet { save(policy, "assistant.agent.policy") } }

    let pending: PendingStore
    let executor: Executor
    let goals: GoalStore
    let memory: OwnerMemory
    var native: NativeActing = NativeActions()
    private(set) lazy var runner = GoalRunner(store: goals, prices: Self.prices, planner: { [weak self] p, o in
        guard let self else { throw ChatError.other }
        return try await self.backgroundPlan(p, origin: o)
    }, propose: { [weak self] goal, action in
        await self?.proposeFromGoal(goal, action) ?? UUID()
    }, notify: { [weak self] in self?.alert($0) }, observe: { [weak self] goal in
        // ponytail: goals run one at a time, so the goal about to be planned is remembered here for provenance (its
        // owner's words, never the prompt, which carries received texts).
        self?.goalWords = goal.ownerWords
        return []
    })
    /// The owner's words of the goal being checked (see `observe` above).
    var goalWords = ""

    /// The owner's words behind each chat card, for the guard's re-check on approval (kept in memory: chat cards live 30
    /// minutes). ponytail: lost on relaunch, so an approval after a restart re-checks provenance strictly.
    private var words: [UUID: String] = [:]

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogMonitor/Agent", isDirectory: true)
    }

    init(defaults: UserDefaults = AppDefaults.store, root: URL = AgentCenter.root) {
        d = defaults
        enabled = defaults.bool(forKey: "assistant.agent.enabled")
        consented = defaults.bool(forKey: "assistant.agent.consent")
        policy = defaults.data(forKey: "assistant.agent.policy").flatMap { try? JSONDecoder().decode(AgentPolicy.Settings.self, from: $0) }
            ?? AgentPolicy.Settings()
        browserOn = defaults.object(forKey: "assistant.agent.browser") as? Bool ?? true
        pending = PendingStore(root: root)
        executor = Executor(store: pending)
        goals = GoalStore(root: root.appendingPathComponent("goals", isDirectory: true))
        memory = OwnerMemory(url: root.appendingPathComponent("profile.json"))
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    /// On, consented and an engine that can plan (the owner's own AI).
    var active: Bool { enabled && consented && BYOEngine.active(intent: nil) != nil }

    // MARK: Routing

    /// A request to do something rather than a question: the actions the template answers "I cannot", shopping, flights,
    /// price watching, "기억해", and mail or messages addressed to someone.
    nonisolated static func wantsAgent(_ question: String, intent: AssistantIntent) -> Bool {
        // Mac actions ("캐시 지워 줘", "앱 꺼 줘") keep their template and 클리너 buttons (review 2026-10-06).
        if intent == .action { return [.schedule, .send, .alarm].contains(AssistantIntent.actionKind(question)) }
        guard intent == .general || intent == .realtime || intent == .calc else { return false }
        let q = question.lowercased(), tight = q.filter { !$0.isWhitespace }
        func has(_ w: [String]) -> Bool { w.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) } }
        if has(["최저가", "쿠팡", "네이버쇼핑", "장바구니", "주문해", "사 줘", "사줘", "구매해", "가격 비교", "가격비교"]) { return true }
        if has(["항공권", "비행기표", "비행기 표", "항공편", "왕복", "편도", "예매해", "예약해"]) { return true }
        if has(["기억해", "기억 해"]) { return true }
        if has(["지켜봐", "지켜 봐", "감시해", "알려줘", "알려 줘"]) && has(["내려가면", "떨어지면", "이하로", "이하면", "아래로"])
            && has(["가격", "원", "만원", "할인", "특가", "최저가", "price"]) { return true }
        // "팀장님한테 메일 써 줘": addressed mail or messages (a bare "메일 쓰는 법" is not).
        if has(["메일", "문자", "카톡", "메시지"]) && has(["한테", "에게", "께 "]) && has(["보내", "써 줘", "써줘", "전해", "답장"]) { return true }
        return false
    }

    // MARK: One chat turn

    /// The messages for one request: what the character says and, when it proposes something, the card.
    /// nil: the planner could not run; the caller answers as a normal question instead.
    func handle(_ question: String, history: [ChatTurn], persona: Persona, engine: BYOEngine, now: Date = Date()) async -> [ChatMessage]? {
        wantsFollowUp = false
        if Self.loops(engine) { return await runTools(question, history: history, persona: persona, engine: engine, now: now) }
        // Memory (the owner's profile) only to engines allowed personal data: API keys and the claude CLI (codex and gemini
        // CLIs keep read-only tools; review 2026-10-06).
        let personal = !(engine.method == .cli && engine.provider != .claude)
        var context = personal ? memory.linesForAI : []
        if personal { context += mailAccountLines }
        let prompt = AgentPlanner.prompt(ownerWords: question, history: history, now: now, context: context)
        let json: [String: Any]
        do {
            json = try await engine.plan(system: AgentPlanner.system(persona: persona), prompt: prompt)
        } catch {
            return nil
        }
        if Self.namesWithoutAddress(json) { _ = await ContactsFinder.requestIfNeeded() }
        let plan = await Task.detached {
            AgentPlanner.parse(json, ownerWords: question, lookup: { ContactsFinder.addresses($0, phones: false) },
                               phoneLookup: { ContactsFinder.addresses($0, phones: true).filter(AgentGuard.isPhone) }, now: now)
        }.value
        var say = ChatMessage(role: .character, text: plan.say.isEmpty ? L("이렇게 할게요. 확인해 주세요.") : plan.say)
        say.suggestions = plan.ask
        wantsFollowUp = plan.action == nil
        if !plan.contactChoices.isEmpty {
            // Resolved here on a tap; the chosen address never goes back to the model.
            pendingChoice = (json, question, plan.contactChoices.compactMap { Self.address(in: $0) })
            say.contactChoices = plan.contactChoices
        }
        guard let action = plan.action else { return [say] }
        let card = await freeze(action, origin: .chat, ownerWords: question, engine: engine, now: now)
        words[card.id] = question
        say.proposal = card.id
        // The reviewer's escalations are already in the tier (apply never lowers it).
        if card.decision.tier <= .preapproved {
            _ = await executor.runAuto(card.id, recheck: { [weak self] in self?.recheck($0, card.id) ?? [] }, perform: perform)
        }
        return [say]
    }

    /// The last namesake question: the plan, the owner's words and the candidate addresses (from Contacts).
    var pendingChoice: (json: [String: Any], words: String, addresses: [String])?

    /// A namesake chip tapped: the same plan, with Contacts narrowed to the one chosen. Local only.
    func choose(_ index: Int) async -> [ChatMessage] {
        guard let c = pendingChoice, c.addresses.indices.contains(index), let engine = BYOEngine.active(intent: nil) else { return [] }
        pendingChoice = nil
        let picked = c.addresses[index]
        let plan = AgentPlanner.parse(c.json, ownerWords: c.words, lookup: { _ in [picked] }, phoneLookup: { _ in [picked] })
        guard let action = plan.action else { return [ChatMessage(role: .notice, text: L("다시 부탁해 주세요."))] }
        let card = await freeze(action, origin: .chat, ownerWords: c.words, engine: engine, now: Date())
        words[card.id] = c.words
        var m = ChatMessage(role: .character, text: L("이렇게 할게요. 확인해 주세요."))
        m.proposal = card.id
        return [m]
    }

    nonisolated static func address(in chip: String) -> String? {
        guard let a = chip.firstIndex(of: "<"), let b = chip.lastIndex(of: ">"), a < b else { return nil }
        return String(chip[chip.index(after: a)..<b])
    }

    /// Accounts the app can send from: SMTP ones, and iCloud through Mail.app in the direct build.
    static func canSend(_ a: MailAccount) -> Bool {
        guard a.on else { return false }
        if MailSender.smtpEndpoint(for: a.preset) != nil { return true }
        #if MAS
        return false
        #else
        return a.preset == .icloud
        #endif
    }

    /// The owner's sending accounts, so "회사 메일로" can pick one (own addresses, personal-allowed engines only).
    var mailAccountLines: [String] {
        let list = MailAccounts.shared.accounts.filter(Self.canSend)
        guard list.count > 1 else { return [] }
        return [L("보낼 수 있는 메일 계정 (account에 이 값을 써): ") + list.map { "\($0.id) = \(MailSender.address(of: $0))" }.joined(separator: ", ")]
    }

    /// Mail is frozen with its sending account (shown on the card, covered by the hash): the one named, else the first
    /// that can send. nil = none can (iCloud only): the compose sheet.
    func withAccount(_ action: AgentAction) -> AgentAction {
        guard var m = Self.mail(action) else { return action }
        let sendable = MailAccounts.shared.accounts.filter(Self.canSend)
        m.accountID = sendable.first { $0.id == m.accountID }?.id ?? sendable.first?.id
        if case .mailReply(_, let r) = action { return .mailReply(m, inReplyTo: r) }
        return .mailSend(m)
    }

    /// Guard, policy, reviewer (when needed), then a frozen card in the store.
    private func freeze(_ action: AgentAction, origin: Origin, ownerWords: String, engine: BYOEngine?, goal: String? = nil,
                        now: Date) async -> FrozenAction {
        let action = withAccount(action)
        let concerns = guardCheck(action, origin: origin, ownerWords: ownerWords, proposedAt: now, now: now)
        var decision = AgentPolicy.decide(action, origin: origin, settings: policy, ownerAddresses: ownerAddresses,
                                          ruleUsesToday: ruleUses(now), concerns: concerns, now: now, inAgentList: Self.inAgentList(action))
        var line: String?
        if decision.needsReview, decision.tier != .blocked, let engine {
            let verdict = await ActionReviewer.review(engine: engine, ownerWords: ownerWords, action: action, origin: origin, goal: goal)
            let applied = ActionReviewer.apply(verdict, to: decision)
            decision = applied.decision
            line = applied.line ?? verdict.map { _ in L("내용이 부탁과 맞아요") }
            if applied.doubleConfirm { decision.reasons.append(ActionCopy.reviewerBlockMark) }
        }
        return pending.add(action, origin: origin, decision: decision, concerns: concerns, reviewer: line, now: now)
    }

    /// reminder_done's reminder is in the "AI 비서" list, the only one a rule may tick (looked up for that type only).
    private static func inAgentList(_ action: AgentAction) -> Bool {
        guard case .reminderDone(let id, _) = action else { return false }
        return AgentCalendar.inAgentList(id)
    }

    /// The JSON has a recipient name with no address, so Contacts will be asked (the lazy permission prompt).
    static func namesWithoutAddress(_ json: [String: Any]) -> Bool {
        guard let a = json["action"] as? [String: Any] else { return false }
        return ((a["to"] as? [[String: Any]] ?? []) + (a["cc"] as? [[String: Any]] ?? [])).contains {
            ($0["address"] as? String ?? "").isEmpty && !($0["name"] as? String ?? "").isEmpty
        }
    }

    // MARK: Card buttons

    /// [보내기]/[만들기]: the only caller of PendingStore.approve.
    func approve(_ id: UUID) async {
        guard let token = pending.approve(id) else { return }
        let words = self.words[id] ?? ""
        _ = await executor.run(id, token: token, recheck: { [weak self] in self?.recheck($0, id, words: words) ?? [] }, perform: perform)
        goals.cardResolved(id)
    }

    func cancel(_ id: UUID) {
        executor.cancel(id)
        goals.cardResolved(id)
    }

    /// The owner typed an untrusted address themselves: a new card with that recipient as their own words.
    func retype(_ id: UUID, index: Int, address: String) async {
        guard let f = pending.get(id) else { return }
        let clean = address.trimmingCharacters(in: .whitespaces).lowercased()
        let ownerWords = (words[id] ?? "") + " " + clean
        let action: AgentAction
        if case .messagePrepare(var to, let body) = f.action {
            guard to.indices.contains(index), AgentGuard.isPhone(clean) || AgentGuard.isEmail(clean) else { return }
            to[index] = Recipient(name: to[index].name, address: clean, provenance: .ownerWords)
            action = .messagePrepare(to: to, body: body)
        } else {
            guard var draft = Self.mail(f.action) else { return }
            var all = draft.to + draft.cc
            guard all.indices.contains(index), AgentGuard.isEmail(clean) else { return }
            all[index] = Recipient(name: all[index].name, address: clean, provenance: .ownerWords)
            draft.to = Array(all.prefix(draft.to.count))
            draft.cc = Array(all.dropFirst(draft.to.count))
            if case .mailReply(_, let original) = f.action { action = .mailReply(draft, inReplyTo: original) } else { action = .mailSend(draft) }
        }
        let engine = BYOEngine.active(intent: nil)
        let fresh = await freeze(action, origin: f.origin, ownerWords: ownerWords, engine: engine, now: Date())
        pending.cancel(id)
        words[fresh.id] = ownerWords
        cardReceived[fresh.id] = cardReceived[id]
        replacedBy[id] = fresh.id
        AssistantModel.shared.replaceProposal(id, with: fresh.id)
    }

    func undo(_ id: UUID) async {
        guard let f = pending.get(id), case .done(_, let undoID?) = f.state else { return }
        do {
            try await native.undo(undoID)
            pending.audit.append(f, state: "undone", summary: L("되돌렸어요"), now: Date())
            AssistantModel.shared.messages.append(ChatMessage(role: .notice, text: L("되돌렸어요.")))
        } catch {
            AssistantModel.shared.messages.append(ChatMessage(role: .notice, text: L("되돌리지 못했어요: \(error.localizedDescription)")))
        }
    }

    static func mail(_ a: AgentAction) -> MailDraft? {
        switch a {
        case .mailSend(let m), .mailReply(let m, _): return m
        default: return nil
        }
    }

    // MARK: Checks

    private func recheck(_ action: AgentAction, _ id: UUID, words: String? = nil) -> [Concern] {
        let f = pending.get(id)
        return guardCheck(action, origin: f?.origin ?? .chat, ownerWords: words ?? self.words[id] ?? "", proposedAt: f?.createdAt ?? Date(),
                          now: Date(), excluding: id)
    }

    private func guardCheck(_ action: AgentAction, origin: Origin, ownerWords: String, proposedAt: Date, now: Date, excluding: UUID? = nil) -> [Concern] {
        // Received texts stay on this Mac (the guard runs here): one pasted into a mail is blocked from going out. Plus
        // the mail and messages a tool run read for this card.
        let received = InboxCenter.memory().compactMap(\.preview) + (excluding.flatMap { cardReceived[$0] } ?? runReceived)
        return AgentGuard.check(action, origin: origin, proposedAt: proposedAt, now: now, ownerWords: ownerWords,
                                todayCounts: counts(now, excluding: excluding), receivedTexts: received, knownAirport: Airports.isKnown)
    }

    /// The owner's own addresses (mail to self may be preapproved).
    var ownerAddresses: Set<String> { Set(MailAccounts.shared.accounts.map { MailSender.address(of: $0).lowercased() }) }

    /// Today's finished writes, from actions.jsonl (the guard's daily caps).
    /// Plus cards already tapped and sending (another card in its countdown counts; the one being checked does not).
    func counts(_ now: Date, excluding: UUID? = nil) -> AgentGuard.Counts {
        var c = AgentGuard.Counts()
        for f in pending.actions where f.id != excluding && (f.state == .approved || f.state == .running) {
            switch f.action.type {
            case .mailSend, .mailReply, .messageSend: c.mails += 1
            case .eventAdd, .reminderAdd, .reminderDone: c.eventsAndReminders += 1
            default: break
            }
        }
        c.activeGoals = goals.list().filter { if case .done = $0.state { return false }; return true }.count
        guard let text = try? String(contentsOf: pending.audit.url, encoding: .utf8) else { return c }
        let today = Goals.day(now)
        let iso = ISO8601DateFormatter()
        for line in text.split(separator: "\n") {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String], j["state"] == "done",
                  let t = j["time"].flatMap(iso.date), Goals.day(t) == today, let type = j["type"].flatMap(AgentActionType.init) else { continue }
            switch type {
            case .mailSend, .mailReply, .messageSend: c.mails += 1
            case .eventAdd, .reminderAdd, .reminderDone: c.eventsAndReminders += 1
            default: break
            }
        }
        return c
    }

    /// Preapproved runs per rule today (kept by day; the rule cap).
    private func ruleUses(_ now: Date) -> [UUID: Int] {
        guard d.string(forKey: "assistant.agent.ruleDay") == Goals.day(now),
              let data = d.data(forKey: "assistant.agent.ruleUses"),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    private func countRule(_ action: AgentAction, now: Date) {
        guard let rule = AgentPolicy.matchingRule(action, rules: policy.rules, ruleUsesToday: ruleUses(now), now: now) else { return }
        var uses = ruleUses(now)
        uses[rule.id, default: 0] += 1
        d.set(Goals.day(now), forKey: "assistant.agent.ruleDay")
        save(Dictionary(uniqueKeysWithValues: uses.map { ($0.key.uuidString, $0.value) }), "assistant.agent.ruleUses")
    }

    // MARK: Perform (the only place actions touch the world)

    lazy var perform: (AgentAction, UUID) async throws -> PerformResult = { [weak self] action, id in
        guard let self else { throw ChatError.other }
        defer { if self.pending.get(id)?.decision.tier == .preapproved { self.countRule(action, now: Date()) } }
        switch action {
        case .mailSend(let m), .mailReply(let m, _):
            return try await self.sendMail(m, id: id, inReplyTo: { if case .mailReply(_, let r) = action { return r }; return nil }())
        case .eventAdd, .reminderAdd, .reminderDone, .messagePrepare, .kakaoPrepare:
            // Run by a rule without a card (or a card that is gone): only the "AI 비서" calendar and list.
            let agentOnly = (self.pending.get(id)?.decision.tier).map { $0 <= .preapproved } ?? true
            let r = try await self.native.perform(action, id: id, agentOnly: agentOnly)
            return PerformResult(summary: r.summary, undoID: r.undoID)
        case .shopSearch(let q, _):
            return PerformResult(summary: await Self.shopSummary(q), undoID: nil)
        case .flightSearch:
            return PerformResult(summary: L("아래 버튼으로 바로 찾아볼 수 있어요"), undoID: nil)
        case .goalCreate(let g):
            let ok = self.goals.add(Goal(title: g.title, ownerWords: self.words[id] ?? "", kind: g.kind, everyMinutes: g.everyMinutes))
            if !ok { throw AgentFailure(L("맡긴 일은 10개까지예요. 끝난 일을 지우고 다시 부탁해 주세요.")) }
            return PerformResult(summary: L("맡겼어요. '맡긴 일'에서 볼 수 있어요"), undoID: nil)
        case .memoryAdd(let k, let v):
            _ = self.memory.add(key: k, value: v)
            return PerformResult(summary: L("기억했어요. 비서 설정에서 고치거나 지울 수 있어요"), undoID: nil)
        case .undo(let target):
            guard let uuid = UUID(uuidString: target), let f = self.pending.get(uuid), case .done(_, let u?) = f.state else {
                throw AgentFailure(L("되돌릴 일을 찾지 못했어요"))
            }
            try await self.native.undo(u)
            return PerformResult(summary: L("되돌렸어요"), undoID: nil)
        case .messageSend(let to, let body):
            return try await self.performMessage(to: to, body: body)
        case .webStep(let w):
            return try await self.performWeb(w)
        }
    }

    private func sendMail(_ m: MailDraft, id: UUID, inReplyTo: String?) async throws -> PerformResult {
        // The account frozen on the card, or none at all (then the compose sheet). Never another one silently.
        guard let accountID = m.accountID else {
            try await native.prepareMail(m)   // iCloud only or no account: the owner presses send
            return PerformResult(summary: L("메일 쓰기 창을 열었어요. 보내기는 직접 눌러 주세요"), undoID: nil)
        }
        guard let account = MailAccounts.shared.accounts.first(where: { $0.id == accountID && $0.on }) else {
            throw AgentFailure(L("카드에 적힌 보내는 계정이 꺼져 있거나 없어요. 다시 부탁해 주세요."))
        }
        #if !MAS
        if account.preset == .icloud, inReplyTo == nil {   // no SMTP here: Mail.app sends it from that account
            let to = m.to.map { $0.name ?? $0.address }.joined(separator: ", ")
            do {
                try MailAppSender.send(draft: m, from: MailSender.address(of: account))
                return PerformResult(summary: L("\(to)에게 Mail 앱으로 보냈어요"), undoID: nil)
            } catch NativeSendError.notAllowed {
                try await native.prepareMail(m)
                return PerformResult(summary: L("Mail 자동 보내기가 꺼져 있어서 쓰기 창을 열었어요. 보내기는 직접 눌러 주세요"), undoID: nil)
            } catch NativeSendError.failed(let why) {
                throw AgentFailure(L("Mail 앱이 보내지 못했어요: \(why)"))
            }
        }
        #endif
        if MailSender.smtpEndpoint(for: account.preset) == nil {
            // iCloud replies (Mail.app cannot thread them from here) and the App Store build: the owner sends it.
            try await native.prepareMail(m)
            return PerformResult(summary: L("메일 쓰기 창을 열었어요. 보내기는 직접 눌러 주세요"), undoID: nil)
        }
        let password = await Task.detached { MailKeychain.load(for: account) }.value
        guard let password else { throw AgentFailure(L("이 메일 계정의 앱 비밀번호가 없어요. 비서 설정 > 메일에서 다시 넣어 주세요.")) }
        let result = await MailSender().send(draft: m, from: account, password: password, messageID: id, inReplyTo: inReplyTo, now: Date(),
                                             fromName: memory.entries.first { $0.key == "이름" }?.value)
        switch result {
        case .sent:
            let to = m.to.map { $0.name ?? $0.address }.joined(separator: ", ")
            return PerformResult(summary: L("\(to)에게 보냈어요"), undoID: nil)
        case .failed(let why, _):
            // Not sent (the server said so before DATA): hand it to the mail app with the reason.
            try? await native.prepareMail(m)
            throw AgentFailure(L("보내지 못해서 메일 쓰기 창으로 넘겼어요: \(why)"))
        case .unknown(let why):
            throw MailUnknown(reason: why)
        }
    }

    /// The owner's Naver key, if any: the five lowest with price and mall; else the links on the card are the result.
    static func shopSummary(_ q: String) async -> String {
        guard NaverShopKeychain.exists() else { return L("네이버쇼핑과 쿠팡에서 바로 볼 수 있어요") }
        do {
            let items = try await NaverShopClient().lowest(q)
            guard !items.isEmpty else { return L("찾은 상품이 없어요") }
            return items.prefix(3).enumerated().map { i, it in "\(i + 1). \(it.title) \(Fmt.won(it.price)) (\(it.mall))" }.joined(separator: "\n")
        } catch {
            return (error as? NaverShopError)?.message ?? L("가격을 불러오지 못했어요. 아래 링크로 볼 수 있어요")
        }
    }

    // MARK: v2 runs (tool loop): cards made mid-run, progress, 멈추기

    /// "젤리가 쿠팡을 보는 중" while a tool run works; nil otherwise.
    @Published private(set) var progress: String?
    /// The agent browser may be used (direct build; 비서 설정 switch).
    @Published var browserOn: Bool { didSet { d.set(browserOn, forKey: "assistant.agent.browser") } }
    var runCancel: (() -> Void)?
    private(set) var runCancelled = false
    /// Namesakes an `act` call met in this run, shown as local chips on the run's last message.
    var runChoices: [String] = []

    func beginRun() { runCancelled = false; runChoices = []; runCalls = 0; runReceived = []; progress = L("생각하는 중") }
    /// Tool calls in the current run (0 = it failed before doing anything).
    var runCalls = 0
    /// The last agent turn asked something: the owner's next message goes back to the agent.
    var wantsFollowUp = false
    /// Cards announced on the phone, ones snoozed with 나중에, and the ntfy cursor for replies.
    var pushedCards = Set<UUID>()
    var laterCards: [UUID: Date] = [:]
    var phoneSince: String? {
        get { d.string(forKey: "assistant.phone.replySince") }
        set { d.set(newValue, forKey: "assistant.phone.replySince") }
    }
    func endRun() { progress = nil; runCancel = nil }

    /// [멈추기]: the loop stops before its next call; a card it waits on is left for the owner.
    func stopRun() {
        runCancelled = true
        runCancel?()
        progress = L("멈추는 중")
    }

    func note(_ e: LoopEvent) {
        switch e {
        case .thinking: progress = L("생각하는 중")
        case .say: break
        case .tool(let name, let note):
            runCalls += 1
            progress = Self.progressLine(name, note)
            chatBrowser?.show(status: progress ?? "")
        }
    }

    static func progressLine(_ tool: String, _ note: String) -> String {
        let n = note.isEmpty ? "" : " " + note
        switch tool {
        case "web_open": return L("\(n.isEmpty ? "사이트" : n.trimmingCharacters(in: .whitespaces)) 여는 중")
        case "web_snapshot", "web_find", "web_scroll", "web_back": return L("페이지 보는 중")
        case "web_click": return L("누르는 중")
        case "web_type", "web_select": return L("입력하는 중")
        case "calendar_list", "reminders_list": return L("일정 보는 중")
        case "mail_search", "mail_read", "inbox_recent": return L("메일·메시지 보는 중")
        case "contacts_find": return L("연락처 찾는 중")
        case "act": return L("카드 만드는 중")
        default: return L("일하는 중")
        }
    }

    /// One action from a tool run: frozen like a chat proposal, run at once when its tier allows, else shown as a card in
    /// the chat and waited on (polling the store) for up to `wait` seconds.
    func submit(_ action: AgentAction, origin: Origin, ownerWords: String, wait: TimeInterval) async -> FrozenAction.State {
        let card = await freeze(action, origin: origin, ownerWords: ownerWords, engine: BYOEngine.active(intent: nil), now: Date())
        words[card.id] = ownerWords
        cardReceived[card.id] = runReceived
        var m = ChatMessage(role: .character, text: origin == .background ? L("자리를 비운 사이라 카드로 남겨요.") : L("이건 확인받을게요."))
        m.proposal = card.id
        if origin == .chat, card.decision.tier <= .preapproved {
            let s = await executor.runAuto(card.id, recheck: { [weak self] in self?.recheck($0, card.id) ?? [] }, perform: perform)
            if case .done = s { m.text = L("바로 했어요.") } else { m.text = AgentToolHost.describe(s) }
            AssistantModel.shared.messages.append(m)
            return s
        }
        AssistantModel.shared.messages.append(m)
        // A blocked card has no buttons: nothing to wait for.
        if card.decision.tier == .blocked { return .failed(reason: card.decision.reasons.joined(separator: " ")) }
        if origin == .background { pushCard(card) }
        let deadline = Date().addingTimeInterval(wait)
        var id = card.id
        while Date() < deadline, !runCancelled {
            if let next = replacedBy[id] { id = next; continue }   // the owner retyped a recipient: wait on the new card
            if let s = pending.get(id)?.state, s.isFinished { return s }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return pending.get(id)?.state ?? .expired
    }

    /// Old card -> the one a retype made (submit follows it).
    var replacedBy: [UUID: UUID] = [:]
    /// Mail and message texts the current run read, and per card the ones its run had read (the forwarding guard).
    var runReceived: [String] = []
    var cardReceived: [UUID: [String]] = [:]

    /// [브라우저 보기]: the window the agent works in.
    func revealBrowser() { chatBrowser?.reveal() }

    /// How a run ended, as chat messages.
    func messages(for stop: LoopStop) -> [ChatMessage] {
        var m: ChatMessage
        switch stop {
        case .finished(let say): m = ChatMessage(role: .character, text: say.isEmpty ? L("다 했어요.") : AssistantPrompt.undash(say))
        case .asked(let q, let choices):
            m = ChatMessage(role: .character, text: AssistantPrompt.undash(q))
            m.suggestions = choices
        case .handedOff(let reason): m = ChatMessage(role: .character, text: L("여기부터는 직접 해 주세요. \(AssistantPrompt.undash(reason))"))
        case .cancelled: m = ChatMessage(role: .notice, text: L("멈췄어요."))
        case .failed(let why): m = ChatMessage(role: .notice, text: why)
        case .budget: m = ChatMessage(role: .notice, text: L("일이 길어져서 여기서 멈췄어요. 이어서 하려면 다시 부탁해 주세요."))
        }
        if !runChoices.isEmpty { m.contactChoices = runChoices }
        return [m]
    }

    // MARK: Goals

    /// Every minute (AssistantCenter) and on wake: expire old cards, run one due goal.
    func tick(_ now: Date = Date()) {
        pending.expireSweep(now: now)
        // A goal waits on its card; once the card is finished or gone (expired, relaunched, retyped), it runs again.
        for g in goals.list() {
            if case .waiting(let card) = g.state, pending.get(card)?.state.isFinished ?? true { goals.cardResolved(card) }
        }
        guard active else { return }
        Task {
            _ = await runner.tick(now)
            await pollPhone(now: now)
        }
    }

    static let prices: GoalRunner.PriceSource = { q in
        try await NaverShopClient().lowest(q).map { GoalRunner.PriceItem(title: $0.title, price: $0.price, mall: $0.mall, url: $0.link) }
    }

    private func backgroundPlan(_ prompt: String, origin: Origin) async throws -> AgentPlan {
        guard let engine = BYOEngine.active(intent: nil) else { throw ChatError.unavailable(L("내 AI 연결이 꺼져 있어요")) }
        if Self.loops(engine) { return try await goalRun(prompt, engine: engine) }
        let json = try await engine.plan(system: AgentPlanner.system(persona: AssistantModel.persona()), prompt: prompt)
        // Provenance from the goal's own words, never the prompt (it carries received texts).
        return AgentPlanner.parse(json, ownerWords: goalWords)
    }

    /// A goal's proposal: a card that waits for the owner (never run here, dots: read-only while away).
    /// The same freeze as chat (guard, policy, reviewer for outbound), with origin background: a card that waits.
    private func proposeFromGoal(_ goal: Goal, _ action: AgentAction) async -> UUID {
        let card = await freeze(action, origin: .background, ownerWords: goal.ownerWords, engine: BYOEngine.active(intent: nil),
                                goal: goal.title, now: Date())
        words[card.id] = goal.ownerWords
        var m = ChatMessage(role: .character, text: L("자리를 비운 사이 '\(goal.title)' 하다가 확인할 일이 생겼어요."))
        m.proposal = card.id
        AssistantModel.shared.messages.append(m)
        if Absence.away { pushCard(card) }
        return card.id
    }

    private func alert(_ a: GoalRunner.Alert) {
        _ = SpeechBubbleCenter.shared.say(text: a.text, source: .assistant, hold: true, closable: true)   // the owner's own goal: not covered by a nudge
        guard a.kind != .paused, AssistantSettings.shared.phone else { return }
        // Content-free unless it is a price (design 10: mail and calendar text never goes to ntfy).
        let body = a.kind == .price ? a.text : L("확인할 일 1건이 있어요. 맥에서 열어 주세요.")
        Task { _ = await Phone.send(title: L("캐릭모니터"), body: body) }
    }
}

/// A short Korean reason the card shows when an action fails.
struct AgentFailure: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
