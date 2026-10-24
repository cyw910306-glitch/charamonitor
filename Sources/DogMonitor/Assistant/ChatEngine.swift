import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Something that answers the AI 비서: this Mac's Apple Intelligence (OnDeviceEngine), the owner's own AI (BYOEngine)
/// and the template fallback.
/// Engines never get tools: the app puts the numbers in the request and runs nothing the model says.
protocol ChatEngine {
    /// Shown under the chat ("이 맥 안에서 답해요" ...).
    var label: String { get }
    /// Loads the model ahead of the first question (no-op where nothing to load).
    func prewarm(_ persona: Persona)
    /// The raw answer; AssistantPrompt.clean runs on it afterwards. Throws ChatError.
    func reply(_ request: ChatRequest) async throws -> String
    /// A big model (내 AI 연결): it answers the small talk, jokes and topic questions the templates take from the small one.
    var strong: Bool { get }
}

extension ChatEngine {
    func prewarm(_ persona: Persona) {}
    var strong: Bool { false }
}

/// Why an answer failed, with what the user is told.
enum ChatError: Error, Equatable {
    case unavailable(String)   // the engine cannot run on this Mac; the message says why and what to do
    case guardrail             // the model refused the topic
    case rateLimited           // too many requests (a menu bar app is a background app to Apple Intelligence)
    case contextTooLong
    case busy                  // an answer is still being made
    case language
    case network
    case server(String)
    case other

    var message: String {
        switch self {
        case .unavailable(let why): return why
        case .guardrail: return L("그 이야기는 답하기 어려워요. 다른 걸 물어봐 주세요.")
        case .rateLimited: return L("AI가 잠깐 쉬는 중이에요. 조금 뒤에 다시 물어봐 주세요.")
        case .contextTooLong: return L("대화가 길어져서 앞부분을 정리했어요. 다시 물어봐 주세요.")
        case .busy: return L("앞 질문의 답을 만드는 중이에요.")
        case .language: return L("이 맥의 AI가 이 언어를 아직 못 알아들어요.")
        case .network: return L("인터넷에 연결하지 못했어요.")
        case .server(let m): return m
        case .other: return L("답을 만들지 못했어요.")
        }
    }
}

/// Which built-in engine answers when no 내 AI does: on-device when possible, else templates.
enum AssistantEngines {
    enum Kind: Equatable { case onDevice, template }

    static func pick(onDevice: Bool) -> Kind { onDevice ? .onDevice : .template }
}

// MARK: - On-device (Apple Foundation Models)

/// This Mac's Apple Intelligence model: free, private, macOS 26+. Measured here: about 2 s per answer in Korean.
/// Context is 4096 tokens a session, so every question gets a fresh session with the last 6 turns in the prompt.
final class OnDeviceEngine: ChatEngine {
    static let shared = OnDeviceEngine()
    let label = L("이 맥 안의 Apple Intelligence로 답해요. 대화는 맥 밖으로 나가지 않아요.")
    /// One prewarmed session waits for the next question; it is used once and replaced.
    private var ready: AnyObject?
    private var readyFor: Persona?
    private let lock = NSLock()

    /// nil when it can run; otherwise what the user is told.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return L("이 맥은 Apple Intelligence를 지원하지 않아서 기본 답변으로 대화해요.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return L("시스템 설정 > Apple Intelligence와 Siri에서 Apple Intelligence를 켜면 더 똑똑하게 답할 수 있어요.")
            case .unavailable(.modelNotReady): return L("Apple Intelligence 모델을 받는 중이에요. 다 받으면 더 똑똑하게 답해요.")
            case .unavailable: return L("지금은 Apple Intelligence를 쓸 수 없어서 기본 답변으로 대화해요.")
            }
        }
        #endif
        return L("macOS 26 이상에서는 이 맥 안의 AI와 대화할 수 있어요. 지금은 기본 답변으로 대화해요.")
    }

    static var isAvailable: Bool { unavailableReason == nil }

    func prewarm(_ persona: Persona) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), Self.isAvailable {
            let s = LanguageModelSession(instructions: persona.instructions)
            s.prewarm()
            lock.withLock { ready = s; readyFor = persona }
        }
        #endif
    }

    func reply(_ request: ChatRequest) async throws -> String {
        if Pivot.applies(request) {
            // 0: one fact, said the same way each time (measured at 0.3: "물 한 모금은 100도의 온도에서 끓어" one run in two).
            let first = try await respond(instructions: Pivot.instructions, prompt: Pivot.prompt(request), persona: nil,
                                          maxTokens: 140, temperature: 0)
            let en = Pivot.english(first)
            if ProcessInfo.processInfo.environment["ASSISTANT_DEBUG"] != nil { print("== 영어 답\n" + first) }   // --assistant-ask tuning
            if !en.isEmpty {
                let retell = { (t: Double) in try await self.respond(instructions: Pivot.retellInstructions(request.persona),
                                                                    prompt: Pivot.retell(request, english: Pivot.bare(en)), persona: nil, maxTokens: 160, temperature: t) }
                var ko = try await retell(0)
                // A number the English never had: once more, a little looser (temperature 0 is not the same answer each run either).
                if Pivot.invents(ko, english: en), let again = try? await retell(0.3), !Pivot.invents(again, english: en) { ko = again }
                return Pivot.settle(ko, english: en)
            }
        }
        return try await respond(instructions: request.persona.instructions, prompt: request.prompt, persona: request.persona, maxTokens: 120)
    }

    /// One short line for 먼저 말 걸기.
    func line(_ persona: Persona, situation: String) async throws -> String {
        try await respond(instructions: persona.nudgeInstructions(situation), prompt: "한 문장으로 말해 줘.", persona: nil, maxTokens: 80)
    }

    /// One word for 딴짓 지킴이 (DriftRules.aiPrompt), the same each time it is asked.
    func word(_ prompt: String) async throws -> String {
        try await respond(instructions: "주어진 화면을 집중, 중립, 딴짓 중 하나로만 답한다.", prompt: prompt, persona: nil, maxTokens: 8, temperature: 0)
    }

    private func respond(instructions: String, prompt: String, persona: Persona?, maxTokens: Int, temperature: Double = 0.3) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let why = Self.unavailableReason { throw ChatError.unavailable(why) }
            let session: LanguageModelSession = lock.withLock {
                defer { ready = nil; readyFor = nil }
                if let persona, readyFor == persona, let s = ready as? LanguageModelSession { return s }
                return LanguageModelSession(instructions: instructions)
            }
            // 0.3: facts over flair (measured at 0.6: three different wrong products for one multiplication).
            let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
            do {
                let r = try await session.respond(to: prompt, options: options)
                if let persona { prewarm(persona) }   // the next question finds a loaded session
                return r.content
            } catch let e as LanguageModelSession.GenerationError {
                // The default guardrails stop harmless questions now and then ("맥이 뜨거운데 괜찮아?" 1 of 6): one retry
                // with the permissive ones before falling back to the template.
                if case .guardrailViolation = e,
                   let again = try? await LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                                                               instructions: instructions).respond(to: prompt, options: options) {
                    return again.content
                }
                throw Self.map(e)
            }
        }
        #endif
        throw ChatError.unavailable(Self.unavailableReason ?? "")
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    static func map(_ e: LanguageModelSession.GenerationError) -> ChatError {
        switch e {
        case .guardrailViolation, .refusal: return .guardrail
        case .rateLimited: return .rateLimited
        case .exceededContextWindowSize: return .contextTooLong
        case .concurrentRequests: return .busy
        case .unsupportedLanguageOrLocale: return .language
        case .assetsUnavailable: return .unavailable(L("Apple Intelligence 모델을 받는 중이에요. 다 받으면 더 똑똑하게 답해요."))
        default: return .other
        }
    }
    #endif
}

