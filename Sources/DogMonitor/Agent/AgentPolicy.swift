import Foundation

/// The owner's tiers with floors in code (design section 3) and the reviewer rule (section 5). Pure: the guard's
/// concerns, today's rule uses and the owner's addresses come in as arguments, so the card and the approval tap agree.
enum AgentPolicy {
    /// The owner's choices from the 행동 규칙 table. Missing types use the default.
    struct Settings: Codable, Equatable {
        var tiers: [AgentActionType: Tier] = [:]
        var rules: [ToolRule] = []

        /// What the picker shows: the owner's choice, never below the floor, and the default for fixed types.
        /// Mail uses its self-only floor here so "규칙에 맞으면 바로" can be picked; decide() still holds every
        /// other mail at confirm.
        func tier(for type: AgentActionType) -> Tier {
            if AgentPolicy.isFixed(type) { return AgentPolicy.defaultTier(type) }
            return max(tiers[type] ?? AgentPolicy.defaultTier(type), AgentPolicy.floor(type, selfOnly: true))
        }
    }

    /// The v1 table's default column.
    static func defaultTier(_ type: AgentActionType) -> Tier {
        switch type {
        case .eventAdd, .reminderAdd, .reminderDone, .mailSend, .mailReply, .goalCreate, .messageSend, .webStep: return .confirm
        case .messagePrepare, .kakaoPrepare, .flightSearch: return .prepareOnly
        case .shopSearch, .memoryAdd, .undo: return .auto
        }
    }

    /// The lowest tier the owner may choose (shown greyed). Mail is confirm, except mail whose every recipient is one
    /// of the owner's own addresses, which may be preapproved (a "self" rule).
    static func floor(_ type: AgentActionType, selfOnly: Bool = false) -> Tier {
        switch type {
        case .eventAdd, .reminderAdd, .reminderDone: return .preapproved
        case .mailSend, .mailReply: return selfOnly ? .preapproved : .confirm
        case .goalCreate, .messageSend, .webStep: return .confirm
        case .messagePrepare, .kakaoPrepare, .flightSearch: return .prepareOnly
        case .shopSearch, .memoryAdd, .undo: return .auto
        }
    }

    /// The owner cannot change these at all (no API to send, or payment and passenger details are the owner's; a web
    /// step exists only because the browser tools decided it needs the owner).
    static func isFixed(_ type: AgentActionType) -> Bool {
        type == .messagePrepare || type == .kakaoPrepare || type == .flightSearch || type == .webStep
    }

    /// The only target each type's rule may name: the designated "AI 비서" calendar and list, or the owner's own mail.
    static func ruleTarget(_ type: AgentActionType) -> String? {
        switch type {
        case .eventAdd: return "agent-calendar"
        case .reminderAdd, .reminderDone: return "agent-reminders"
        case .mailSend, .mailReply: return "self"
        default: return nil
        }
    }

    /// Mail that only goes to the owner (To and Cc), compared case-insensitively.
    static func isSelfMail(_ action: AgentAction, ownerAddresses: Set<String>) -> Bool {
        let own = Set(ownerAddresses.map { $0.lowercased() })
        let to = action.recipients
        return action.type.isOutbound && !to.isEmpty && to.allSatisfy { own.contains($0.address.lowercased()) }
    }

    /// One action's tier. Order: a blocking concern wins outright; then the owner's tier clamped to the floor; a
    /// preapproved tier holds only when a rule matches (else confirm), and for reminder_done only when `inAgentList`
    /// (the caller looked the reminder up in the "AI 비서" list; unknown counts as outside); any other concern lifts to
    /// confirm; background work is never below confirm (a card, never executed).
    static func decide(_ action: AgentAction, origin: Origin, settings: Settings, ownerAddresses: Set<String>,
                       ruleUsesToday: [UUID: Int], concerns: [Concern], now: Date, inAgentList: Bool = false) -> Decision {
        let blocking = concerns.filter(\.blocking)
        if !blocking.isEmpty {
            // The reviewer can neither add nor lift a hard block, so it is not asked.
            return Decision(tier: .blocked, needsReview: false, reasons: blocking.map(\.message))
        }

        let type = action.type
        var reasons: [String] = []
        let selfMail = isSelfMail(action, ownerAddresses: ownerAddresses)
        var tier = isFixed(type) ? defaultTier(type)
            : max(settings.tiers[type] ?? defaultTier(type), floor(type, selfOnly: selfMail))

        if tier == .preapproved {
            if let why = ruleRefusal(action, rules: settings.rules, ruleUsesToday: ruleUsesToday, now: now) {
                tier = .confirm
                reasons.append(why)
            } else if type == .reminderDone && !inAgentList {
                // The rule names the "AI 비서" list: a reminder the model points at anywhere else is the owner's to tick.
                tier = .confirm
                reasons.append(L("AI 비서 목록 밖의 미리알림이라 확인받을게요"))
            }
        }

        let warnings = concerns.filter { !$0.blocking }
        if !warnings.isEmpty {
            tier = max(tier, .confirm)
            reasons += warnings.map(\.message)
        }

        if origin == .background && tier < .confirm {
            tier = .confirm
            reasons.append(L("자리를 비운 사이 찾은 일이라 카드로만 남겨요"))
        }

        let untrusted = action.recipients.contains { $0.provenance == .untrusted } || !fromOwnerWords(action)
        let review = type.isOutbound || type == .goalCreate || type == .webStep || tier == .preapproved || untrusted
        return Decision(tier: tier, needsReview: review, reasons: reasons)
    }

    /// nil when a rule lets this run without a card; otherwise why not, for the card.
    static func ruleRefusal(_ action: AgentAction, rules: [ToolRule], ruleUsesToday: [UUID: Int], now: Date) -> String? {
        let type = action.type
        guard let target = ruleTarget(type) else { return L("이 일은 규칙으로 바로 할 수 없어요") }
        if !fromOwnerWords(action) { return L("메일 등에서 가져온 내용이라 확인받을게요") }
        // Events and reminder adds have no calendar field: a preapproved run goes into the "AI 비서" calendar or list or
        // nowhere (AgentCalendar, agentOnly). reminder_done outside that list stays confirm (decide, inAgentList).
        let candidates = rules.filter { $0.type == type && $0.target == target }
        if candidates.isEmpty { return L("맞는 규칙이 없어서 확인받을게요") }
        let live = candidates.filter { $0.expires.map { now < $0 } ?? true }
        if live.isEmpty { return L("규칙 기한이 지나서 확인받을게요") }
        if !live.contains(where: { (ruleUsesToday[$0.id] ?? 0) < $0.perDay }) {
            return L("오늘 규칙으로 할 수 있는 만큼 다 해서 확인받을게요")
        }
        return nil
    }

    /// The rule a preapproved run is counted against in ruleUsesToday: the first live one with room left today.
    static func matchingRule(_ action: AgentAction, rules: [ToolRule], ruleUsesToday: [UUID: Int], now: Date) -> ToolRule? {
        guard ruleRefusal(action, rules: rules, ruleUsesToday: ruleUsesToday, now: now) == nil else { return nil }
        return rules.first {
            $0.type == action.type && $0.target == ruleTarget(action.type)
                && ($0.expires.map { now < $0 } ?? true) && (ruleUsesToday[$0.id] ?? 0) < $0.perDay
        }
    }

    /// Events and reminders the model took from a mail say so; everything else carries no such flag.
    static func fromOwnerWords(_ action: AgentAction) -> Bool {
        switch action {
        case .eventAdd(let e): return e.fromOwnerWords
        case .reminderAdd(let r): return r.fromOwnerWords
        default: return true
        }
    }
}
