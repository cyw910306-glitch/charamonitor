import XCTest
@testable import DogMonitor

/// AgentPolicy: the v1 tier table, floors, structured rules, concerns and the reviewer rule. Pure, no clock but `now`.
final class AgentPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let me: Set<String> = ["Me@Example.com", "me@naver.com"]
    private var hour: Date { now.addingTimeInterval(3600) }

    private func sample(_ type: AgentActionType, fromOwner: Bool = true, to: [Recipient]? = nil) -> AgentAction {
        let bob = [Recipient(name: "Bob", address: "bob@example.com", provenance: .contact)]
        switch type {
        case .eventAdd:
            return .eventAdd(EventDraft(title: "치과", start: hour, end: hour.addingTimeInterval(3600), fromOwnerWords: fromOwner))
        case .reminderAdd: return .reminderAdd(ReminderDraft(title: "우유", due: hour, fromOwnerWords: fromOwner))
        case .reminderDone: return .reminderDone(id: "r1", title: "우유")
        case .mailSend: return .mailSend(MailDraft(to: to ?? bob, subject: "회의", body: "10시로 미뤄요"))
        case .mailReply: return .mailReply(MailDraft(to: to ?? bob, subject: "Re: 회의", body: "네"), inReplyTo: "<m1>")
        case .messagePrepare: return .messagePrepare(to: to ?? bob, body: "곧 도착")
        case .kakaoPrepare: return .kakaoPrepare(body: "곧 도착")
        case .shopSearch: return .shopSearch(query: "하기스 4단계", store: .coupang)
        case .flightSearch: return .flightSearch(FlightQuery(from: "GMP", to: "CJU", depart: hour))
        case .goalCreate: return .goalCreate(GoalDraft(title: "기저귀", kind: .priceWatch(query: "하기스", target: 30000, dropPercent: nil)))
        case .memoryAdd: return .memoryAdd(key: "좌석", value: "창가")
        case .undo: return .undo(actionID: "a1")
        case .messageSend: return .messageSend(to: to ?? bob, body: "곧 도착")
        case .webStep: return .webStep(WebStep(kind: .click, pageURL: "https://www.coupang.com/vp/1", label: "장바구니 담기",
                                               ref: "e1", signature: "s", value: nil, why: "상태를 바꾸는 버튼"))
        }
    }

    private func decide(_ a: AgentAction, origin: Origin = .chat, settings: AgentPolicy.Settings = .init(),
                        uses: [UUID: Int] = [:], concerns: [Concern] = [], inAgentList: Bool = false) -> Decision {
        AgentPolicy.decide(a, origin: origin, settings: settings, ownerAddresses: me,
                           ruleUsesToday: uses, concerns: concerns, now: now, inAgentList: inAgentList)
    }

    private let selfAddr = [Recipient(name: nil, address: "me@example.com", provenance: .ownerProfile)]

    private func rules(_ pairs: [(AgentActionType, String)], perDay: Int = 10, expires: Date? = nil) -> AgentPolicy.Settings {
        var s = AgentPolicy.Settings()
        for (t, target) in pairs {
            s.tiers[t] = .preapproved
            s.rules.append(ToolRule(type: t, target: target, perDay: perDay, expires: expires))
        }
        return s
    }

    // MARK: Table

    func testDefaultsAndFloorsMatchTheV1Table() {
        let expected: [AgentActionType: (Tier, Tier)] = [
            .eventAdd: (.confirm, .preapproved), .reminderAdd: (.confirm, .preapproved),
            .reminderDone: (.confirm, .preapproved), .mailSend: (.confirm, .confirm), .mailReply: (.confirm, .confirm),
            .messagePrepare: (.prepareOnly, .prepareOnly), .kakaoPrepare: (.prepareOnly, .prepareOnly),
            .shopSearch: (.auto, .auto), .flightSearch: (.prepareOnly, .prepareOnly), .goalCreate: (.confirm, .confirm),
            .memoryAdd: (.auto, .auto), .undo: (.auto, .auto), .messageSend: (.confirm, .confirm), .webStep: (.confirm, .confirm),
        ]
        XCTAssertEqual(expected.count, AgentActionType.allCases.count)
        for t in AgentActionType.allCases {
            XCTAssertEqual(AgentPolicy.defaultTier(t), expected[t]?.0, "\(t)")
            XCTAssertEqual(AgentPolicy.floor(t), expected[t]?.1, "\(t)")
        }
        XCTAssertEqual(AgentPolicy.floor(.mailSend, selfOnly: true), .preapproved)
        XCTAssertEqual(AgentPolicy.floor(.goalCreate, selfOnly: true), .confirm)
    }

    /// Every type, both origins, default settings, no concerns.
    func testFullDefaultMatrix() {
        let chat: [AgentActionType: Tier] = [
            .eventAdd: .confirm, .reminderAdd: .confirm, .reminderDone: .confirm, .mailSend: .confirm, .mailReply: .confirm,
            .messagePrepare: .prepareOnly, .kakaoPrepare: .prepareOnly, .shopSearch: .auto, .flightSearch: .prepareOnly,
            .goalCreate: .confirm, .memoryAdd: .auto, .undo: .auto, .messageSend: .confirm, .webStep: .confirm,
        ]
        for t in AgentActionType.allCases {
            XCTAssertEqual(decide(sample(t)).tier, chat[t], "chat \(t)")
            let bg = decide(sample(t), origin: .background).tier
            XCTAssertEqual(bg, max(chat[t]!, .confirm), "background \(t)")
        }
    }

    func testNeedsReviewPerSection5() {
        let reviewed: Set<AgentActionType> = [.mailSend, .mailReply, .goalCreate, .messageSend, .webStep]
        for t in AgentActionType.allCases {
            XCTAssertEqual(decide(sample(t)).needsReview, reviewed.contains(t), "\(t)")
        }
        // A preapproved run is reviewed; an untrusted field is reviewed even at confirm.
        let pre = decide(sample(.eventAdd), settings: rules([(.eventAdd, "agent-calendar")]))
        XCTAssertEqual(pre.tier, .preapproved)
        XCTAssertTrue(pre.needsReview)
        XCTAssertTrue(decide(sample(.eventAdd, fromOwner: false)).needsReview)
        let shady = [Recipient(name: nil, address: "x@evil.com", provenance: .untrusted)]
        XCTAssertTrue(decide(sample(.messagePrepare, to: shady)).needsReview)
    }

    // MARK: Floors

    func testFloorsCannotBeLowered() {
        var s = AgentPolicy.Settings()
        for t in AgentActionType.allCases { s.tiers[t] = .auto }
        for t in AgentActionType.allCases {
            XCTAssertGreaterThanOrEqual(s.tier(for: t), AgentPolicy.floor(t, selfOnly: true), "\(t)")
            XCTAssertGreaterThanOrEqual(decide(sample(t), settings: s).tier, AgentPolicy.floor(t), "\(t)")
        }
        // Mail set to preapproved with a self rule still stays confirm for anyone else.
        let mail = rules([(.mailSend, "self")])
        XCTAssertEqual(decide(sample(.mailSend), settings: mail).tier, .confirm)
        XCTAssertEqual(decide(sample(.goalCreate), settings: s).tier, .confirm)
    }

    func testFixedTypesIgnoreTheOwnersChoice() {
        var s = AgentPolicy.Settings()
        for t in [AgentActionType.messagePrepare, .kakaoPrepare, .flightSearch] {
            s.tiers[t] = .auto
            XCTAssertEqual(s.tier(for: t), .prepareOnly)
            XCTAssertEqual(decide(sample(t), settings: s).tier, .prepareOnly)
            s.tiers[t] = .confirm
            XCTAssertEqual(decide(sample(t), settings: s).tier, .prepareOnly)
        }
    }

    func testOwnerMayRaiseAboveDefault() {
        var s = AgentPolicy.Settings()
        s.tiers[.shopSearch] = .confirm
        s.tiers[.mailSend] = .prepareOnly
        XCTAssertEqual(decide(sample(.shopSearch), settings: s).tier, .confirm)
        XCTAssertEqual(decide(sample(.mailSend), settings: s).tier, .prepareOnly)
    }

    // MARK: Rules

    func testPreapprovedNeedsAMatchingStructuredRule() {
        let s = rules([(.eventAdd, "agent-calendar"), (.reminderAdd, "agent-reminders"), (.reminderDone, "agent-reminders")])
        for t in [AgentActionType.eventAdd, .reminderAdd, .reminderDone] {
            XCTAssertEqual(decide(sample(t), settings: s, inAgentList: true).tier, .preapproved, "\(t)")
        }
        // Tier chosen but no rule, or a rule with the wrong target.
        var none = AgentPolicy.Settings()
        none.tiers[.eventAdd] = .preapproved
        let d = decide(sample(.eventAdd), settings: none)
        XCTAssertEqual(d.tier, .confirm)
        XCTAssertFalse(d.reasons.isEmpty)
        XCTAssertEqual(decide(sample(.eventAdd), settings: rules([(.eventAdd, "self")])).tier, .confirm)
        XCTAssertEqual(decide(sample(.eventAdd), settings: rules([(.reminderAdd, "agent-calendar")])).tier, .confirm)
        // A rule alone does not lower a type the owner left at confirm.
        var ruleOnly = AgentPolicy.Settings()
        ruleOnly.rules = [ToolRule(type: .eventAdd, target: "agent-calendar")]
        XCTAssertEqual(decide(sample(.eventAdd), settings: ruleOnly).tier, .confirm)
    }

    /// The rule names the "AI 비서" list: a reminder_done on any other reminder (or one not found) is a card. Adds have
    /// no list to pick; the executor writes a rule's run into "AI 비서" or nowhere (NativeActionsTests).
    func testARuleTicksOnlyRemindersInTheAgentList() {
        let s = rules([(.reminderDone, "agent-reminders"), (.eventAdd, "agent-calendar"), (.reminderAdd, "agent-reminders")])
        let outside = decide(sample(.reminderDone), settings: s)
        XCTAssertEqual(outside.tier, .confirm)
        XCTAssertEqual(outside.reasons, ["AI 비서 목록 밖의 미리알림이라 확인받을게요"])
        XCTAssertEqual(decide(sample(.reminderDone), settings: s, inAgentList: true).tier, .preapproved)
        XCTAssertEqual(decide(sample(.eventAdd), settings: s).tier, .preapproved)
        XCTAssertEqual(decide(sample(.reminderAdd), settings: s).tier, .preapproved)
        // Without a rule the list makes no difference.
        XCTAssertEqual(decide(sample(.reminderDone), inAgentList: true).tier, .confirm)
    }

    func testEventsFromMailStayConfirm() {
        let s = rules([(.eventAdd, "agent-calendar"), (.reminderAdd, "agent-reminders")])
        XCTAssertEqual(decide(sample(.eventAdd, fromOwner: false), settings: s).tier, .confirm)
        XCTAssertEqual(decide(sample(.reminderAdd, fromOwner: false), settings: s).tier, .confirm)
    }

    func testRuleCapAndExpiry() {
        let s = rules([(.eventAdd, "agent-calendar")], perDay: 3)
        let id = s.rules[0].id
        XCTAssertEqual(decide(sample(.eventAdd), settings: s, uses: [id: 2]).tier, .preapproved)
        XCTAssertEqual(decide(sample(.eventAdd), settings: s, uses: [id: 3]).tier, .confirm)
        XCTAssertEqual(AgentPolicy.matchingRule(sample(.eventAdd), rules: s.rules, ruleUsesToday: [id: 2], now: now)?.id, id)
        XCTAssertNil(AgentPolicy.matchingRule(sample(.eventAdd), rules: s.rules, ruleUsesToday: [id: 3], now: now))

        let expired = rules([(.eventAdd, "agent-calendar")], expires: now.addingTimeInterval(-1))
        XCTAssertEqual(decide(sample(.eventAdd), settings: expired).tier, .confirm)
        let later = rules([(.eventAdd, "agent-calendar")], expires: now.addingTimeInterval(60))
        XCTAssertEqual(decide(sample(.eventAdd), settings: later).tier, .preapproved)
    }

    func testMailToSelfMayBePreapproved() {
        let s = rules([(.mailSend, "self"), (.mailReply, "self")])
        XCTAssertEqual(decide(sample(.mailSend, to: selfAddr), settings: s).tier, .preapproved)
        XCTAssertEqual(decide(sample(.mailReply, to: selfAddr), settings: s).tier, .preapproved)
        XCTAssertTrue(decide(sample(.mailSend, to: selfAddr), settings: s).needsReview)
        // Any other recipient (To or Cc) puts it back at confirm.
        var mixed = MailDraft(to: selfAddr, subject: "메모", body: "내일 할 일")
        mixed.cc = [Recipient(name: nil, address: "bob@example.com", provenance: .contact)]
        XCTAssertEqual(decide(.mailSend(mixed), settings: s).tier, .confirm)
        // Self mail without a self rule stays at the default.
        XCTAssertEqual(decide(sample(.mailSend, to: selfAddr)).tier, .confirm)
        XCTAssertEqual(decide(sample(.mailSend, to: selfAddr), settings: rules([(.mailSend, "agent-calendar")])).tier, .confirm)
    }

    // MARK: Concerns and origin

    func testBlockingConcernBlocks() {
        let c = Concern(kind: .secret, message: "카드번호", blocking: true)
        for t in AgentActionType.allCases {
            let d = decide(sample(t), concerns: [c])
            XCTAssertEqual(d.tier, .blocked, "\(t)")
            XCTAssertEqual(d.reasons, ["카드번호"])
        }
        let s = rules([(.eventAdd, "agent-calendar")])
        XCTAssertEqual(decide(sample(.eventAdd), settings: s, concerns: [c]).tier, .blocked)
    }

    func testWarningRaisesToConfirm() {
        let w = Concern(kind: .secret, message: "계좌 확인", blocking: false)
        XCTAssertEqual(decide(sample(.shopSearch), concerns: [w]).tier, .confirm)
        XCTAssertEqual(decide(sample(.memoryAdd), concerns: [w]).reasons, ["계좌 확인"])
        XCTAssertEqual(decide(sample(.eventAdd), settings: rules([(.eventAdd, "agent-calendar")]), concerns: [w]).tier, .confirm)
        // Never lowers a stricter tier.
        XCTAssertEqual(decide(sample(.kakaoPrepare), concerns: [w]).tier, .prepareOnly)
    }

    func testBackgroundNeverRunsWithoutACard() {
        let s = rules([(.eventAdd, "agent-calendar"), (.reminderAdd, "agent-reminders"), (.reminderDone, "agent-reminders"),
                       (.mailSend, "self"), (.mailReply, "self")])
        var all = s
        for t in AgentActionType.allCases where all.tiers[t] == nil { all.tiers[t] = .auto }
        for t in AgentActionType.allCases {
            let d = decide(sample(t, to: selfAddr), origin: .background, settings: all)
            XCTAssertGreaterThanOrEqual(d.tier, .confirm, "\(t)")
        }
        XCTAssertFalse(decide(sample(.shopSearch), origin: .background).reasons.isEmpty)
    }
}