// MARK: - One answer, start to end

/// What the chat and --assistant-ask both do: a fixed answer when the intent needs no model, else the engine,
/// cleaned, else the template (with why).
enum AssistantAnswer {
    struct Result {
        var text: String
        var raw: String?        // the engine's own words (nil: fixed or failed)
        var error: ChatError?
    }

    static func make(_ r: ChatRequest, engine: ChatEngine) async -> Result {
        let fallback = { AssistantPrompt.clean(TemplateEngine.answer(r), persona: r.persona, max: r.maxCharacters) }
        // An inbox answer is the app's own list, one item a line: said as is, never cut to three sentences.
        if let f = TemplateEngine.fixed(r), !(engine.strong && TemplateEngine.modelTakes(r)) {
            return Result(text: r.resolvedIntent == .inbox ? f : fallback(), raw: nil, error: nil)
        }
        do {
            let raw = try await engine.reply(r)
            let text = AssistantPrompt.clean(raw, persona: r.persona, max: r.maxCharacters, for: r)
            return Result(text: text.isEmpty ? fallback() : text, raw: raw, error: nil)
        } catch let e as ChatError {
            return Result(text: fallback(), raw: nil, error: e)
        } catch {
            return Result(text: fallback(), raw: nil, error: .other)
        }
    }
}

// MARK: - Templates (free, every Mac)

/// Answers built without a model: for Macs without Apple Intelligence, when an engine fails, and (`fixed`) for the
/// questions no model should answer.
struct TemplateEngine: ChatEngine {
    let label = L("기본 답변이에요. 숫자로 지금 상태를 알려 드려요.")

    func reply(_ request: ChatRequest) async throws -> String { Self.answer(request) }

