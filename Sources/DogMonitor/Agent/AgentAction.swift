import Foundation

// 비서가 행동하기 (OpenAI dots-style, 2026-10): the owner's own AI plans, the app acts. The model only proposes one
// AgentAction per turn (closed set: an unknown type is a parse failure). The app runs AgentGuard (deterministic, cannot
// be turned off), AgentPolicy (the owner's tiers, with floors and hard blocks in code), an optional reviewer model that can
// only escalate, freezes the result (FrozenAction, sha256), shows it as a card, and on the owner's tap re-checks and runs
// the frozen copy itself. Background goals never execute: they only leave cards. Payment, transfers, passwords and
// 본인인증 are never automated. Design: scratchpad agent-plan.md (judge panel 2026-10-05).

/// What the agent may do in v1. Raw values are the model-facing names in the JSON schema.
enum AgentActionType: String, Codable, CaseIterable {
    case eventAdd = "event_add"
    case reminderAdd = "reminder_add"
    case reminderDone = "reminder_done"
    case mailSend = "mail_send"
    case mailReply = "mail_reply"
    case messagePrepare = "message_prepare"
    case kakaoPrepare = "kakao_prepare"
    case shopSearch = "shop_search"
    case flightSearch = "flight_search"
    case goalCreate = "goal_create"
    case memoryAdd = "memory_add"
    case undo = "undo"
    /// v2 (direct build): Messages sends it itself (AppleScript), after the card and the 10-second countdown.
    case messageSend = "message_send"
    /// v2 (direct build): one step in the agent browser that needs the owner (a state-changing click, a new site, typing
    /// the owner's details). Made by the tool host, never by the planner.
    case webStep = "web_step"

    /// Leaves the Mac as something sent in the owner's name (dots: reviewed by a second model, confirmed).
    var isOutbound: Bool { self == .mailSend || self == .mailReply || self == .messageSend }

    /// The v1 single-proposal planner may name these (web steps come only from the browser tools).
    var plannable: Bool { self != .webStep }
}

/// One browser step frozen on a card (design section 3, web_click/web_type). On approval the browser re-reads the element
/// and compares `signature` (text, href, form action, page URL): if the page changed, the card is void.
struct WebStep: Codable, Equatable {
    enum Kind: String, Codable { case open, click, type, select }
    var kind: Kind
    /// The page it happens on; for `.open`, the address to open.
    var pageURL: String
    /// What the owner reads: the button text, the field's label, or the site.
    var label: String
    /// The element ref from the snapshot (nil for `.open`).
    var ref: String?
    /// ElementSignature.make at proposal time (nil for `.open`).
    var signature: String?
    /// Text to type or the option to select, placeholders unresolved ("{{memory.이름}}"); the card shows the real value.
    var value: String?
    /// Why it needs the owner ("상태를 바꾸는 버튼", "처음 가는 사이트", "내 정보 입력").
    var why: String
    /// `.type`: press Enter after typing.
    var submit: Bool? = nil
}

/// Where a field's value came from. Only the first three may be sent to in one tap; anything the model took from a
/// mail body or a web page is `.untrusted` and must be retyped by the owner.
enum Provenance: String, Codable, Equatable {
    case ownerWords      // typed by the owner in this conversation
    case contact         // a contact found from a name the owner typed
    case pointedMail     // the From of the mail the owner pointed at
    case ownerProfile    // something the owner asked the app to remember
    case untrusted       // read from a mail body, a web page or a received text
}

struct Recipient: Codable, Equatable, Hashable {
    var name: String?
    var address: String
    var provenance: Provenance
}

struct EventDraft: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var notes: String?
    /// Every field came from the owner's words (an event taken from a mail stays confirm).
    var fromOwnerWords = true
}

struct ReminderDraft: Codable, Equatable {
    var title: String
    var due: Date?
    var notes: String?
    var fromOwnerWords = true
}

struct MailDraft: Codable, Equatable {
    /// MailAccount.id to send from; nil = the first account that can send.
    var accountID: String?
    var to: [Recipient]
    var cc: [Recipient] = []
    var subject: String
    var body: String
}

enum ShopStore: String, Codable, Equatable, CaseIterable { case naver, coupang }

struct FlightQuery: Codable, Equatable {
    var from: String          // IATA, e.g. "GMP"
    var to: String            // IATA, e.g. "CJU"
    var depart: Date          // the day (local midnight)
    var returnDate: Date?
    var adults: Int = 1
    var airline: String?      // e.g. "진에어"
}

enum GoalKind: Codable, Equatable {
    /// No model: Naver Shopping API lowest price, alert at or below `target` won (or a `dropPercent` fall).
    case priceWatch(query: String, target: Int?, dropPercent: Int?)
    /// The owner's AI, read-and-propose only, every run.
    case agent(prompt: String)
}

