import Foundation

/// One bubble of the chat page.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, character, notice }
    let id = UUID()
    var role: Role
    var text: String
    /// The numbers the answer was given (FactChips), shown under it.
    var chips: [String] = []
    var actions: [AssistantAction] = []
    /// 비서가 행동하기: the card shown under this bubble (AgentCenter's PendingStore id).
    var proposal: UUID?
    /// Choices the planner offered (동명이인, two readings of a date): tapping one sends it as the next message.
    var suggestions: [String] = []
    /// Namesakes from Contacts ("김부장 <kim@a.com>"): a tap is resolved by AgentCenter.choose, never sent to the model.
    var contactChoices: [String] = []
    /// Who wrote this answer ("Claude · claude-opus-5-5", "이 맥"); nil for the app's own fixed answers.
    var by: String?
}

/// The chat: messages on screen, the turns the model sees, the engine choice. Kept in memory only, never saved.
@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    @Published var messages: [ChatMessage] = []
    @Published private(set) var thinking = false
    private var turns: [ChatTurn] = []
    private var summary = ""
    private var agentHintSaid = false
    /// The agent just asked something: the answer goes back to the planner, not to the chat engine.
    private var agentFollowUp = false

    /// Which engine answers the next question.
    func kind(_ s: AssistantSettings = .shared) -> AssistantEngines.Kind {
        AssistantEngines.pick(onDevice: OnDeviceEngine.isAvailable)
    }

    func engine(_ k: AssistantEngines.Kind) -> ChatEngine {
        switch k {
        case .onDevice: return OnDeviceEngine.shared
        case .template: return TemplateEngine()
        }
    }

    nonisolated static func persona(_ app: AppSettings = .shared, _ s: AssistantSettings = .shared) -> Persona {
        let c = app.shownCharacter
        let id = c == .original ? app.originalID : c == .cat ? app.catID : nil
        let own = app.shownVoice
        return Persona.resolve(name: app.characterName, character: c, id: id, chosen: s.persona, own: own.style, cries: own.cries)
    }

    /// The caption under an answer: 내 AI and its model when it answered, 이 맥 when Apple Intelligence did (a 내 AI
    /// failure included), nil for a fixed or template answer. Read right after the answer: BYOEngine has reported by then.
    static func answeredBy(raw: Bool, mine: BYOEngine?, kind: AssistantEngines.Kind, _ byo: BYOSettings = .shared) -> String? {
        guard raw else { return nil }
        if let mine, byo.lastFailure == nil { return "\(mine.provider.label) · \(byo.lastModel ?? mine.model)" }
        if mine != nil { return L("이 맥") }
        switch kind {
        case .onDevice: return L("이 맥")
        case .template: return nil
        }
    }

    /// Called when the chat page opens: loads the on-device model so the first answer comes faster.
    func prewarm() {
        let k = kind()
        if k != .template { engine(k).prewarm(Self.persona()) }
    }

    /// A retyped recipient made a new card: the bubble now shows that one.
    func replaceProposal(_ old: UUID, with new: UUID) {
        if let i = messages.firstIndex(where: { $0.proposal == old }) { messages[i].proposal = new }
    }

    func clear() {
        messages = []
        turns = []
        summary = ""
        agentFollowUp = false
        restorePending()
    }

    /// Cards still waiting (after a relaunch or a cleared chat) come back as bubbles, so each can be tapped or cancelled.
    func restorePending() {
        guard AgentCenter.shared.active else { return }
        let shown = Set(messages.compactMap(\.proposal))
        for f in AgentCenter.shared.pending.pending() where !shown.contains(f.id) {
            var m = ChatMessage(role: .character, text: f.origin == .background ? L("자리를 비운 사이 맡긴 일이 남긴 카드예요.") : L("확인 기다리는 일이에요."))
            m.proposal = f.id
            messages.append(m)
        }
    }

    /// A namesake chip: shown here with the address, but the turn the model later sees says only that one was picked.
    func choose(_ index: Int, of message: ChatMessage) async {
        guard message.contactChoices.indices.contains(index), !thinking else { return }
        thinking = true
        defer { thinking = false }
        messages.append(ChatMessage(role: .user, text: message.contactChoices[index]))
        if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i].contactChoices = [] }
        let replies = await AgentCenter.shared.choose(index)
        messages.append(contentsOf: replies)
        agentFollowUp = false
        turns.append(ChatTurn(user: L("(연락처에서 한 명을 고름)"), reply: replies.first?.text ?? ""))
        (summary, turns) = AssistantPrompt.window(turns, summary: summary)
    }

    /// Asks the current engine, falling back to the template answer (plus why) when it fails.
    func send(_ raw: String, monitor: SystemMonitor) async {
        let question = AssistantPrompt.short(raw, AssistantPrompt.maxQuestion)
        guard !question.isEmpty, !thinking else { return }
        messages.append(ChatMessage(role: .user, text: question))
        thinking = true
        defer { thinking = false }

        let snap = monitor.sampleNow()
        let facts = SystemSnapshotText.lines(snap, busyApps: SystemSnapshotText.busyApps())
        let persona = Self.persona()
        let settings = AssistantSettings.shared
        let (folded, recent) = AssistantPrompt.window(turns, summary: summary)
        let intent = AssistantIntent.route(question, hasHistory: !recent.isEmpty, previous: recent.last?.user)
        // 집중 타이머 and today's to-do count: answered here, on this Mac (reminder titles never reach a model).
        if intent == .focus || intent == .todoProgress {
            let text = intent == .focus ? FocusCenter.shared.chat(question, persona: persona)
                                        : TodoProgress.answer(settings.reminders ? await CalendarLink.shared.todayProgress() : nil, polite: !persona.style.banmal)
            let shown = persona.dress(text, flair: false)
            messages.append(ChatMessage(role: .character, text: shown))
            turns.append(ChatTurn(user: question, reply: L("(이 맥 안에서만 답한 내용이라 기록하지 않음)")))
            (summary, turns) = AssistantPrompt.window(turns, summary: summary)
            if settings.voice { AssistantVoice.shared.speak(shown) }
            return
        }
        let k = kind()
        // Today's events, then up to 3 to-dos ("할 일: 10:00 보고서").
        let today = intent == .schedule ? CalendarLink.shared.todayLines() + (await CalendarLink.shared.todayReminders()).prefix(3) : []
        var request = ChatRequest(persona: persona, summary: folded, history: recent, facts: facts, personal: today, question: question)
        request.hints = SystemSnapshotText.verdicts(snap)
        request.intent = intent
        if intent == .inbox { request.inbox = await AssistantContext.inbox(request.inboxQuery) }
        request.calendarLinked = settings.calendar && CalendarLink.authorized(.event)
        request.remindersLinked = settings.reminders && CalendarLink.authorized(.reminder)
        request.workHours = settings.workHours.greet.contains(.leave) ? settings.workHours : nil
        // Only with the 날씨 창문 on (privacy page: nothing leaves for weather otherwise); off, the old 'can't know' answer.
        if intent == .realtime, AssistantIntent.realtimeKind(question) == .weather, WeatherWindow.shared.on {
            request.weather = await WeatherService.shared.forecast()
        }

        // 내 AI 연결 (BYOEngine) answers when connected; calendar and inbox questions only with its sharePersonal switch.
        // 비서가 행동하기: a request to do something goes to the planner, which answers with a card (never runs it).
        let followUp = agentFollowUp
        agentFollowUp = false
        if AgentCenter.shared.active, followUp || AgentCenter.wantsAgent(question, intent: intent), let planner = BYOEngine.active(intent: nil),
           let replies = await AgentCenter.shared.handle(question, history: recent, persona: persona, engine: planner) {
            messages.append(contentsOf: replies)
            agentFollowUp = AgentCenter.shared.wantsFollowUp || replies.contains { !$0.suggestions.isEmpty || !$0.contactChoices.isEmpty }
            turns.append(ChatTurn(user: question, reply: replies.first { $0.role == .character }?.text ?? ""))
            (summary, turns) = AssistantPrompt.window(turns, summary: summary)
            return
        }
        let mine = BYOEngine.active(intent: intent)
        if mine != nil { request.strong = true; request.maxCharacters = AssistantPrompt.strongAnswer }
        let result = await AssistantAnswer.make(request, engine: mine ?? engine(k))
        if result.error == .contextTooLong { turns = []; summary = "" }
        let answer = result.text
        // 울음소리 말투: the sound goes on here, outside the turns the model sees. An inbox answer is a list: as is.
        let shown = intent == .inbox ? answer : persona.dress(answer, flair: false)

        if let e = result.error { messages.append(ChatMessage(role: .notice, text: e.message)) }
        // "회의 잡아 줘" with the agent off: say once where it can be turned on.
        if intent == .action, !AgentCenter.shared.active, !agentHintSaid {
            agentHintSaid = true
            messages.append(ChatMessage(role: .notice, text: L("비서 설정에서 '비서가 행동하기'를 켜면 메일·일정·쇼핑·항공권을 대신 준비해 줄 수 있어요.")))
        }
        // Number chips and cards only where the Mac was the subject (a CPU chip under "고래는 포유류야?" is noise).
        let aboutMac = intent == .mac || intent == .action
        let freeDisk = snap.disk.map { $0.total > 0 ? Double($0.available) / Double($0.total) : 1 }
        var reply = ChatMessage(role: .character, text: shown, chips: FactChips.chips(request.shownFacts),
                                actions: AssistantAction.suggest(question: question, cpu: aboutMac ? snap.cpu.usage : nil,
                                                                 diskFreeFraction: aboutMac ? freeDisk : nil))
        reply.by = Self.answeredBy(raw: result.raw != nil, mine: mine, kind: k)
        messages.append(reply)
        // "춤춰 줘", "응원해 줘": the menu bar character does it too, with the answer in its bubble (read aloud below).
        // The desktop friends join in, and the line pops up on a picture card over one of them.
        if intent == .dance || intent == .cheer {
            SituationEngine.play([.special, .eat])
            let card: PoseCard = intent == .dance ? .dance : .cheer
            DesktopKit.celebrate.send(card)
            SpeechBubbleCenter.shared.say(text: persona.exclaim(answer), source: .assistant, aloud: false, card: card, anchor: DesktopFriends.speaker)
        }
        // History can go to the cloud on a later turn: calendar titles and received messages never enter it.
        let personal = intent == .schedule || intent == .inbox
        turns.append(ChatTurn(user: question, reply: personal ? L("(이 맥 안에서만 답한 내용이라 기록하지 않음)") : answer))
        (summary, turns) = AssistantPrompt.window(turns, summary: summary)
        if AssistantSettings.shared.voice { AssistantVoice.shared.speak(shown) }
    }
}