    /// Answers that never go to a model: what the character cannot do, live data it cannot know, a vague question,
    /// and mail or calendar it has nothing from.
    static func fixed(_ r: ChatRequest) -> String? {
        let polite = !r.persona.style.banmal
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        // Measured 2026-10-18: the model made up "퇴근까지 1시간 남았어" with no 퇴근 time anywhere.
        if Self.asksLeave(r.question), [.general, .realtime].contains(r.resolvedIntent) { return leave(r, polite) }
        switch r.resolvedIntent {
        case .action:
            switch AssistantIntent.actionKind(r.question) ?? .other {
            case .schedule: return say(L("일정은 내가 직접 못 만들어. 캘린더 앱에서 추가해 줘."), L("일정은 제가 직접 만들 수 없어요. 캘린더 앱에서 추가해 주세요."))
            case .alarm: return say(L("알람은 내가 못 맞춰. 시계 앱이나 Siri에게 부탁해 줘."), L("알람은 제가 맞출 수 없어요. 시계 앱이나 Siri에게 부탁해 주세요."))
            case .send: return say(L("메시지는 내가 직접 못 보내. 메일이나 메시지 앱에서 보내 줘."), L("메시지는 제가 직접 보낼 수 없어요. 메일이나 메시지 앱에서 보내 주세요."))
            case .files:
                #if MAS
                return say(L("파일은 내가 직접 못 지워. Finder에서 정리해 줘."), L("파일은 제가 직접 지울 수 없어요. Finder에서 정리해 주세요."))
                #else
                return say(L("파일은 내가 직접 못 지워. 클리너에서 확인하고 정리할 수 있어."), L("파일은 제가 직접 지울 수 없어요. 클리너에서 확인하고 정리할 수 있어요."))
                #endif
            case .apps: return say(L("앱을 열거나 끄는 건 내가 직접 못 해. 활성 상태 보기에서 확인할 수 있어."), L("앱을 열거나 끄는 건 제가 직접 못 해요. 활성 상태 보기에서 확인할 수 있어요."))
            case .other: return say(L("그건 내가 직접 할 수 없어. 하는 방법이 궁금하면 물어봐 줘."), L("그건 제가 직접 할 수 없어요. 하는 방법이 궁금하면 물어봐 주세요."))
            }
        case .realtime:
            let f = DateFormatter()
            f.locale = appLocale
            switch AssistantIntent.realtimeKind(r.question) ?? .news {
            case .time:
                if appIsEnglish { f.setLocalizedDateFormatFromTemplate("ahm") } else { f.dateFormat = "a h시 m분" }   // "오후 9시 39분이야"
                let t = f.string(from: r.now)
                return say(L("지금은 \(t)이야."), L("지금은 \(t)이에요."))
            case .date:
                // "내일 무슨 요일이야?": the day asked about, not always today.
                let offset = AssistantIntent.dayOffset(r.question) ?? 0
                let day = Calendar.current.date(byAdding: .day, value: offset, to: r.now) ?? r.now
                f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
                let d = f.string(from: day)
                let which = [-2: L("그저께는"), -1: L("어제는"), 1: L("내일은"), 2: L("모레는"), 3: L("글피는")][offset] ?? L("오늘은")
                return offset < 0 ? say(L("\(which) \(d)이었어."), L("\(which) \(d)이었어요.")) : say(L("\(which) \(d)이야."), L("\(which) \(d)이에요."))
            case .money: return say(L("환율이나 시세는 실시간 정보라 지금 알 수 없어. 은행이나 증권 앱에서 확인해 줘."), L("환율이나 시세는 실시간 정보라 지금 알 수 없어요. 은행이나 증권 앱에서 확인해 주세요."))
            case .weather:
                if let w = r.weather, let a = w.answer(polite: polite, dayOffset: AssistantIntent.dayOffset(r.question) ?? 0) { return a }
                return say(L("날씨는 실시간 정보라 지금 알 수 없어. 날씨 앱에서 확인해 줘."), L("날씨는 실시간 정보라 지금 알 수 없어요. 날씨 앱에서 확인해 주세요."))
            case .news: return say(L("뉴스는 실시간 정보라 지금 알 수 없어. 뉴스 앱이나 검색으로 확인해 줘."), L("뉴스는 실시간 정보라 지금 알 수 없어요. 뉴스 앱이나 검색으로 확인해 주세요."))
            case .sports: return say(L("경기 결과는 실시간 정보라 지금 알 수 없어. 스포츠 앱에서 확인해 줘."), L("경기 결과는 실시간 정보라 지금 알 수 없어요. 스포츠 앱에서 확인해 주세요."))
            }
        case .joke:
            let (quiz, answer) = LinePick.pick("riddle", riddles)
            return say(L("문제 하나 낼게. \(quiz) 정답은 \(answer)."), L("문제 하나 낼게요. \(quiz) 정답은 \(answer)."))
        case .inbox:
            // Said as the app has it (measured: the model turned "보낸 사람 이지은, 네이버페이" into "이지은이 보낸 네이버페이 메일").
            return (r.inbox ?? InboxReport(query: r.inboxQuery)).answer(polite: polite, now: r.now)
        case .vague:
            return say(L("어떤 걸 말하는 건지 조금만 더 알려 줘."), L("어떤 걸 말씀하시는 건지 조금만 더 알려 주세요."))
        case .mac where !r.facts.isEmpty:
            return MacAnswer(facts: r.facts, question: r.macQuestion, polite: polite).text
        case .schedule where r.personal.isEmpty:
            if asksTodos(r.question) { return noTodos(r, polite) }
            return r.calendarLinked ? say(L("오늘 남은 일정은 없어."), L("오늘 남은 일정은 없어요."))
                                    : say(L("캘린더 연동이 꺼져 있어서 일정을 볼 수 없어. 비서 설정에서 켜 줘."), L("캘린더 연동이 꺼져 있어서 일정을 볼 수 없어요. 비서 설정에서 켜 주세요."))
        case .schedule:
            return schedule(r, polite)
        case .dance:
            let p = LinePick.pick("chat.dance", danceLines)
            return r.persona.flavor(polite ? p.1 : p.0)
        case .cheer:
            let p = LinePick.pick("chat.cheer", cheerLines)
            return r.persona.flavor(polite ? p.1 : p.0)
        case .calc:
            // "250 ÷ 4 = 62.5야" (measured: "62.5이야", and "8만원의 15%" made into nothing by the clean-up).
            guard let c = Calc.solve(r.question) else { return nil }
            let unit = r.question.range(of: #"\d\s*[만천억]?\s*원"#, options: .regularExpression) != nil ? L("원") : ""
            return c + unit + (polite ? Banmal.particle(c + unit, "이에요", "예요") : Banmal.particle(c + unit, "이야", "야")) + "."
        case .general where Self.thanks(r.question):
            return say(L("천만에, 또 필요하면 불러 줘."), L("천만에요, 또 필요하면 불러 주세요."))
        case .general where Feeling.plainRemark(r.question):
            return Feeling.reply(r.question, polite: polite)
        case .general where Self.greeting(r.question):
            return say(L("안녕! 궁금한 거 있으면 언제든 물어봐."), L("안녕하세요! 궁금한 거 있으면 언제든 물어봐 주세요."))
        case .general:
            guard let (head, a, b) = Self.meal(r.question, now: r.now) else { return nil }
            return say(L("\(head) \(a)\(Banmal.particle(a, "이나", "나")) \(b) 어때?"), L("\(head) \(a)\(Banmal.particle(a, "이나", "나")) \(b) 어때요?"))
        default:
            return nil
        }
    }

    /// What a big model answers better than a template: small talk, jokes, a vague question in context, and live topics it
    /// can say it does not know while still helping (measured 2026-10-05 with Claude: a fixed riddle or "날씨 앱에서 확인해"
    /// read as canned). The clock, sums, Mac numbers, the inbox, the calendar and what the app cannot do stay fixed.
    static func modelTakes(_ r: ChatRequest) -> Bool {
        if asksLeave(r.question) { return false }   // no model knows the owner's 퇴근 time
        switch r.resolvedIntent {
        case .general, .joke, .vague: return true
        case .realtime:
            let k = AssistantIntent.realtimeKind(r.question)
            return ![.time, .date].contains(k) && !(k == .weather && r.weather != nil)   // a real forecast beats any model
        default: return false
        }
    }

    /// "고마워", "감사합니다", "thanks": said back to the character (measured: the model said "고마워!" back).
    static func thanks(_ q: String) -> Bool {
        let t = AssistantPrompt.squeeze(q).filter { $0 != "~" && $0 != "ㅎ" && $0 != "ㅋ" && $0 != "^" }
        return t.count <= 8 && ["고마", "감사", "땡큐", "ㄱㅅ", "thank", "thx", "고맙"].contains(where: t.hasPrefix)
    }

    /// "안녕", "하이", "hello": a greeting back (measured 2026-10-04: "오늘 하루는 어떻게 보내?" with no 안녕 in it).
    static func greeting(_ q: String) -> Bool {
        let t = AssistantPrompt.squeeze(q).filter { !"~ㅎㅋ^!".contains($0) }
        return ["안녕", "안녕하세요", "안뇽", "하이", "ㅎㅇ", "반가워", "반가워요", "hi", "hello", "hey", "헬로", "좋은아침", "굿모닝"].contains(t)
    }

    /// "오늘 점심 뭐 먹지?": two dishes for the meal (measured: the model listed sixteen, or asked the question back).
    static let dishes: [String: [String]] = [
        "아침": ["토스트", "누룽지", "계란말이", "요거트", "김밥", "북엇국"],
        "점심": ["김치찌개", "비빔밥", "칼국수", "돈가스", "쌀국수", "제육볶음", "냉면", "순두부찌개"],
        "저녁": ["된장찌개", "삼겹살", "카레", "부대찌개", "초밥", "닭갈비", "파스타", "샤브샤브"],
        "야식": ["떡볶이", "치킨", "라면", "만두", "족발"],
    ]

    static func meal(_ q: String, now: Date) -> (String, String, String)? {
        let t = q.lowercased().filter { !$0.isWhitespace }
        guard ["뭐먹", "머먹", "뭘먹", "메뉴추천", "메뉴골라", "먹을거추천", "whatshouldieat", "whattoeat"].contains(where: t.contains) else { return nil }
        let hour = Calendar.current.component(.hour, from: now)
        let named = ["아침", "점심", "저녁", "야식"].first { t.contains($0) } ?? (t.contains("밤") ? "야식" : nil)
        let meal = named ?? (hour < 10 ? "아침" : hour < 15 ? "점심" : hour < 21 ? "저녁" : "야식")
        let list = dishes[meal] ?? []
        guard !list.isEmpty else { return nil }
        let i = LinePick.pick("meal." + meal, Array(list.indices))   // never the same pair twice in a row
        let head = named == "야식" ? L("야식으로") : L("오늘 \(meal)은")
        return (head, list[i], list[(i + list.count / 2) % list.count])
    }

    /// Today's calendar said as the app has it, times included (measured 2026-10-04: the model dropped every time).
    /// What was asked picks the part: "다음 약속 몇 시야?" the next one, "그거 몇 시야?" times only, "저녁에 약속 있나"
    /// that part of the day, "오늘 회의 있어?" the events named so. One already started is never "남은" (measured: a
    /// 10:00 meeting listed as left at 10:27), and to-dos come only with the whole day.
    private static func schedule(_ r: ChatRequest, _ polite: Bool) -> String {
        func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
        func be(_ w: String) -> String { polite ? Banmal.particle(w, "이에요", "예요") : Banmal.particle(w, "이야", "야") }
        let todo = r.personal.filter { $0.hasPrefix("할 일:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let events = r.personal.filter { !$0.hasPrefix("할 일:") }.map(Event.init)
        let cal = Calendar.current
        let nowMinute = cal.component(.hour, from: r.now) * 60 + cal.component(.minute, from: r.now)
        let started = events.filter { ($0.minute ?? .max) < nowMinute }, ahead = events.filter { ($0.minute ?? .max) >= nowMinute }
        let q = r.question.lowercased().filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0.filter { !$0.isWhitespace }) } }
        // The kind of event named here or, for "그거", in the question before ("회의", "약속").
        let named = ([r.question] + (has(AssistantIntent.pointerWords) ? r.history.suffix(1).map(\.user) : []))
            .flatMap { Event.kinds(in: $0) }
        let matchAll = events.filter { e in named.contains { e.title.contains($0) } }
        let matching = matchAll.filter { ahead.contains($0) }
        let pool = matching.isEmpty ? ahead : matching
        let kind = matching.isEmpty ? L("일정") : named.first { k in matching.contains { $0.title.contains(k) } } ?? L("일정")
        let list = { (es: [Event]) in es.map(\.line).joined(separator: ", ") }
        let begun = started.isEmpty ? nil : { let l = list(started); return say(L("\(l)\(Banmal.particle(l, "은", "는")) 이미 시작했어."),
                                                                            L("\(l)\(Banmal.particle(l, "은", "는")) 이미 시작했어요.")) }()
        let none = say(L("오늘 남은 \(kind)\(Banmal.particle(kind, "은", "는")) 없어."), L("오늘 남은 \(kind)\(Banmal.particle(kind, "은", "는")) 없어요."))

        // "회의 언제야?" when the 회의 has begun: that, and what comes next.
        let begunOnly: String? = matching.isEmpty && !matchAll.isEmpty ? {
            let l = list(matchAll)
            var out = [say(L("\(l)\(Banmal.particle(l, "은", "는")) 이미 시작했어."), L("\(l)\(Banmal.particle(l, "은", "는")) 이미 시작했어요."))]
            if let next = ahead.first { out.append(say(L("다음 일정은 \(next.line)\(be(next.line))."), L("다음 일정은 \(next.line)\(be(next.line))."))) }
            return out.joined(separator: " ")
        }() : nil
        let todoLine: String? = todo.isEmpty ? nil : {
            let l = todo.joined(separator: ", ")
            return say(L("할 일은 \(l)\(Banmal.particle(l, "이", "가")) 남았어."), L("할 일은 \(l)\(Banmal.particle(l, "이", "가")) 남았어요."))
        }()
        // Only to-dos known: the calendar being off is said before any branch, not passed over as an empty day or evening.
        if events.isEmpty && !r.calendarLinked {
            if asksTodos(r.question) { return todoLine ?? noTodos(r, polite) }
            let off = say(L("캘린더 연동은 꺼져 있어서 일정은 볼 수 없어."), L("캘린더 연동은 꺼져 있어서 일정은 볼 수 없어요."))
            return ([off] + [todoLine].compactMap { $0 }).joined(separator: " ")
        }
        // "다음 약속 몇 시야?": the next one; the very next event too when the named kind comes later.
        if has(["다음", "next", "이따"]) {
            if let begunOnly { return begunOnly }
            guard let next = pool.first else { return ([none] + [begun].compactMap { $0 }).joined(separator: " ") }
            let head = L("다음 \(kind)\(Banmal.particle(kind, "은", "는"))")
            var out = [say(L("\(head) \(next.line)\(be(next.line))."), L("\(head) \(next.line)\(be(next.line))."))]
            if let first = ahead.first, first != next {
                out.append(say(L("그 전에 \(first.line)도 있어."), L("그 전에 \(first.line)도 있어요.")))
            }
            return out.joined(separator: " ")
        }
        // "그거 몇 시야?", "회의 언제야?": the time, nothing else.
        if has(["몇시", "언제", "whattime", "when"]) {
            if let begunOnly { return begunOnly }
            if pool.count == 1, let e = pool.first {
                return say(L("\(e.title)\(Banmal.particle(e.title, "은", "는")) \(e.time)\(be(e.time))."), L("\(e.title)\(Banmal.particle(e.title, "은", "는")) \(e.time)\(be(e.time))."))
            }
            if pool.isEmpty { return ([none] + [begun].compactMap { $0 }).joined(separator: " ") }
            let l = list(pool)
            return say(L("\(l)\(be(l))."), L("\(l)\(be(l))."))
        }
        var out: [String] = []
        let parts: [(String, ClosedRange<Int>)] = [("아침", 5...10), ("오전", 0...11), ("점심", 11...13), ("오후", 12...17), ("저녁", 17...21), ("밤", 19...23)]
        if let (name, hours) = parts.first(where: { q.contains($0.0) }) {
            let hit = events.filter { $0.minute.map { hours.contains($0 / 60) } ?? false }
            if hit.isEmpty { out.append(say(L("\(name)에는 일정이 없어."), L("\(name)에는 일정이 없어요."))) }
            else {
                let l = list(hit), ga = Banmal.particle(l, "이", "가")
                out.append(say(L("\(name)에는 \(l)\(ga) 있어."), L("\(name)에는 \(l)\(ga) 있어요.")))
            }
            return out.joined(separator: " ")
        }
        // "오늘 할 일 뭐 있어?": the to-dos only.
        if asksTodos(r.question) { return todoLine ?? noTodos(r, polite) }
        if let begunOnly { return begunOnly }
        if !matching.isEmpty {
            let l = list(matching), ga = Banmal.particle(l, "이", "가")
            return say(L("오늘 \(kind)\(Banmal.particle(kind, "은", "는")) \(l)\(ga) 있어."), L("오늘 \(kind)\(Banmal.particle(kind, "은", "는")) \(l)\(ga) 있어요."))
        }
        if !ahead.isEmpty {
            let l = list(ahead)
            out.append(say(L("오늘 남은 일정은 \(l)\(be(l))."), L("오늘 남은 일정은 \(l)\(be(l)).")))
        } else if !events.isEmpty {
            out.append(say(L("오늘 남은 일정은 없어."), L("오늘 남은 일정은 없어요.")))
        }
        if let begun { out.append(begun) }
        if let todoLine { out.append(todoLine) }
        return out.joined(separator: " ")
    }