struct GoalDraft: Codable, Equatable {
    var title: String
    var kind: GoalKind
    /// Minutes between runs (at least 60).
    var everyMinutes: Int = 180
}

/// One proposal. Associated values keep each case's fields exact; the model never sees this encoding (AgentPlanner maps
/// its flat JSON to it).
enum AgentAction: Codable, Equatable {
    case eventAdd(EventDraft)
    case reminderAdd(ReminderDraft)
    case reminderDone(id: String, title: String)
    case mailSend(MailDraft)
    case mailReply(MailDraft, inReplyTo: String)
    case messagePrepare(to: [Recipient], body: String)
    case kakaoPrepare(body: String)
    case shopSearch(query: String, store: ShopStore?)
    case flightSearch(FlightQuery)
    case goalCreate(GoalDraft)
    case memoryAdd(key: String, value: String)
    case undo(actionID: String)
    case messageSend(to: [Recipient], body: String)
    case webStep(WebStep)

    var type: AgentActionType {
        switch self {
        case .eventAdd: return .eventAdd
        case .reminderAdd: return .reminderAdd
        case .reminderDone: return .reminderDone
        case .mailSend: return .mailSend
        case .mailReply: return .mailReply
        case .messagePrepare: return .messagePrepare
        case .kakaoPrepare: return .kakaoPrepare
        case .shopSearch: return .shopSearch
        case .flightSearch: return .flightSearch
        case .goalCreate: return .goalCreate
        case .memoryAdd: return .memoryAdd
        case .undo: return .undo
        case .messageSend: return .messageSend
        case .webStep: return .webStep
        }
    }

    /// Every recipient (mail and messages), for the provenance check.
    var recipients: [Recipient] {
        switch self {
        case .mailSend(let m), .mailReply(let m, _): return m.to + m.cc
        case .messagePrepare(let to, _), .messageSend(let to, _): return to
        default: return []
        }
    }

    /// Every text that would leave the Mac or be shown to someone else, for the secret-pattern check.
    var outboundTexts: [String] {
        switch self {
        // Recipient display names go out in the To/Cc headers too (review 2026-10-06: an OTP hidden in a "name").
        case .mailSend(let m), .mailReply(let m, _): return [m.subject, m.body] + (m.to + m.cc).compactMap(\.name)
        case .messagePrepare(let to, let body), .messageSend(let to, let body): return [body] + to.compactMap(\.name)
        case .kakaoPrepare(let body): return [body]
        // What the agent types into a site leaves the Mac too: an OTP or a card number never goes in by the agent.
        case .webStep(let w): return [w.value].compactMap { $0 }
        default: return []
        }
    }
}

/// What the model returns for one turn: something to say, an optional question with choices, at most one action.
struct AgentPlan: Equatable {
    var say: String
    var ask: [String] = []
    var action: AgentAction?
    /// Namesakes found in Contacts ("김부장 <kim@a.com>"): resolved by the app on a tap, never sent back to the model
    /// (review 2026-10-06: a chip sent as text put the contact's address in the AI prompt).
    var contactChoices: [String] = []
}

/// dots' four tiers plus the code-only block. Ordered from least to most owner involvement.
enum Tier: Int, Codable, Comparable, CaseIterable {
    case auto = 0          // do without asking
    case preapproved = 1   // do when a structured rule the owner made matches
    case confirm = 2       // a card, the owner taps
    case prepareOnly = 3   // the app prepares, the owner does it (compose sheet, links)
    case blocked = 4       // never (payment, transfers, passwords, secrets)

    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .auto: return L("바로 하기")
        case .preapproved: return L("규칙에 맞으면 바로")
        case .confirm: return L("매번 확인")
        case .prepareOnly: return L("준비만, 실행은 내가")
        case .blocked: return L("하지 않기")
        }
    }
}

/// Who started the work. `.background` (a goal running while the owner may be away) never executes anything.
enum Origin: String, Codable, Equatable { case chat, background }

/// A structured pre-approval (never free text): run `type` without a card when the target matches, up to `perDay`.
struct ToolRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var type: AgentActionType
    /// What it may touch: "agent-calendar", "agent-reminders", "self" (mail to the owner's own address).
    var target: String
    var perDay: Int = 10
    var expires: Date?
}

/// Something the deterministic guard found. `blocking` ones stop the action outright; the rest raise the tier to
/// confirm and show the message on the card.
struct Concern: Equatable {
    enum Kind: String, Equatable { case schema, provenance, secret, cap, expired, hardBlock }
    var kind: Kind
    var message: String
    var blocking: Bool
}

/// AgentPolicy's answer for one action.
struct Decision: Equatable {
    var tier: Tier
    /// The reviewer model must look before it may run (outbound, preapproved, untrusted fields, goals).
    var needsReview: Bool
    var reasons: [String] = []
}