    /// "오늘 할 일 뭐 있어?": a question about the to-dos alone, not the calendar.
    /// "퇴근까지 얼마나 남았어?", "퇴근 몇 시야?": 퇴근 and a when or how long, not "퇴근하고 싶다".
    static func asksLeave(_ question: String) -> Bool {
        let t = question.filter { !$0.isWhitespace }
        return t.contains("퇴근") && ["얼마", "몇분", "몇시", "언제", "남았", "남은"].contains(where: t.contains)
    }

    /// From the times set in 비서 설정 (퇴근 10분 전 알림), or where to set them.
    static func leave(_ r: ChatRequest, _ polite: Bool, calendar: Calendar = .current) -> String {
        guard let w = r.workHours else {
            return polite ? L("퇴근 시간을 아직 몰라요. 비서 설정에서 퇴근 10분 전 알림을 켜고 시간을 정해 주세요.")
                          : L("퇴근 시간을 아직 몰라. 비서 설정에서 퇴근 10분 전 알림을 켜고 시간을 정해 줘.")
        }
        let end = String(format: "%02d:%02d", w.end / 60, w.end % 60)
        let left = w.minutesToEnd(r.now, calendar: calendar)
        guard left > 0 else { return polite ? L("퇴근 시간(\(end))이 지났어요. 오늘도 수고하셨어요!") : L("퇴근 시간(\(end))이 지났어. 오늘도 수고했어!") }
        let span = left < 60 ? L("\(left)분") : left % 60 == 0 ? L("\(left / 60)시간") : L("\(left / 60)시간 \(left % 60)분")
        return polite ? L("퇴근(\(end))까지 \(span) 남았어요.") : L("퇴근(\(end))까지 \(span) 남았어.")
    }

    static func asksTodos(_ question: String) -> Bool {
        let q = question.lowercased().filter { !$0.isWhitespace }
        return ["할일", "미리알림", "todo", "reminder"].contains(where: q.contains) && !["일정", "스케줄", "schedule"].contains(where: q.contains)
    }

    /// No to-dos to tell: none left, or 미리알림 not linked (never "none" while it is off).
    private static func noTodos(_ r: ChatRequest, _ polite: Bool) -> String {
        if r.remindersLinked { return polite ? L("오늘 남은 할 일은 없어요.") : L("오늘 남은 할 일은 없어.") }
        return polite ? L("미리알림 연동이 꺼져 있어서 할 일을 볼 수 없어요. 비서 설정에서 켜 주세요.")
                      : L("미리알림 연동이 꺼져 있어서 할 일을 볼 수 없어. 비서 설정에서 켜 줘.")
    }

    /// One calendar line, "15:00 디자인 리뷰".
    struct Event: Equatable {
        let line: String
        var time: String { String(line.prefix { $0 != " " }) }
        var title: String { line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces) }
        /// Minutes since midnight; nil when the line has no time.
        var minute: Int? {
            let p = time.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : nil
        }
        init(_ line: String) { self.line = line }

        /// Event words a question names ("오늘 회의 있어?" -> 회의).
        static let kindWords = ["회의", "미팅", "약속", "리뷰", "수업", "면접", "점심", "저녁", "운동", "병원", "meeting", "call"]
        static func kinds(in question: String) -> [String] { kindWords.filter { question.lowercased().contains($0) } }
    }

    /// (banmal, 존댓말) for "춤춰 줘" and "응원해 줘", said while the menu bar character plays its special moment.
    static let danceLines: [(String, String)] = [
        (L("좋아, 춤 간다! 하나 둘, 하나 둘!"), L("좋아요, 춤 갑니다! 하나 둘, 하나 둘!")),
        (L("빙글빙글~ 내 춤 어때?"), L("빙글빙글~ 제 춤 어때요?")),
        (L("음악 없어도 출 수 있어. 둠칫둠칫!"), L("음악 없어도 출 수 있어요. 둠칫둠칫!")),
        (L("신난다! 너도 같이 어깨 들썩여 봐."), L("신나요! 같이 어깨 들썩여 봐요.")),
    ]
    static let cheerLines: [(String, String)] = [
        (L("넌 잘하고 있어. 내가 옆에서 응원할게!"), L("잘하고 계세요. 제가 옆에서 응원할게요!")),
        (L("영차영차! 조금만 더 가 보자. 힘내!"), L("영차영차! 조금만 더 가 봐요. 힘내세요!")),
        (L("오늘도 여기까지 온 거 대단해. 파이팅!"), L("오늘도 여기까지 오신 거 대단해요. 파이팅!")),
        (L("힘들면 잠깐 쉬어도 돼. 난 계속 네 편이야!"), L("힘들면 잠깐 쉬어 가셔도 돼요. 저는 계속 응원할게요!")),
    ]

    static let riddles: [(String, String)] = [
        ("세상에서 가장 가난한 왕은?", "최저임금"), ("왕이 넘어지면?", "킹콩"), ("바나나가 웃으면?", "바나나킥"),
        ("세상에서 가장 뜨거운 과일은?", "천도복숭아"), ("소가 웃으면?", "우하하"), ("오리가 얼면?", "언덕"),
        ("아몬드가 죽으면?", "다이아몬드"), ("딸기가 회사에서 잘리면?", "딸기시럽"),
    ]

    /// Every intent's answer without a model: `fixed`, else what the request's own data says.
    static func answer(_ r: ChatRequest) -> String {
        fixed(r) ?? (r.resolvedIntent == .general ? Feeling.reply(r.question, polite: !r.persona.style.banmal) : nil) ?? general(!r.persona.style.banmal)
    }

    private static func general(_ polite: Bool) -> String {
        polite ? L("그건 지금 기본 답변으로는 답하기 어려워요. 맥 상태, 일정, 메일, 계산은 물어봐 주세요.")
               : L("그건 지금 기본 답변으로는 답하기 어려워. 맥 상태, 일정, 메일, 계산은 물어봐 줘.")
    }
}

/// This Mac's numbers said as the answer, from the SystemSnapshotText lines alone: each asked topic with its number and
/// what it means. Measured 2026-10-04 on the on-device model: "응, CPU가 14.3%밖에 안 써", "디스크가 꽉 찼어?",
/// "재부팅은 필요 없어. 오래 켜 뒀으니 재시동 한 번 해 봐", and not one number for "왜 느려?".
struct MacAnswer {
    let facts: [String]
    let question: String
    let polite: Bool

    private func say(_ banmal: String, _ yo: String) -> String { polite ? yo : banmal }
    /// 이야/야 (이에요/예요) after a value.
    private func be(_ w: String) -> String { polite ? Banmal.particle(w, "이에요", "예요") : Banmal.particle(w, "이야", "야") }

    /// "61.0% (16.0 GB / 24.0 GB, 압력 보통)" -> ("61.0%", "16.0 GB / 24.0 GB, 압력 보통").
    private func fact(_ key: String) -> (value: String, detail: String?)? {
        guard let line = facts.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        guard let open = v.range(of: " ("), v.hasSuffix(")") else { return (v, nil) }
        return (String(v[..<open.lowerBound]), String(v[open.upperBound...].dropLast()))
    }

    static func number(_ s: String) -> Double? {
        s.replacingOccurrences(of: ",", with: "").range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression)
            .flatMap { Double(s.replacingOccurrences(of: ",", with: "")[$0]) }
    }

    /// "1.72 TB" in bytes (only to compare two sizes).
    static func bytes(_ s: String) -> Double? {
        let u = s.uppercased()
        return number(s).map { $0 * (u.contains("TB") ? 1e12 : u.contains("GB") ? 1e9 : u.contains("MB") ? 1e6 : u.contains("KB") ? 1e3 : 1) }
    }

    private var cpu: Double? { fact("CPU").flatMap { Self.number($0.value) } }
    private var pressure: String { fact("메모리")?.detail?.components(separatedBy: "압력 ").dropFirst().first ?? "보통" }
    private var diskFree: Double? {
        guard let d = fact("저장 공간"), let free = Self.bytes(d.value), let total = d.detail.flatMap(Self.bytes), total > 0 else { return nil }
        return free / total
    }
    private var uptimeDays: Int { fact("켜진 지").map { $0.value.contains("일") ? Int(Self.number($0.value) ?? 0) : 0 } ?? 0 }
    private var battery: Int? { fact("배터리").flatMap { Self.number($0.value) }.map { Int($0) } }
    private var plugged: Bool { fact("배터리")?.detail != nil }

    private func asks(_ words: [String]) -> Bool {
        let q = question.lowercased(), t = q.filter { !$0.isWhitespace }
        return words.contains { q.contains($0) || t.contains($0) }
    }

    var text: String {
        let topics = MacTopic.asked(question)
        if MacTopic.isSlow(question) { return slow() }
        if MacTopic.isHog(question) { return hog() }
        if topics.count == MacTopic.allCases.count { return overview() }
        var out: [String] = []
        if topics.contains(.cpu) || topics.contains(.heat) { out += cpuSentences(apps: topics.contains(.cpu)) }
        if topics.contains(.heat) { out.insert(heat(), at: 0) }
        if topics.contains(.memory) { out += memory() }
        if topics.contains(.storage) { out.append(storage()) }
        if topics.contains(.battery) { out += batteryLines() }
        if topics.contains(.network), let n = fact("네트워크")?.value { let v = FactChips.localize(n); out.append(say(L("네트워크는 \(v)\(be(v))."), L("네트워크는 \(v)\(be(v))."))) }
        if topics.contains(.uptime) { out += uptime(advise: true) }
        return out.joined(separator: " ")
    }

    // MARK: Topics

    private func cpuSentences(apps: Bool) -> [String] {
        guard let c = cpu, let v = fact("CPU")?.value else { return [] }
        var out = [c >= 70 ? say(L("CPU가 \(v)로 많이 바빠."), L("CPU가 \(v)로 많이 바빠요."))
                   : c >= 30 ? say(L("CPU는 \(v)로 조금 바쁘지만 괜찮아."), L("CPU는 \(v)로 조금 바쁘지만 괜찮아요."))
                   : say(L("CPU는 \(v)라 여유 있어."), L("CPU는 \(v)라 여유 있어요."))]
        guard apps else { return out }
        if let a = appLine { out.append(a) }
        else if asks(["앱", "app", "프로그램"]) { out.append(say(L("어떤 앱인지는 활성 상태 보기에서 확인해 줘."), L("어떤 앱인지는 활성 상태 보기에서 확인해 주세요."))) }
        return out
    }

    /// The busiest apps as measured: named, "none stands out" only when measured as none, nil when not measured
    /// (measured 2026-10-04: no app line at all was said as "눈에 띄게 많이 쓰는 앱은 없어").
    private var appLine: String? {
        guard let a = fact("바쁜 앱")?.value else { return nil }
        if a == "없음" { return say(L("지금은 눈에 띄게 CPU를 많이 쓰는 앱이 없어."), L("지금은 눈에 띄게 CPU를 많이 쓰는 앱이 없어요.")) }
        if !a.contains(",") { return say(L("CPU를 제일 많이 쓰는 앱은 \(a)\(be(a))."), L("CPU를 제일 많이 쓰는 앱은 \(a)\(be(a)).")) }
        return say(L("CPU를 많이 쓰는 앱은 \(a) 순이야."), L("CPU를 많이 쓰는 앱은 \(a) 순이에요."))
    }

    /// "무슨 앱이 제일 많이 먹어?": the app first, then the whole Mac's CPU and memory.
    private func hog() -> String {
        var out = [appLine ?? say(L("앱별 사용량은 지금 내가 못 읽어서, 어떤 앱인지는 활성 상태 보기에서 확인해 줘."),
                               L("앱별 사용량은 지금 제가 못 읽어서, 어떤 앱인지는 활성 상태 보기에서 확인해 주세요."))]
        if let c = fact("CPU")?.value, let m = fact("메모리")?.value {
            let busy = (cpu ?? 0) >= 70 || pressure != "보통"
            out.append(busy ? say(L("전체로는 CPU \(c), 메모리 \(m)를 쓰는 중이라 빠듯해."), L("전체로는 CPU \(c), 메모리 \(m)를 쓰는 중이라 빠듯해요."))
                            : say(L("전체로는 CPU \(c), 메모리 \(m)를 쓰는 중이라 여유 있어."), L("전체로는 CPU \(c), 메모리 \(m)를 쓰는 중이라 여유 있어요.")))
        }
        return out.joined(separator: " ")
    }

    private func memory() -> [String] {
        guard let m = fact("메모리"), let used = Self.number(m.value) else { return [] }
        let left = String(format: "%.1f%%", max(0, 100 - used))
        let sizes = m.detail?.components(separatedBy: ", ").first?.components(separatedBy: " / ") ?? []
        var out: [String]
        if sizes.count == 2, let u = Self.number(sizes[0]), let t = Self.number(sizes[1]), t >= u {
            let free = String(format: "%.1f GB", t - u)
            out = [say(L("메모리는 \(sizes[1]) 중 \(sizes[0])를 쓰고 있어서 \(free)(\(left))가 남았어."),
                       L("메모리는 \(sizes[1]) 중 \(sizes[0])를 쓰고 있어서 \(free)(\(left))가 남았어요."))]
        } else {
            out = [say(L("메모리는 \(m.value)를 쓰고 있어서 \(left)가 남았어."), L("메모리는 \(m.value)를 쓰고 있어서 \(left)가 남았어요."))]
        }
        switch pressure {
        case "보통": out.append(say(L("압력이 보통이라 아직 넉넉해."), L("압력이 보통이라 아직 넉넉해요.")))
        case "높음": out.append(say(L("압력이 높아서 부족해지는 중이야. 안 쓰는 앱을 닫아 봐."), L("압력이 높아서 부족해지는 중이에요. 안 쓰는 앱을 닫아 보세요.")))
        default: out.append(say(L("압력이 매우 높아서 많이 부족해. 안 쓰는 앱을 닫아 줘."), L("압력이 매우 높아서 많이 부족해요. 안 쓰는 앱을 닫아 주세요.")))
        }
        return out
    }

    private func storage() -> String {
        guard let d = fact("저장 공간") else { return "" }
        let free = d.value.replacingOccurrences(of: " 남음", with: ""), total = d.detail?.replacingOccurrences(of: "전체 ", with: "")
        let of = total.map { L("전체 \($0) 중 ") } ?? ""
        switch diskFree ?? 1 {
        case ..<0.1: return say(L("저장 공간은 \(of)\(free)만 남아서 거의 꽉 찼어. 정리가 필요해."), L("저장 공간은 \(of)\(free)만 남아서 거의 꽉 찼어요. 정리가 필요해요."))
        case ..<0.2: return say(L("저장 공간은 \(of)\(free) 남아서 조금 빠듯해."), L("저장 공간은 \(of)\(free) 남아서 조금 빠듯해요."))
        default: return say(L("저장 공간은 \(of)\(free) 남아서 넉넉해."), L("저장 공간은 \(of)\(free) 남아서 넉넉해요."))
        }
    }

    private func batteryLines() -> [String] {
        guard let p = battery, let v = fact("배터리")?.value else { return [say(L("이 맥은 배터리가 없어."), L("이 맥은 배터리가 없어요."))] }
        if fact("배터리")?.detail == "충전 중" { return [say(L("배터리는 \(v)고 충전 중이야."), L("배터리는 \(v)이고 충전 중이에요."))] }
        // "충전해야 돼?": the yes or no first, then the number (measured 2026-10-04: "28% 남았어. 여유 있을 때 충전해 두면
        // 좋아" left the question unanswered).
        if !plugged, asks(["충전", "charg"]) {
            if p <= 20 { return [say(L("응, 지금 충전해 줘. 배터리가 \(v)밖에 안 남아서 곧 꺼질 수 있어."), L("네, 지금 충전해 주세요. 배터리가 \(v)밖에 안 남아서 곧 꺼질 수 있어요."))] }
            if p <= 40 { return [say(L("응, 지금 충전해 두는 게 좋아. 배터리가 \(v) 남았어."), L("네, 지금 충전해 두시는 게 좋아요. 배터리가 \(v) 남았어요."))] }
            return [say(L("아직 충전 안 해도 돼. 배터리가 \(v) 남았어."), L("아직 충전 안 하셔도 돼요. 배터리가 \(v) 남았어요."))]
        }
        var out = [plugged ? say(L("배터리는 \(v)고 전원에 연결돼 있어."), L("배터리는 \(v)이고 전원에 연결돼 있어요."))
                           : say(L("배터리는 \(v) 남았어."), L("배터리는 \(v) 남았어요."))]
        guard !plugged, p <= 20 || asks(["괜찮"]) else { return out }
        out.append(p <= 20 ? say(L("곧 꺼질 수 있으니 충전해 줘."), L("곧 꺼질 수 있으니 충전해 주세요."))
                   : p <= 40 ? say(L("여유 있을 때 충전해 두면 좋아."), L("여유 있을 때 충전해 두시면 좋아요."))
                   : say(L("아직 충전 안 해도 돼."), L("아직 충전 안 하셔도 돼요.")))
        return out
    }

    private func heat() -> String {
        switch fact("발열")?.value ?? "보통" {
        case "뜨거움", "아주 뜨거움": return say(L("맥이 뜨거워서 스스로 속도를 낮추는 중이야."), L("맥이 뜨거워서 스스로 속도를 낮추는 중이에요."))
        case "조금 따뜻함": return say(L("조금 따뜻하지만 걱정할 정도는 아니야."), L("조금 따뜻하지만 걱정할 정도는 아니에요."))
        default: return say(L("발열은 보통이라 괜찮아."), L("발열은 보통이라 괜찮아요."))
        }
    }

    /// The time on, and with `advise` whether to restart (one answer, not "필요 없어. … 재시동 해 봐").
    private func uptime(advise: Bool) -> [String] {
        guard let u = fact("켜진 지")?.value else { return [] }
        // "재부팅 해야 돼?": yes or no first, then the time on.
        if advise, asks(["해야", "할까", "필요", "should"]) {
            let since = say(L("켜진 지 \(u) 됐어."), L("켜진 지 \(u) 됐어요."))
            if uptimeDays >= 7 { return [say(L("응, 한 번 재시동하는 게 좋아."), L("네, 한 번 재시동하시는 게 좋아요.")), since] }
            if pressure != "보통" { return [say(L("응, 메모리가 빠듯해서 재시동하면 나아질 거야."), L("네, 메모리가 빠듯해서 재시동하시면 나아질 거예요.")), since] }
            return [say(L("아직 재시동은 안 해도 돼."), L("아직 재시동은 안 하셔도 돼요.")), since]
        }
        let tip: String
        if uptimeDays >= 7 { tip = say(L("오래 켜 뒀으니 한 번 재시동하면 좋아."), L("오래 켜 두셨으니 한 번 재시동하시면 좋아요.")) }
        else if pressure != "보통" { tip = say(L("메모리가 빠듯하니 재시동하면 나아질 거야."), L("메모리가 빠듯하니 재시동하시면 나아질 거예요.")) }
        else { tip = say(L("아직 재시동은 안 해도 돼."), L("아직 재시동은 안 하셔도 돼요.")) }
        return [say(L("켜진 지 \(u) 됐어."), L("켜진 지 \(u) 됐어요."))] + (advise ? [tip] : [])
    }

    // MARK: Whole picture

    /// What would make this Mac slow, worst first, each with its number.
    private var reasons: [String] {
        var out: [String] = []
        if let c = cpu, c >= 70 { out += cpuSentences(apps: true) }
        if pressure != "보통" { out.append(memory().joined(separator: " ")) }
        if let f = diskFree, f < 0.1 { out.append(storage()) }
        if ["뜨거움", "아주 뜨거움"].contains(fact("발열")?.value ?? "") { out.append(heat()) }
        return out
    }

    /// Low and not plugged in: said in the overview, not a reason for a slow Mac (measured 2026-10-04 at 19%: "왜 느려?"
    /// was answered with the battery alone, and "상태 어때?" said 배터리 19% twice).
    private var lowBattery: String? {
        guard let p = battery, p <= 20, fact("배터리")?.detail == nil, let v = fact("배터리")?.value else { return nil }
        return say(L("배터리가 \(v)밖에 안 남아서 충전이 필요해."), L("배터리가 \(v)밖에 안 남아서 충전이 필요해요."))
    }

    /// After a "괜찮아" verdict it is said as an aside (measured 2026-10-04: "전체적으로 괜찮아. … 재시동하면 나아질 수
    /// 있어" read as two verdicts).
    private func restartTip(aside: Bool) -> String? {
        guard uptimeDays >= 7, let u = fact("켜진 지")?.value else { return nil }
        let ra = Banmal.particle(u, "이라", "라")
        return aside ? say(L("다만 켜진 지 \(u)\(ra) 재시동하면 나아질 수 있어."), L("다만 켜진 지 \(u)\(ra) 재시동하면 나아질 수 있어요."))
                     : say(L("켜진 지 \(u)\(ra) 재시동하면 나아질 수 있어."), L("켜진 지 \(u)\(ra) 재시동하면 나아질 수 있어요."))
    }

    /// "왜 느려?": the reasons with their numbers, or the numbers that say there is none.
    private func slow() -> String {
        var out = reasons
        if out.isEmpty {
            out.append(say(L("지금 숫자로는 느릴 뚜렷한 이유가 없어."), L("지금 숫자로는 느릴 뚜렷한 이유가 없어요.")))
            if let c = fact("CPU")?.value, let m = fact("메모리")?.value {
                out.append(say(L("CPU는 \(c), 메모리는 \(m)를 쓰는 중이라 둘 다 여유 있어."), L("CPU는 \(c), 메모리는 \(m)를 쓰는 중이라 둘 다 여유 있어요.")))
            }
        }
        if let tip = restartTip(aside: reasons.isEmpty) { out.append(tip) }
        return out.joined(separator: " ")
    }

    /// "내 컴퓨터 상태 어때?": the verdict, then the main numbers.
    private func overview() -> String {
        var out = [reasons.first ?? lowBattery ?? say(L("지금 전체적으로 괜찮아."), L("지금 전체적으로 괜찮아요."))]
        var parts: [String] = []
        if let v = fact("CPU")?.value { parts.append("CPU \(v)") }
        if let v = fact("메모리")?.value { parts.append(L("메모리 \(v)")) }
        if let v = fact("저장 공간")?.value { parts.append(L("남은 저장 공간 \(v.replacingOccurrences(of: " 남음", with: ""))")) }
        if let v = fact("배터리")?.value, !out[0].contains(v) { parts.append(L("배터리 \(v)")) }   // said once
        if !parts.isEmpty { let list = parts.joined(separator: ", "); out.append(list + be(list) + ".") }
        if let tip = restartTip(aside: reasons.isEmpty && lowBattery == nil) { out.append(tip) }
        return out.joined(separator: " ")
    }
}
