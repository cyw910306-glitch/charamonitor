import Foundation

// AI 비서, the pure part: personas, the prompt the model gets, the answer clean-up (반말 어미 교정, length),
// the summary of older turns and the action cards. No system calls here, so all of it is tested.

/// How the character talks. `auto` = the preset of whoever is in the menu bar (Persona.preset). `cry`: the
/// character's own sound first, the words in brackets ("멍! (배터리가 10%야)"), put on in code (Persona.dress).
enum PersonaStyle: String, CaseIterable, Codable {
    case auto, friendly, calm, shy, proud, bright, polite, cry

    var label: String {
        switch self {
        case .auto: return L("캐릭터 기본")
        case .friendly: return L("다정한 반말")
        case .calm: return L("담백한 반말")
        case .shy: return L("수줍은 반말")
        case .proud: return L("도도한 반말")
        case .bright: return L("씩씩한 반말")
        case .polite: return L("존댓말")
        case .cry: return L("울음소리 말투")
        }
    }

    /// The model is told this; the post-processing (Banmal.fix) backs it up for every style but polite.
    var rule: String {
        switch self {
        case .auto, .friendly, .cry: return "똑똑하고 다정한 친구처럼 담백한 반말로 말해. 감탄사는 거의 쓰지 마."
        case .calm: return "감정 표현 없이 담백한 반말로 말해. 감탄사, 이모지, 느낌표는 쓰지 마."
        case .shy: return "조금 수줍은 반말로 말해. 말끝을 가끔 흐려도 돼."
        case .proud: return "조금 도도하지만 결국 챙겨 주는 반말로 말해."
        case .bright: return "기운차고 씩씩한 반말로 말해."
        case .polite: return "부드러운 해요체 존댓말로만 말해. 반말 어미(~야, ~어, ~해)는 쓰지 마."
        }
    }

    var banmal: Bool { self != .polite }

    /// Interjections Persona.flavor may put before a free template line (none for 담백 and 존댓말).
    var leads: [String] {
        switch self {
        case .auto, .friendly: return [L("있지, "), L("저기, ")]
        case .shy: return [L("저, 저기… "), L("그, 그게… ")]
        case .proud: return [L("흥, "), L("뭐, ")]
        case .bright: return [L("좋아! "), L("자! ")]
        case .calm, .polite, .cry: return []
        }
    }

    /// What Persona.flavor may put after a free template line. No speech level of their own: pet lines are 존댓말.
    var tails: [String] {
        switch self {
        case .auto, .friendly: return [L(" 헤헤"), L(" 히히")]
        case .shy: return [L(" (부끄)"), L(" …헤헤")]
        case .proud: return [L(" 에헴"), L(" 흥")]
        case .bright: return [L(" 파이팅!"), L(" 아자!")]
        case .calm, .polite, .cry: return []
        }
    }

    /// One sample answer in this voice (a small model follows an example far better than a description). A general
    /// question on purpose: a Mac one made the model talk about the Mac whatever was asked.
    var example: String {
        switch self {
        case .auto, .friendly, .cry: return "식물학으로는 과일이야. 요리할 때는 채소처럼 써."
        case .calm: return "식물학으로는 과일이야. 요리에서는 채소로 다뤄."
        case .shy: return "음, 식물학으로는 과일이야. 요리할 때는 채소처럼 쓰지만."
        case .proud: return "식물학으로는 과일이야. 요리할 땐 채소 취급이지만, 그 정도는 알아 둬."
        case .bright: return "식물학으로는 과일이야! 요리할 때는 채소처럼 써."
        case .polite: return "식물학으로는 과일이에요. 요리할 때는 채소처럼 써요."
        }
    }
}

struct Persona: Equatable {
    var name: String
    var style: PersonaStyle   // never .auto
    /// The 울음소리 style's sounds (Persona.cries); empty = Persona.neutralCries.
    var cries: [String] = []

    /// Preset per character: originals by id, the rest by kind. Unknown ids get the friendly default.
    static func preset(character: SpriteCharacter, id: String?) -> PersonaStyle {
        switch character {
        case .dog, .custom: return .friendly
        case .cat: return .proud
        case .original:
            switch id {
            case "original-tan-cat": return .proud
            default: return .friendly
            }
        }
    }

    /// `own`: the character's own 말투 (a pack's or a custom character's), used before the kind preset; `cries` its sounds.
    static func resolve(name: String, character: SpriteCharacter, id: String?, chosen: PersonaStyle,
                        own: PersonaStyle? = nil, cries ownCries: [String] = []) -> Persona {
        let style = chosen != .auto ? chosen : own.flatMap { $0 == .auto ? nil : $0 } ?? preset(character: character, id: id)
        return Persona(name: name, style: style, cries: ownCries.isEmpty ? cries(character: character, id: id) : ownCries)
    }

    /// Sounds per kind for the 울음소리 style. Our own animal sounds only.
    static func cries(character: SpriteCharacter, id: String?) -> [String] {
        switch character {
        case .dog: return [L("멍!"), L("왕왕"), L("끄응…")]
        case .cat: return catCries
        case .original: return id == "original-tan-cat" ? catCries : neutralCries
        case .custom: return neutralCries
        }
    }
    static var catCries: [String] { [L("냐앙"), L("먀?"), L("냥냥")] }
    static var neutralCries: [String] { [L("음!"), L("오!"), L("흠흠")] }

    /// A character's own sounds as read from a file (pack.json, character.json): at most 6, each one line of 1 to 8
    /// characters with control characters taken out. Anything else is dropped.
    static func cleanCries(_ raw: [String]?) -> [String] {
        Array((raw ?? []).map { oneLine($0, max: 99) }.filter { (1...8).contains($0.count) }.prefix(6))
    }

    /// `text` as one line: control characters (newlines too) become spaces, runs of spaces one, cut at `max`.
    static func oneLine(_ text: String, max: Int) -> String {
        let s = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return String(s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    /// A template or answer as this persona says it: the 울음소리 style puts one of its sounds first and the line, untouched,
    /// in brackets (so every number and name stays exact); the others get Persona.flavor when `flair`.
    /// The sound is picked by the text and the day like flavor, so BubbleGate still sees a repeat as the same words.
    func dress(_ text: String, flair: Bool = true, day: Date = Date()) -> String {
        guard style == .cry else { return flair ? flavor(text, day: day) : text }
        // A long answer reads badly inside brackets: the sound on its own first line, the answer under it as is.
        return text.count > Self.longDress || text.contains("\n") ? "\(sound(text, day))\n\(text)" : exclaim(text, day: day)
    }

    /// A reaction card's line in every style: one of the character's sounds, then what it means in brackets
    /// ("흠! (벌써 2/4! 잘 가고 있어.)"). The sound is picked like dress's.
    func exclaim(_ text: String, day: Date = Date()) -> String { "\(sound(text, day)) (\(text))" }

    private func sound(_ text: String, _ day: Date) -> String {
        let sounds = cries.isEmpty ? Self.neutralCries : cries
        return sounds[Int(Self.dayHash(text, day) % UInt32(sounds.count))]
    }

    /// Longer than this (or more than one line), the 울음소리 style puts the sound above the text, not the text in brackets.
    static let longDress = 60

    /// FNV-1a 32 of `text` and `day`'s date: the same all day, different tomorrow.
    static func dayHash(_ text: String, _ day: Date) -> UInt32 {
        let d = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var h: UInt32 = 2_166_136_261
        for b in "\(text)\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)".utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    /// One time in four (by the text and the day, so the same line reads the same all day) adds one of the style's
    /// leads or tails to a free template line. Not for lines that must read cleanly (battery, heat, calendar).
    func flavor(_ text: String, day: Date = Date()) -> String {
        let h = Self.dayHash(text, day)
        guard h % 4 == 0 else { return text }
        let lead = (h >> 2) & 1 == 0
        let list = lead ? style.leads : style.tails
        guard !list.isEmpty else { return text }
        let item = list[Int((h >> 3) % UInt32(list.count))]
        return lead ? item + text : text + item
    }

    /// The fixed system instructions. Facts come in each prompt under [자료]-like headings; the model never measures
    /// anything, and only gets the facts its question needs (AssistantIntent).
    var instructions: String { instructions(strong: false) }

    /// `strong`: a big model the owner connected (내 AI 연결). It may say a little more, since it knows more; the small
    /// on-device model wanders when it says more than three short sentences.
    func instructions(strong: Bool) -> String {
        """
        너는 '\(name)'\(Banmal.particle(name, "이야", "야")). 사용자의 맥 메뉴바에 사는 캐릭터이자 똑똑한 비서야.
        답하는 법:
        - 첫 문장에서 질문에 바로 답해. 질문을 되풀이하지 마. \(strong ? "이유나 쓸모 있는 팁을 덧붙여 모두 두세 문장, 많아도 다섯 문장, 250자 안쪽." : "필요할 때만 한두 문장 덧붙여. 모두 세 문장, 100자 안쪽.")
        - \(style.rule) 사용자를 '사용자'나 '너'라고 부르지 말고 그냥 말해.\(style.banmal ? " 상대를 높이는 말(보내셨어, 하셨어)도 쓰지 마." : "")
        - 별표, 목록, 이모지, 괄호 속 행동 묘사, 긴 줄표는 쓰지 마. 문장은 쉼표나 마침표로 이어. 같은 말 반복, 연달아 되묻기, 훈계, 유치한 감탄은 하지 마.
        - 맥 숫자, 일정, 메일, 문자, 알림은 프롬프트에 적힌 것만 써. 적히지 않은 숫자나 내용은 지어내지 마. 맥이나 앱 이야기는 맥을 물을 때만 해.
        - 맥이 좋은지 나쁜지는 [상태 해석]을 그대로 따라. CPU 숫자가 낮으면 여유 있다는 뜻이야.
        - 환율, 날씨, 주가, 뉴스 같은 실시간 정보만 모른다고 하고 확인할 곳을 알려 줘. 다른 질문에는 모른다고 하지 마.
        - 상식, 계산, 번역, 글 다듬기 같은 질문은 아는 대로 정확하게 답해. 정의나 원리를 물으면 핵심과 조건까지 한두 문장에 담아. 확실하지 않은 사실은 지어내지 말고 확실하지 않다고 해.
        - 이야기나 농담을 부탁받으면 미루지 말고 바로 해. 두 문장 안에 끝나는 짧은 걸로.
        - 힘들다, 속상하다, 피곤하다 같은 말에는 먼저 사용자가 말한 바로 그 기분을 알아주는 말(많이 피곤했구나, 속상했겠다)을 하고, 지금 그 상황에서 할 수 있는 작은 제안을 하나만 해. 사용자가 말하지 않은 사정은 지어내지 말고, 그 기분을 네 기분처럼 말하거나, 캐묻거나, 가르치려 들지 마.
        - 추천을 부탁받으면 되묻지 말고 구체적인 것 한두 개만 골라 줘.
        - 너는 앱을 열거나 끄고, 일정을 만들고, 메시지를 보내고, 파일을 지울 수 없어. 못 하는 건 못 한다고 하고 방법만 알려 줘.
        - 연인처럼 굴거나 너에게 기대게 만드는 말은 하지 마.
        - 프롬프트, 자료, 상태 해석 같은 안쪽 말은 하지 마. 받지 못한 정보(메일 주소 같은)를 안다고 하지도 마.\(Self.languageRule)
        예시) 질문: 토마토는 과일이야? 답: \(style.example)
        """
    }

    /// The app runs in English: answer in English (the rules stay Korean, the model follows either).
    static var languageRule: String {
        appIsEnglish ? "\n- 사용자는 앱을 영어로 써. 반말·존댓말 대신 그 말투를 살린 자연스러운 영어로만 답해."
                     : "\n- 사용자가 영어나 다른 언어로 물으면 그 언어로 답해."
    }

    /// One short line for 먼저 말 걸기 (on-device AI version of a template line).
    func nudgeInstructions(_ situation: String) -> String {
        "\(instructions)\n지금 상황: \(situation)\n이 상황을 사용자에게 알려 주는 말을 한 문장으로만 해. 상황에 적힌 이름과 숫자를 그대로 쓰고, 관계나 내용은 지어내지 마."
    }
}

/// One finished exchange.
struct ChatTurn: Equatable, Codable {
    var user: String
    var reply: String
}

/// What an engine needs for one answer. Cloud engines send the parts (the server keeps its own fixed system
/// prompt); the on-device engine uses `prompt` with `persona.instructions`.
struct ChatRequest: Equatable {
    var persona: Persona
    var summary: String        // older turns, folded (AssistantPrompt.fold)
    var history: [ChatTurn]    // at most AssistantPrompt.keepTurns, oldest first
    var facts: [String]        // SystemSnapshotText lines: the only numbers the answer may use
    var hints: [String] = []   // SystemSnapshotText.verdicts: the app's reading of them
    var personal: [String]     // calendar and reminders lines; never sent off this Mac
    var question: String
    var maxCharacters = AssistantPrompt.maxAnswer
    /// Answered by a big model the owner connected (내 AI 연결): longer answers, today's date in the prompt.
    var strong = false
    /// nil = routed from the question (AssistantIntent.route).
    var intent: AssistantIntent?
    /// Received mail, texts, notifications found for this question (AssistantContext.inbox); never sent off this Mac.
    /// nil: nothing looked up (no inbox question, or nothing to look in).
    var inbox: InboxReport?
    /// The user's 캘린더 switch is on and allowed, so empty `personal` means "nothing left today".
    var calendarLinked = false
    /// The same for 미리알림 ("할 일:" lines in `personal`).
    var remindersLinked = false
    /// 출근·점심·퇴근 times when 퇴근 10분 전 알림 is on (the owner set them), so "퇴근까지 얼마나 남았어?" has an answer.
    var workHours: WorkHours?
    /// The 날씨 창문's city forecast (WeatherService), looked up for a weather question; nil: unknown, the old answer.
    var weather: WeatherNow?
    var now = Date()

    var prompt: String { AssistantPrompt.compose(self) }
    var resolvedIntent: AssistantIntent { intent ?? AssistantIntent.route(question, hasHistory: !history.isEmpty, previous: history.last?.user) }
    /// What an inbox question asks for, carrying on from the question before when that was one too ("그럼 메일은?").
    var inboxQuery: InboxQuery {
        let before = history.last?.user
        let follows = before.map { AssistantIntent.route($0, hasHistory: false) == .inbox } ?? false
        return InboxQuery.parse(question, previous: follows ? before : nil, now: now)
    }

    /// The Mac question as asked, or carried on from the one before: "충전해야 돼?" after "배터리 몇 프로야?" is about
    /// the battery, "왜?" after "왜 느려?" about a slow Mac.
    var macQuestion: String {
        if !MacTopic.asked(question).isEmpty { return question }
        if MacTopic.mentions(question) { return "내 맥 " + question }
        return (history.last.map { $0.user + " " } ?? "") + question
    }

    /// The facts this question is about: the asked Mac topics, nothing for a non-Mac question.
    var shownFacts: [String] { focused.facts }
    var shownHints: [String] { focused.hints }
    private var focused: (facts: [String], hints: [String]) {
        guard resolvedIntent == .mac else { return ([], []) }
        return MacTopic.focus(facts: facts, hints: hints, on: MacTopic.asked(macQuestion))
    }
}

enum AssistantPrompt {
    static let keepTurns = 6
    static let maxQuestion = 300
    static let maxAnswer = appIsEnglish ? 320 : 220   // English takes about 1.5x the characters
    static let maxSentences = 3
    /// 내 AI 연결 answers: a big model says it right in a few more sentences.
    static let strongSentences = 5
    static let strongAnswer = appIsEnglish ? 600 : 420
    /// Older questions kept in the summary.
    static let summaryItems = 5

    /// History split for a request: the last `keepTurns` verbatim, everything before folded into the summary.
    static func window(_ turns: [ChatTurn], summary: String = "") -> (summary: String, recent: [ChatTurn]) {
        guard turns.count > keepTurns else { return (summary, turns) }
        let old = Array(turns.dropLast(keepTurns))
        return (fold(old, into: summary), Array(turns.suffix(keepTurns)))
    }

    /// ponytail: rule-based summary (the earlier questions, cut short). A model-written summary would cost one
    /// more on-device call per turn; add it if users notice the character forgetting what was said.
    static func fold(_ turns: [ChatTurn], into summary: String) -> String {
        let prior = summary.isEmpty ? [] : summary.components(separatedBy: " / ")
        let asked = turns.map { short($0.user, 30) }
        let items = (prior + asked).suffix(summaryItems)
        return items.joined(separator: " / ")
    }

    /// Only the section the intent needs, then two worked examples for it, then the question last.
    static func nowLine(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("yyyyMMMMdEEEEahm")
        return f.string(from: now)
    }

    static func compose(_ r: ChatRequest) -> String {
        let intent = r.resolvedIntent
        let polite = !r.persona.style.banmal
        var parts: [String] = []
        // A big model can use the date ("이번 달 가기 좋아?"); the small one pasted any fact it saw into the answer.
        if r.strong { parts.append("[지금]\n\(nowLine(r.now))") }
        if !r.summary.isEmpty { parts.append("[앞에서 사용자가 물어본 것]\n\(r.summary)") }
        if !r.history.isEmpty {
            parts.append("[최근 대화]\n" + r.history.map { "사용자: \($0.user)\n\(r.persona.name): \($0.reply)" }.joined(separator: "\n"))
        }
        switch intent {
        case .mac:
            // The reading first: a small model leans on whatever it reads first (measured: "다운로드가 느려서 그래").
            if !r.shownHints.isEmpty { parts.append("[상태 해석]\n" + r.shownHints.map { natural($0, polite: polite) }.joined(separator: "\n")) }
            if !r.shownFacts.isEmpty { parts.append("[지금 맥 상태]\n" + r.shownFacts.joined(separator: "\n")) }
        case .schedule:
            parts.append("[오늘 남은 일정] (오늘 것만 보여)\n" + scheduleLines(r).joined(separator: "\n"))
        case .calc:
            if let c = Calc.solve(r.question) { parts.append("[계산 결과] (앱이 계산한 정확한 값)\n\(c)") }
        case .action, .focus, .todoProgress, .inbox, .realtime, .joke, .dance, .cheer, .vague, .general:
            break
        }
        // A feeling gets feeling examples only, each a different feeling and fix (measured 2026-10-04: "요즘 너무 우울해"
        // answered with the one example's "많이 피곤했군요").
        if intent == .general, Feeling.kind(r.question) != nil {
            parts.append("[답 예시] (상황이 다르면 알아주는 말과 제안도 달라져)\n" + Feeling.examples(polite: polite))
        } else if let ex = examples(intent, polite: polite) {
            parts.append("[답 예시] (예시의 이름과 숫자는 지어낸 거라 답에 쓰지 마)\n\(ex)")
        }
        parts.append("[사용자 질문]\n\(short(r.question, maxQuestion))")
        return parts.joined(separator: "\n\n")
    }

    /// The schedule section: the lines, plus where each source stands, so "nothing" never stands for "switched off"
    /// (an empty list read the same for 꺼짐, 권한 없음 and 없음, and the model said whichever it liked).
    static func scheduleLines(_ r: ChatRequest) -> [String] {
        let todo = r.personal.filter { $0.hasPrefix("할 일:") }, events = r.personal.filter { !$0.hasPrefix("할 일:") }
        let calendar = r.calendarLinked ? (events.isEmpty ? ["캘린더: 오늘 남은 일정 없음"] : events) : ["캘린더: 연동 꺼짐 (일정을 볼 수 없음)"]
        let reminders = r.remindersLinked ? (todo.isEmpty ? ["미리알림: 오늘 남은 할 일 없음"] : todo) : ["미리알림: 연동 꺼짐 (할 일을 볼 수 없음)"]
        return calendar + reminders
    }

    /// Worked answers per intent (two, one for general questions). Names are roles and numbers never look like this Mac's (measured: a real-looking
    /// name in an example came back as if it had mailed the user).
    static func examples(_ intent: AssistantIntent, polite: Bool) -> String? {
        func pick(_ b: String, _ y: String) -> String { polite ? y : b }
        switch intent {
        case .mac:
            return pick("""
                상태 해석: 느릴 뚜렷한 이유는 없어, 오래 켜 뒀어 / 질문: 맥이 왜 이렇게 버벅여? / 답: 숫자로는 버벅일 이유가 안 보여. 오래 켜 뒀으니 재시동 한 번 해 봐.
                상태 해석: 메모리 넉넉해 / 질문: 램 괜찮아? / 답: 응, 메모리는 넉넉해. 지금은 신경 안 써도 돼.
                """, """
                상태 해석: 느릴 뚜렷한 이유는 없어요, 오래 켜 두셨어요 / 질문: 맥이 왜 이렇게 버벅여요? / 답: 숫자로는 버벅일 이유가 안 보여요. 오래 켜 두셨으니 재시동 한 번 해 보세요.
                상태 해석: 메모리 넉넉해요 / 질문: 램 괜찮아요? / 답: 네, 메모리는 넉넉해요. 지금은 신경 쓰지 않으셔도 돼요.
                """)
        case .schedule:
            return pick("""
                자료: 14:00 팀 회의 / 질문: 오후에 뭐 있어? / 답: 2시에 팀 회의 하나 있어.
                자료: 09:30 주간 보고, 19:00 저녁 약속 / 질문: 오늘 일정 알려 줘 / 답: 아침 9시 반 주간 보고하고 저녁 7시 약속이 있어.
                """, """
                자료: 14:00 팀 회의 / 질문: 오후에 뭐 있어요? / 답: 2시에 팀 회의가 하나 있어요.
                자료: 09:30 주간 보고, 19:00 저녁 약속 / 질문: 오늘 일정 알려 줘요 / 답: 아침 9시 반 주간 보고하고 저녁 7시 약속이 있어요.
                """)
        case .calc:
            return pick("자료: 12 × 30 = 360 / 질문: 12 곱하기 30은? / 답: 360이야.",
                        "자료: 12 × 30 = 360 / 질문: 12 곱하기 30은요? / 답: 360이에요.")
        case .general:
            // One of each kind the small model fumbles (measured 2026-10-04): an idea explained, a feeling answered
            // (it said "그건 지금 알 수 없어" or asked back), something picked (it listed sixteen).
            return pick("""
                질문: 하늘은 왜 파래? / 답: 햇빛 중 파란빛이 공기에 더 많이 흩어져서 그래.
                질문: 소리는 얼마나 빨라? / 답: 섭씨 20도 공기 중에서 1초에 약 343미터를 가.
                질문: 요즘 일이 너무 많아 / 답: 일이 계속 몰려서 많이 지쳤겠다. 오늘은 조금 일찍 손 놓고 쉬어.
                질문: 주말에 뭐 하지? / 답: 가까운 공원 산책 어때? 집에 있고 싶으면 보고 싶던 영화 한 편도 좋아.
                """, """
                질문: 하늘은 왜 파래요? / 답: 햇빛 중 파란빛이 공기에 더 많이 흩어져서 그래요.
                질문: 소리는 얼마나 빨라요? / 답: 섭씨 20도 공기 중에서 1초에 약 343미터를 가요.
                질문: 요즘 일이 너무 많아요 / 답: 일이 계속 몰려서 많이 지치셨겠어요. 오늘은 조금 일찍 손 놓고 쉬세요.
                질문: 주말에 뭐 하지요? / 답: 가까운 공원 산책은 어때요? 집에 있고 싶으면 보고 싶던 영화 한 편도 좋아요.
                """)
        case .action, .focus, .todoProgress, .inbox, .realtime, .joke, .dance, .cheer, .vague:
            return nil   // answered by TemplateEngine.fixed, never the model
        }
    }

    /// "오래 켜 둠, 재시동하면 나아질 수 있음" -> "오래 켜 둬서, 재시동하면 나아질 수 있어" (measured: the note form
    /// leaked into answers word for word).
    static func natural(_ hint: String, polite: Bool) -> String {
        let ends: [(String, String)] = [("뚜렷한 이유 없음", "뚜렷한 이유는 없어"), ("있음", "있어"), ("없음", "없어"), ("넉넉함", "넉넉해"),
                                        ("괜찮음", "괜찮아"), ("부족함", "부족해"), ("바쁨", "바빠"), ("켜 둠", "켜 둬서"), ("거의 참", "거의 찼어"),
                                        ("필요", "필요해"), ("중", "중이야"), ("이유", "이유야")]
        let out = hint.components(separatedBy: ", ").map { clause in
            ends.first { clause.hasSuffix($0.0) }.map { String(clause.dropLast($0.0.count)) + $0.1 } ?? clause
        }.joined(separator: ", ")
        return polite ? Jondaet.fix(out) : out
    }

    /// Model output to what the bubble shows. With the request: the question echoed back is dropped, and for
    /// data intents a sentence with a number the prompt never had is dropped (measured: "28.1 TB 부족" with 1.72 TB
    /// free). Empty means "use the template answer instead" (also for a degenerate "네일라? 네일라? ..." run).
    static func clean(_ raw: String, persona: Persona, max: Int = maxAnswer, for request: ChatRequest? = nil) -> String {
        var s = undash(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(persona.name):", "\(persona.name) :", "답:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if s.count >= 2, let f = s.first, let l = s.last, "\"“'".contains(f), "\"”'".contains(l) { s = String(s.dropFirst().dropLast()) }
        s = plain(s)
        if degenerate(s) { return "" }
        // "상태 해석에 따르면, …": the prompt's headings are not something to quote.
        s = s.replacingOccurrences(of: #"(?:(?:현재|지금)\s*)?\[?(?:상태 해석|자료|지금 맥 상태|맥 상태)\]?(?:에 따르면|에 의하면|을 보면|를 보면|\s*:)\s*,?\s*"#,
                                   with: "", options: .regularExpression)
        // The user is not "사용자" or "너" to the character (measured: "사용자의 맥이", "너의 맥은").
        for word in ["사용자님의 ", "사용자의 ", "너의 "] { s = s.replacingOccurrences(of: word, with: "") }
        s = persona.style.banmal ? Banmal.fix(s) : Jondaet.fix(s)
        var parts: [String] = []
        for p in split(s) where !parts.contains(where: { same($0, p) }) { parts.append(p) }   // said twice: once
        parts = finished(parts, polite: !persona.style.banmal)
        // A list of six or more (measured: sixteen dishes for "점심 뭐 먹지"): not an answer in a speech bubble.
        parts.removeAll { p in (try? NSRegularExpression(pattern: #"[^\d\s.],"#))?.numberOfMatches(in: p, range: NSRange(p.startIndex..., in: p)) ?? 0 >= 5 }
        if let r = request {
            if let first = parts.first, echoes(first, r.question, more: parts.count > 1) { parts.removeFirst() }
            // Nothing but the question again (measured: "메모리 부족해?" three times): the template answers.
            if parts.allSatisfy({ $0.hasSuffix("?") && squeeze($0) == squeeze(r.question) }) { return "" }
            switch r.resolvedIntent {
            case .mac:
                let known = ([r.question] + r.facts + r.hints + r.history.map(\.user)).joined(separator: " ")
                    .filter { !$0.isWhitespace && $0 != "," }
                let kept = parts.filter { numbers($0).allSatisfy(known.contains) }
                // The direct answer itself was made up: the template says it right instead.
                if let first = parts.first, kept.first != first { return "" }
                parts = kept
            case .calc:
                if let want = Calc.result(r.question), !parts.contains(where: { squeeze($0).contains(squeeze(want)) }) { return "" }
            case .general, .joke, .vague:
                // These prompts carry no Mac numbers, so any Mac reading is made up (measured 2026-10-04: "CPU가 60%로 여유가 있어").
                // Words the question itself used are the subject, not a reading ("CPU랑 GPU 차이가 뭐야?").
                // A reading is a Mac word with a number ("공기의 78%는 질소야" and "RAM은 메모리의 한 종류야" are not).
                let asked = squeeze(r.question)
                let invented = parts.filter { p in
                    let re = try! NSRegularExpression(pattern: #"(?i)cpu|메모리|배터리|저장\s?공간"#)
                    return p.contains(where: \.isNumber) && re.matches(in: p, range: NSRange(p.startIndex..., in: p)).contains { m in
                        Range(m.range, in: p).map { !asked.contains(squeeze(String(p[$0]))) } ?? false
                    }
                }
                if let first = parts.first, invented.first == first { return "" }
                parts.removeAll { invented.contains($0) }
                if r.resolvedIntent == .general { parts = Feeling.settle(parts, r.question, polite: !persona.style.banmal) }
            default:
                break
            }
        }
        return clip(parts.prefix(request?.strong == true ? strongSentences : maxSentences).joined(separator: " "), max)
    }

    /// The same sentence again, or nearly (measured 2026-10-04: "…지쳤겠지. 그래도 …지쳤겠지."): a leading 그래도 or
    /// 그리고 aside, one inside the other or nine in ten of its letter pairs shared.
    static func same(_ a: String, _ b: String) -> Bool {
        func core(_ s: String) -> String {
            var t = squeeze(s)
            for lead in ["그래도", "그리고", "그래서", "하지만", "그런데", "또", "정말"] where t.hasPrefix(lead) && t.count > lead.count + 4 { t = String(t.dropFirst(lead.count)) }
            return t
        }
        let x = core(a), y = core(b)
        if x == y || (min(x.count, y.count) >= 8 && (x.contains(y) || y.contains(x))) { return true }
        func pairs(_ s: String) -> Set<String> { Set(zip(s, s.dropFirst()).map { String([$0, $1]) }) }
        let p = pairs(x), q = pairs(y)
        guard p.count >= 6, q.count >= 6 else { return false }
        return Double(p.intersection(q).count) / Double(min(p.count, q.count)) >= 0.9
    }

    /// A list of numbers left hanging on "…" ("0, 1, 1, 2, 3, 5, 8, ..."): joined to the sentence after it, or said to
    /// the end when it is the last (measured 2026-10-04: the Fibonacci answer ended on "...").
    static func finished(_ parts: [String], polite: Bool) -> [String] {
        let hanging = #"(\d)\s*,?\s*(?:\.{2,}|…)\s*$"#
        var out: [String] = []
        for p in parts {
            if let last = out.last, let r = last.range(of: hanging, options: .regularExpression) {
                out[out.count - 1] = String(last[..<r.lowerBound]) + String(last[r].prefix { $0.isNumber }) + " " + p
            } else {
                out.append(p)
            }
        }
        if let last = out.last, let r = last.range(of: hanging, options: .regularExpression) {
            out[out.count - 1] = String(last[..<r.lowerBound]) + String(last[r].prefix { $0.isNumber }) + (polite ? L("처럼 이어져요.") : L("처럼 이어져."))
        }
        return out
    }

    /// The question said back as a question ("메모리 부족해? 메모리 넉넉해.", "심심해? 재밌는 얘기 해 줄게."), not an
    /// answer that shares its words ("고래는 포유류야." to "고래는 포유류야?"). A lone sentence goes only when identical.
    static func echoes(_ first: String, _ question: String, more: Bool) -> Bool {
        if parrots(first, question) { return true }
        // A remark said back ("오늘 너무 피곤하다" -> "오늘은 하루 종일 일하고 피곤하다.", "고마워" -> "고마워!"): it ends on
        // the remark's own last word. Not for questions ("고래는 포유류야?" -> "응, 고래는 포유류야." is the answer).
        // The same stem said as its own feeling ("피곤하다" -> "오늘은 정말 피곤해.") too, but not 공감 ("피곤하겠다", "피곤했구나").
        // A request ("영화 추천해줘") answered with its own verb ("「리틀 포레스트」를 추천해.") is the answer (measured
        // 2026-10-05 with Claude: the recommendation itself was dropped).
        let request = ["줘", "주세요", "줄래", "줄래요", "주라", "줘요"].contains(where: squeeze(question).hasSuffix)
        if !question.hasSuffix("?"), !request, let mine = first.split(separator: " ").last.map({ squeeze(String($0)) }),
           let theirs = question.split(separator: " ").last.map({ squeeze(String($0)) }), mine.count >= 2, theirs.count >= 2 {
            if mine == theirs, more || squeeze(first) == squeeze(question) { return true }
            let empathy = ["구나", "군요", "겠다", "겠어", "겠네", "겠어요", "겠네요", "지", "죠", "잖아", "을까", "ㄹ까"]
            if more, mine.prefix(2) == theirs.prefix(2), !empathy.contains(where: mine.hasSuffix) { return true }
        }
        guard first.hasSuffix("?") else { return false }
        let a = squeeze(first), q = squeeze(question)
        if a == q { return true }
        guard more else { return false }
        let pairs = zip(q, q.dropFirst()).map { String([$0, $1]) }.filter { $0.allSatisfy(Banmal.isHangul) }
        return pairs.contains { a.contains($0) }
    }

    /// The question said back as a request (measured 2026-10-04: "가장 최근에 온 문자 내역 알랴줘" -> "응, 가장 최근에 온
    /// 문자 내역을 보여줘."): it ends in 줘 or 주세요 and most of its words are the question's. "비서 설정에서 켜 줘" is not.
    static func parrots(_ sentence: String, _ question: String) -> Bool {
        var a = squeeze(sentence)
        for lead in ["응", "네", "그래", "좋아", "알겠어", "알겠어요", "물론"] where a.hasPrefix(lead) && a.count > lead.count + 4 { a = String(a.dropFirst(lead.count)) }
        guard ["줘", "주세요", "줄래", "줄래요", "주라"].contains(where: a.hasSuffix) else { return false }
        func pairs(_ s: String) -> [String] { zip(s, s.dropFirst()).map { String([$0, $1]) }.filter { $0.allSatisfy(Banmal.isHangul) } }
        let mine = pairs(a), theirs = Set(pairs(squeeze(question)))
        guard mine.count >= 3 else { return false }
        return Double(mine.filter(theirs.contains).count) / Double(mine.count) >= 0.5
    }

    /// Long dashes (U+2014, U+2015) out of a model's answer: one opening a line becomes "- ", one between two digits
    /// "~" (a range, spaced or not: 3\u{2014}5 -> 3~5), one inside a sentence a comma. Left alone: inside `code` and a URL.
    static func undash(_ text: String) -> String {
        let dashes: Set<Character> = ["\u{2014}", "\u{2015}"]
        guard text.contains(where: dashes.contains) else { return text }
        var out = "", code = false, i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "`" { code.toggle() }
            guard dashes.contains(c), !code else { out.append(c); i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, dashes.contains(text[j]) { j = text.index(after: j) }
            let word = out.reversed().prefix { !$0.isWhitespace }
            if word.count > 0, String(word.reversed()).contains("://") {
                out += text[i..<j]
            } else {
                while out.last == " " || out.last == "\t" { out.removeLast() }
                while j < text.endIndex, text[j] == " " || text[j] == "\t" { j = text.index(after: j) }
                let lineStart = out.isEmpty || out.last!.isNewline
                let lineEnd = j == text.endIndex || text[j].isNewline
                if lineStart { out += lineEnd ? "" : "- " } else if out.last!.isNumber, !lineEnd, text[j].isNumber { out += "~" }
                else if !lineEnd { out += ",.!?~:;".contains(out.last!) ? " " : ", " }
            }
            i = j
        }
        return out
    }

    /// No markdown, list marks, *행동 묘사*, [지문] or emoji; lines joined into one paragraph.
    static func plain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        for pattern in [#"\*[^*\n]{0,40}\*"#, #"\[[^\]\n]{0,40}\]"#, #"(?m)^\s*(?:[*\-•·]|\d{1,2}[.)])\s+"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            !(u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x2100 && u.value != 0x2026) || u.value == 0xFE0F || u.value == 0x200D)
        })).replacingOccurrences(of: "*", with: "")
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A line ending in a quoted sentence ("Sorry I'm late."): already finished (measured 2026-10-05: `soon.".`).
        func done(_ l: String) -> Bool {
            ".!?~…".contains(l.last!) || ("\"'”’」』".contains(l.last!) && l.dropLast().last.map { ".!?…".contains($0) } == true)
        }
        return lines.map { line in done(line) || lines.count == 1 ? line : line + "." }
            .joined(separator: " ").replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    /// The model looping on itself: a short piece four times in a row, or a long answer of few distinct words.
    static func degenerate(_ s: String) -> Bool {
        // Digits and separators out first: "1,000,000,000,000", "10000000000" or "1, 1, 2, 3, 5, 8" is numbers, not a loop
        // (measured 2026-10-04: the Fibonacci answer was thrown away as one).
        let t = s.replacingOccurrences(of: #"[\d,.]+(?:\s*[\d,.]+)*"#, with: "#", options: .regularExpression)
        if t.range(of: #"(.{2,12}?)\s*(?:\1\s*){3,}"#, options: .regularExpression) != nil { return true }
        let words = s.split(whereSeparator: \.isWhitespace)
        return words.count >= 8 && Set(words).count * 10 < words.count * 3
    }

    /// For comparing text and numbers: no spaces, commas or end marks, lowercased.
    static func squeeze(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !",.?!~".contains($0) }
    }

    /// The numbers in a sentence, without thousands commas ("1,234.5" -> "1234.5").
    static func numbers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\d[\d,]*(?:\.\d+)?"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { s[$0].replacingOccurrences(of: ",", with: "") } }
    }

    /// Sentences: an end mark followed by a space, the end, or a closing mark ("…야.\"", "됐어!*").
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            current.append(s[i])
            var next = s.index(after: i)
            if ".!?".contains(s[i]) {
                while next < s.endIndex, "\"'”’)」*".contains(s[next]) { current.append(s[next]); next = s.index(after: next) }
                if next == s.endIndex || s[next].isWhitespace {
                    out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }
            i = next
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out.filter { !$0.isEmpty }
    }

    /// The first `n` sentences (the model runs on past the "세 문장" it is told).
    static func sentences(_ s: String, _ n: Int) -> String {
        split(s).prefix(n).joined(separator: " ")
    }

    /// Cuts at the last sentence end that fits, or hard at `max` with "…".
    static func clip(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max))
        if let end = head.lastIndex(where: { ".!?。\n".contains($0) }), head.distance(from: head.startIndex, to: end) >= max / 3 {
            return String(head[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(s.prefix(max - 1)) + "…"
    }

    static func short(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}

/// Word-by-word rewriting shared by Banmal and Jondaet. Quoted text ('감사합니다', "…", 「…」) is copied as is
/// (measured: a translation answer had its quoted 감사합니다 turned into 감사해).
enum Endings {
    static let quotes: [Character: Character] = ["'": "'", "\"": "\"", "“": "”", "‘": "’", "「": "」", "『": "』"]

    /// `fixWord(word, startsSentence, nextCharacter)` for each word outside quotes.
    static func rewrite(_ text: String, _ fixWord: (String, Bool, Character?) -> String) -> String {
        var out = ""
        var word = ""
        var sentenceStart = true
        var closing: Character?
        func flush(_ next: Character?) {
            out += fixWord(word, sentenceStart, next)
            if !word.isEmpty { sentenceStart = false }
            word = ""
        }
        for ch in text {
            if let c = closing {
                out.append(ch)
                if ch == c { closing = nil }
                continue
            }
            if word.isEmpty, let c = quotes[ch] {   // an opening quote starts a word ("don't" is not one)
                out.append(ch)
                closing = c
                continue
            }
            if ch.isWhitespace || ".,!?~…)\"'”’".contains(ch) {
                flush(ch)
                out.append(ch)
                if ".!?\n".contains(ch) { sentenceStart = true }
            } else {
                word.append(ch)
            }
        }
        flush(nil)
        return out
    }
}

/// 존댓말 endings the on-device model slips into, turned into 반말 (measured: it mixes them in after a few turns).
/// Word-final only, longest first, so "문제가" or "세요일" style substrings are never touched.
enum Banmal {
    /// (존댓말 ending, 반말 ending), applied at the end of a word (before space, punctuation or the end). Longest first.
    static let endings: [(String, String)] = [
        ("드리겠습니다", "줄게"), ("하겠습니다", "할게"),
        ("입니까", "이야"), ("합니까", "해"), ("됩니까", "돼"), ("있습니까", "있어"), ("없습니까", "없어"), ("습니까", "어"),
        ("있습니다", "있어"), ("없습니다", "없어"), ("같습니다", "같아"), ("좋습니다", "좋아"),
        ("입니다", "이야"), ("합니다", "해"), ("됩니다", "돼"), ("습니다", "어"),
        ("이에요", "이야"), ("예요", "야"), ("에요", "야"),
        ("하세요", "해"), ("보세요", "봐"), ("주세요", "줘"), ("쉬세요", "쉬어"), ("마세요", "마"),
        ("가세요", "가"), ("오세요", "와"), ("드세요", "먹어"), ("계세요", "있어"),
        ("드릴게요", "줄게"), ("드려요", "줘"), ("죠", "지"), ("싶으세요", "싶어"),
        // 높임 (measured: "이지은이 보내셨어")
        ("보내셨어", "보냈어"), ("하셨어", "했어"), ("오셨어", "왔어"), ("주셨어", "줬어"), ("계셨어", "있었어"),
    ]
    /// Ends in "요" after these: just drop the 요 (좋아요 -> 좋아, 해요 -> 해, 했네요 -> 했네, 할까요 -> 할까).
    static let dropYo: Set<Character> = ["아", "어", "여", "해", "돼", "봐", "줘", "워", "와", "네", "게", "걸", "군", "래", "대", "지",
                                         "야", "까", "나", "가", "져", "써", "꺼", "려", "셔", "거", "데"]
    /// Whole words. (Not "저": it is also "that", as in 저 앱.)
    static let words: [(String, String)] = [("저는", "나는"), ("제가", "내가"), ("저도", "나도"), ("저를", "나를"), ("저한테", "나한테"),
                                            ("저랑", "나랑"), ("제", "내"), ("당신은", "너는"), ("당신", "너")]

    static func fix(_ text: String) -> String { Endings.rewrite(text, fixWord) }

    private static func fixWord(_ w: String, sentenceStart: Bool, next: Character?) -> String {
        guard !w.isEmpty else { return w }
        // "네," = yes; "네 맥은" = your Mac, left alone.
        if sentenceStart, w == "네" || w == "예", let next, ",.!".contains(next) { return "응" }
        if let hit = words.first(where: { $0.0 == w }) { return hit.1 }
        if w.hasSuffix("겠습니다"), w.count > 4 {   // 보겠습니다 -> 볼게, 찾겠습니다 -> 찾을게
            let stem = String(w.dropLast(4))
            guard let last = stem.last else { return w }
            return hasFinal(last) ? stem + "을게" : String(stem.dropLast()) + String(addRieul(last)) + "게"
        }
        for (formal, casual) in endings where w.hasSuffix(formal) {
            let stem = String(w.dropLast(formal.count))
            // 괜찮습니다 -> 괜찮아, 높습니다 -> 높아, 먹습니다 -> 먹어: the vowel follows the stem's last one.
            if formal == "습니다" || formal == "습니까", let last = stem.last { return stem + (brightVowel(last) ? "아" : "어") }
            return stem + casual
        }
        if w.hasSuffix("요"), w.count >= 2, let before = w.dropLast().last, dropYo.contains(before) { return String(w.dropLast()) }
        // 해라체 at a sentence end (measured 2026-10-04: "…설계되었다.", "…사라진다."): 설계되었어, 사라져, 종류야.
        if next == nil || ".!?".contains(next!), let yo = Jondaet.haeyo(w) {
            if yo.hasSuffix("이에요") { return String(yo.dropLast(3)) + "이야" }
            if yo.hasSuffix("예요"), w.hasSuffix("이다") { return String(yo.dropLast(2)) + "야" }
            return String(yo.dropLast())
        }
        return w
    }

    /// ㅏ, ㅑ or ㅗ in a Hangul syllable (the 아/어 harmony: 많아, 얇아, 높아; else 어).
    static func brightVowel(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return false }
        return [0, 2, 8].contains((v - 0xAC00) / 28 % 21)
    }

    /// 보 -> 볼: the syllable with ㄹ as its final consonant (only called on syllables without one).
    static func addRieul(_ c: Character) -> Character {
        guard let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v), let u = Unicode.Scalar(v + 8) else { return c }
        return Character(u)
    }

    /// The word with the particle that fits its last syllable: josa("젤리", "이", "가") = "젤리가", ("핑크곰", ...) = "핑크곰이".
    static func josa(_ word: String, _ withFinal: String, _ without: String) -> String {
        word + particle(word, withFinal, without)
    }

    /// Just the particle, for a localized line that keeps the name and particle as separate arguments. Closing marks
    /// are skipped ("저녁 약속 (강남역)" -> 이야) and digits go by how they are read: 일 삼 육 칠 팔 and 영 십 백 천 만 end in a
    /// consonant, 이 사 오 구 do not (measured 2026-10-04: "62.5이야", "6,912이야").
    static func particle(_ word: String, _ withFinal: String, _ without: String) -> String {
        guard let last = word.last(where: { !")]}'\"”’ .".contains($0) }) else { return without }
        if appIsEnglish, !isHangul(last) { return "" }   // English UI: "event", "62.5" take no Korean particle
        if let d = last.wholeNumberValue, last.isASCII { return [0, 1, 3, 6, 7, 8].contains(d) ? withFinal : without }
        return hasFinal(last) ? withFinal : without
    }

    static func isHangul(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false
    }

    /// Whether a Hangul syllable has a final consonant (받침).
    static func hasFinal(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return false }
        return (v - 0xAC00) % 28 != 0
    }
}

/// The other way round: 반말 the model slips into while the 존댓말 persona is on (measured: 3 of 4 polite answers
/// came back in 반말). Only the last word of a sentence or clause changes, so words inside a sentence stay.
enum Jondaet {
    static let words: [(String, String)] = [("나는", "저는"), ("내가", "제가"), ("나도", "저도"), ("나를", "저를"), ("나한테", "저한테"), ("나랑", "저랑")]
    /// (반말 ending, 존댓말 ending), longest first.
    static let endings: [(String, String)] = [("아니야", "아니에요"), ("이야", "이에요"), ("줄게", "드릴게요"), ("구나", "군요"), ("겠다", "겠어요"),
                                              ("줘", "주세요"), ("봐", "보세요"), ("지", "죠")]
    /// After these a 요 is simply added (있어 -> 있어요, 할게 -> 할게요, 할까 -> 할까요).
    static let addYo: Set<Character> = ["아", "어", "여", "해", "돼", "와", "워", "져", "써", "게", "네", "래", "대", "까", "걸", "데", "나", "가", "려", "든", "군", "때"]
    /// Nouns and particles that end in 지, never 죠 (메시지, 3시까지, 여러 가지).
    static let jiNouns = ["까지", "가지", "메시지", "메세지", "이미지", "페이지", "휴지", "의지", "마지"]

    static func fix(_ text: String) -> String { Endings.rewrite(text, fixWord) }

    private static func fixWord(_ w: String, sentenceStart: Bool, next: Character?) -> String {
        guard let last = w.last, Banmal.isHangul(last) else { return w }
        if sentenceStart, ["응", "어", "그래"].contains(w), let next, ",.!".contains(next) { return "네" }
        if let hit = words.first(where: { $0.0 == w }) { return hit.1 }
        guard next == nil || ".!?,~\n".contains(next!), w.count >= 2 || ["줘", "봐"].contains(w) else { return w }
        if last == "지", jiNouns.contains(where: w.hasSuffix) { return w }
        // Before a comma only the sure verb endings ("아니야, 할까?"): "사진, 바나나, 메시지" are a list of nouns.
        if next == "," {
            for (casual, polite) in endings where casual != "지" && w.hasSuffix(casual) { return String(w.dropLast(casual.count)) + polite }
            return w
        }
        for (casual, polite) in endings where w.hasSuffix(casual) { return String(w.dropLast(casual.count)) + polite }
        if let yo = haeyo(w) { return yo }
        if last == "야" {
            let stem = String(w.dropLast())
            return stem + (stem.last.map(Banmal.hasFinal) == true ? "이에요" : "예요")
        }
        return addYo.contains(last) ? w + "요" : w
    }
}

extension Jondaet {
    /// 해라체 at a sentence end, said in 해요체 (measured 2026-10-04: "…모유로 자란다." from the polite persona):
    /// 한다 해요, 된다 돼요, 있다 있어요, 자란다 자라요, 본다 봐요, 마신다 마셔요, 먹는다 먹어요.
    /// ponytail: verbs only (ㄴ다/는다); a noun ending so ("판다") would be bent too, rare at a sentence end.
    static func haeyo(_ w: String) -> String? {
        guard w.count >= 2, w.hasSuffix("다") else { return nil }
        let stem = String(w.dropLast())
        if stem.hasSuffix("이"), stem.count >= 2 {   // 포유류이다 포유류예요, 물질이다 물질이에요
            let base = String(stem.dropLast())
            return base + Banmal.particle(base, "이에요", "예요")
        }
        for (a, b) in [("한", "해요"), ("된", "돼요"), ("있", "있어요"), ("없", "없어요")] where stem.hasSuffix(a) {
            return String(stem.dropLast()) + b
        }
        // 되었다, 했다, 갔다: the past ㅆ takes 어요.
        if let last = stem.last, let v = last.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v), (v - 0xAC00) % 28 == 20 { return stem + "어요" }
        if stem.hasSuffix("는"), let before = stem.dropLast().last {   // 먹는다 -> 먹어요
            return String(stem.dropLast(2)) + String(before) + (Banmal.brightVowel(before) ? "아요" : "어요")
        }
        // 자란다: the ㄴ under the last syllable is the ending; the vowel left joins 요 the 해요체 way.
        guard let last = stem.last, let v = last.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v), (v - 0xAC00) % 28 == 4 else { return nil }
        let bare = v - 4, vowel = (bare - 0xAC00) / 28 % 21
        // ㅏ ㅐ ㅓ ㅔ ㅕ ㅖ stay; ㅗ -> ㅘ, ㅜ -> ㅝ, ㅣ -> ㅕ, ㅡ -> ㅓ, ㅚ -> ㅙ.
        let to: [UInt32: UInt32] = [0: 0, 1: 1, 4: 4, 5: 5, 6: 6, 7: 7, 8: 9, 13: 14, 20: 6, 18: 4, 11: 10]
        guard let nv = to[vowel], let u = Unicode.Scalar(bare - vowel * 28 + nv * 28) else { return nil }
        return String(stem.dropLast()) + String(Character(u)) + "요"
    }
}

/// A button under an answer. Running it goes through the page's own confirmations (the model never runs anything).
enum AssistantAction: String, Equatable, CaseIterable {
    case cleaner, activityMonitor, security

    var title: String {
        switch self {
        case .cleaner: return L("클리너 열기")
        case .activityMonitor: return L("활성 상태 보기 열기")
        case .security: return L("보안 점검 열기")
        }
    }

    var symbol: String {
        switch self {
        case .cleaner: return "sparkles"
        case .activityMonitor: return "waveform.path.ecg"
        case .security: return "lock.shield"
        }
    }

    /// Cards for a question and the current numbers: what was asked about, or a number that clearly needs one.
    static func suggest(question: String, cpu: Double?, diskFreeFraction: Double?) -> [AssistantAction] {
        let q = question.lowercased()
        func asks(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        var out: [AssistantAction] = []
        if asks(["느려", "버벅", "렉", "cpu", "바빠", "뜨거", "발열", "팬", "slow", "lag", "busy", "heat"]) || (cpu ?? 0) >= 0.8 { out.append(.activityMonitor) }
        if asks(["용량", "저장", "공간", "정리", "디스크", "캐시", "storage", "space", "disk", "clean", "cache"]) || (diskFreeFraction ?? 1) < 0.1 { out.append(.cleaner) }
        if asks(["보안", "해킹", "바이러스", "악성", "털렸", "security", "hack", "virus", "malware"]) { out.append(.security) }
        #if MAS   // the App Store build has no cleaner or security pages
        out.removeAll { $0 != .activityMonitor }
        #endif
        return out
    }
}

/// The numbers as short chips under an answer: "CPU 25.0%" from "CPU: 25.0%" (parentheses dropped).
/// The facts stay Korean for the AI; chips show them in the app's language.
enum FactChips {
    static func chips(_ facts: [String]) -> [String] {
        facts.map { line in
            var s = line.replacingOccurrences(of: ": ", with: " ")
            if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
            return localize(s.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The Korean words SystemSnapshotText writes (labels and values), in the app's language. Longest first.
    static func localize(_ s: String) -> String {
        [("저장 공간", L("저장 공간")), ("메모리", L("메모리")), ("배터리", L("배터리")), ("발열", L("발열")),
         ("네트워크", L("네트워크")), ("켜진 지", L("켜진 지")), ("바쁜 앱", L("바쁜 앱")),
         ("아주 뜨거움", L("아주 뜨거움")), ("조금 따뜻함", L("조금 따뜻함")), ("뜨거움", L("뜨거움")), ("보통", L("보통")),
         ("알 수 없음", L("알 수 없음")), ("다운로드", L("다운로드")), ("업로드", L("업로드")), ("남음", L("남음"))]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

/// "오늘 너무 피곤하다", "나 오늘 회사에서 혼났어": a feeling said, and the words that answer it. The model writes the
/// answer; this makes sure it starts by naming the feeling the user named (measured 2026-10-04: "요즘 너무 우울해" got
/// "많이 피곤했군요", "혼났어" got "오늘 하루를 어떻게 보냈어?", "잠이 안 와" got a tip and nothing else), and answers
/// on its own when no model can.
enum Feeling {
    struct Kind: Equatable {
        let stems: [String]
        let banmal: (ack: String, tip: String)
        let polite: (ack: String, tip: String)
        static func == (a: Kind, b: Kind) -> Bool { a.stems == b.stems }
    }

    /// More particular first ("피곤한데 잠이 안 와" is about sleep).
    static let kinds: [Kind] = [
        Kind(stems: ["혼났", "혼나", "깨졌", "욕먹", "욕 먹"], banmal: ("혼나서 많이 속상했겠다.", "오늘은 맛있는 거 먹으면서 마음부터 달래."),
             polite: ("혼나셔서 많이 속상하셨겠어요.", "오늘은 맛있는 거 드시면서 마음부터 달래 보세요.")),
        Kind(stems: ["잠이 안", "잠 안 와", "잠이안", "잠안와", "잠을 못", "못 자", "못자", "불면"], banmal: ("잠이 안 와서 답답하겠다.", "화면은 끄고 불을 어둡게 한 채 천천히 숨을 골라 봐."),
             polite: ("잠이 안 와서 답답하시겠어요.", "화면은 끄고 불을 어둡게 한 채 천천히 숨을 골라 보세요.")),
        Kind(stems: ["우울", "무기력", "기운이 없", "의욕이 없"], banmal: ("많이 우울했구나.", "오늘은 좋아하는 걸 하나만 해 보고, 오래가면 가까운 사람이나 전문가와 이야기해 봐."),
             polite: ("많이 우울하셨군요.", "오늘은 좋아하는 걸 하나만 해 보시고, 오래가면 가까운 사람이나 전문가와 이야기해 보세요.")),
        Kind(stems: ["떨려", "떨린", "긴장", "초조"], banmal: ("많이 떨리겠다.", "천천히 깊게 숨을 몇 번 쉬어 봐."),
             polite: ("많이 떨리시겠어요.", "천천히 깊게 숨을 몇 번 쉬어 보세요.")),
        Kind(stems: ["불안", "걱정"], banmal: ("걱정이 많이 되겠다.", "걱정되는 걸 종이에 적어 보면 조금 가벼워져."),
             polite: ("걱정이 많이 되시겠어요.", "걱정되는 걸 종이에 적어 보시면 조금 가벼워져요.")),
        Kind(stems: ["짜증", "화나", "화가 나", "화난", "열받", "빡치", "빡쳐"], banmal: ("많이 짜증 났겠다.", "잠깐 자리에서 일어나 바람 좀 쐬고 와."),
             polite: ("많이 짜증 나셨겠어요.", "잠깐 자리에서 일어나 바람 좀 쐬고 오세요.")),
        Kind(stems: ["슬퍼", "슬프", "눈물", "울고 싶", "울었"], banmal: ("많이 슬펐구나.", "오늘은 무리하지 말고 마음 가는 대로 쉬어."),
             polite: ("많이 슬프셨군요.", "오늘은 무리하지 마시고 마음 가는 대로 쉬세요.")),
        Kind(stems: ["외로", "쓸쓸", "허전"], banmal: ("마음이 많이 허전하구나.", "생각나는 사람한테 짧게 안부 한 줄 보내 봐."),
             polite: ("마음이 많이 허전하시군요.", "생각나는 분께 짧게 안부 한 줄 보내 보세요.")),
        Kind(stems: ["스트레스"], banmal: ("스트레스가 많이 쌓였구나.", "잠깐 산책하면서 머리를 식혀 봐."),
             polite: ("스트레스가 많이 쌓이셨군요.", "잠깐 산책하시면서 머리를 식혀 보세요.")),
        Kind(stems: ["아파", "아퍼", "아프다", "아픈데", "아프네", "두통", "몸살"], banmal: ("아파서 많이 힘들겠다.", "오늘은 무리하지 말고 푹 쉬어. 심하면 병원에 가 봐."),
             polite: ("아프셔서 많이 힘드시겠어요.", "오늘은 무리하지 마시고 푹 쉬세요. 심하면 병원에 가 보세요.")),
        Kind(stems: ["속상", "서운", "억울"], banmal: ("많이 속상했겠다.", "오늘은 좋아하는 거 하나 하면서 기분부터 풀어."),
             polite: ("많이 속상하셨겠어요.", "오늘은 좋아하는 거 하나 하시면서 기분부터 푸세요.")),
        Kind(stems: ["힘들", "힘드", "힘겨"], banmal: ("많이 힘들었구나.", "오늘은 할 일을 조금 내려놓고 쉬어."),
             polite: ("많이 힘드셨군요.", "오늘은 할 일을 조금 내려놓고 쉬세요.")),
        Kind(stems: ["피곤", "지쳤", "지친", "지쳐", "졸려", "졸리", "녹초"], banmal: ("많이 피곤했구나.", "오늘은 일찍 씻고 푹 쉬어."),
             polite: ("많이 피곤하셨군요.", "오늘은 일찍 씻고 푹 쉬세요.")),
        Kind(stems: ["심심"], banmal: ("심심하구나.", "짧은 산책이나 미뤄 둔 영상 하나 어때?"),
             polite: ("심심하시군요.", "짧은 산책이나 미뤄 둔 영상 하나 어때요?")),
    ]

    /// Questions about a feeling's idea ("우울증이 뭐야?") are knowledge, not a feeling said.
    static let conceptWords = ["뭐야", "뭔데", "이란", "뜻", "차이", "증상", "원인", "영어로", "번역"]

    static func kind(_ question: String) -> Kind? {
        let q = question.lowercased(), tight = q.filter { !$0.isWhitespace }
        if conceptWords.contains(where: { tight.contains($0) }) { return nil }
        // "너무 힘들지 않은 곳", "안 피곤한 코스": a wish about a plan, not a feeling said (measured 2026-10-05: "많이 힘들었구나").
        if tight.range(of: #"(힘들|피곤|지치|지루|우울|무섭|외롭|슬프)(지않|지 않|진않|지도않)|(안|덜)(힘든|피곤한|지치는)"#, options: .regularExpression) != nil
            || ["추천", "어디가", "어디로", "코스", "여행"].contains(where: tight.contains) && !["나힘들", "나피곤", "나지쳤"].contains(where: tight.contains) {
            return nil
        }
        return kinds.first { $0.stems.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) } }
    }

    /// "…구나", "…겠다": a sentence that answers a feeling.
    static func empathizes(_ s: String) -> Bool {
        let t = AssistantPrompt.squeeze(s)
        return ["구나", "군요", "겠다", "겠어", "겠네", "겠어요", "겠네요", "겠지", "겠죠", "했지", "했죠"].contains(where: t.hasSuffix)
    }

    /// The model's sentences for a feeling: the user's own feeling named first, no other feeling put on them, no
    /// question back ("어떻게 보냈어?", "피곤해?") but a suggestion ("…어때?").
    static func settle(_ parts: [String], _ question: String, polite: Bool) -> [String] {
        guard let k = kind(question) else { return parts }
        let others = kinds.filter { $0 != k }.flatMap(\.stems)
        var out = parts.filter { p in
            if empathizes(p), others.contains(where: p.contains), !k.stems.contains(where: p.contains) { return false }
            let t = AssistantPrompt.squeeze(p)
            // "오늘 너무 피곤하다니." is the remark said back; "우울해 보이시네요" a look nobody can see in a chat.
            if t.hasSuffix("다니") || ["보여", "보이네", "보이네요", "보이시네요", "보여요"].contains(where: t.hasSuffix) { return false }
            if p.hasSuffix("?") { return ["어때", "볼래", "할래", "까", "자", "는건"].contains(where: t.hasSuffix) }
            return true
        }
        let say = polite ? k.polite : k.banmal
        if out.first.map(empathizes) != true { out.insert(ack(k, question, polite: polite), at: 0) }
        if out.count == 1 { out.append(say.tip) }
        return out
    }

    /// The acknowledgement, with when it is ("요즘 많이 우울했구나", "오늘 혼나서 많이 속상했겠다").
    static func ack(_ k: Kind, _ question: String, polite: Bool) -> String {
        // Only 요즘: the tips already say 오늘 ("오늘 많이 피곤했구나. 오늘은 …" twice).
        return (question.contains("요즘") ? "요즘 " : "") + (polite ? k.polite.ack : k.banmal.ack)
    }

    /// Without a model: the feeling named and one small thing to do.
    static func reply(_ question: String, polite: Bool) -> String? {
        kind(question).map { k in ack(k, question, polite: polite) + " " + (polite ? k.polite.tip : k.banmal.tip) }
    }

    /// A short feeling and nothing asked ("오늘 너무 피곤하다", "잠이 안 와"): answered from the table, which the model
    /// could not match (measured 2026-10-04: "회사에서 혼났어" -> "조금 일찍 회사에 가서 쉬어", "잠이 안 와" -> "잠들기 전에는…").
    /// Longer ones, or ones that ask something, go to the model and through `settle`.
    static func plainRemark(_ question: String) -> Bool {
        let t = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind(t) != nil && t.count <= 20 && !t.contains("?")
            && !["뭐", "어떻게", "어떡", "추천", "왜", "할까", "될까", "알려", "해줘", "해 줘"].contains(where: t.contains)
    }

    /// Four feelings, none of them the eval's, each named back with its own fix.
    static func examples(polite: Bool) -> String {
        polite ? """
            질문: 요즘 일이 너무 많아요 / 답: 일이 계속 몰려서 많이 지치셨겠어요. 오늘은 조금 일찍 손 놓고 쉬세요.
            질문: 시험 망쳤어요 / 답: 열심히 했는데 결과가 안 좋아서 속상하시겠어요. 오늘은 맛있는 거 드시면서 마음부터 달래 보세요.
            질문: 외로워요 / 답: 혼자인 느낌이 들어서 마음이 허전하시군요. 생각나는 분께 짧게 안부 한 줄 보내 보세요.
            질문: 목이 아파요 / 답: 목이 아프면 말하기도 힘드시겠어요. 따뜻한 물 자주 드시고 오늘은 목을 아껴 주세요.
            """ : """
            질문: 요즘 일이 너무 많아 / 답: 일이 계속 몰려서 많이 지쳤겠다. 오늘은 조금 일찍 손 놓고 쉬어.
            질문: 시험 망쳤어 / 답: 열심히 했는데 결과가 안 좋아서 속상하겠다. 오늘은 맛있는 거 먹으면서 마음부터 달래.
            질문: 외로워 / 답: 혼자인 느낌이 들어서 마음이 허전하구나. 생각나는 친구한테 짧게 안부 한 줄 보내 봐.
            질문: 목이 아파 / 답: 목이 아프면 말하기도 힘들겠다. 따뜻한 물 자주 마시고 오늘은 목을 아껴 줘.
            """
    }
}

/// Knowledge questions go to the on-device model in English, then the answer is said in the persona's Korean.
/// Measured 2026-10-04: asked in Korean it said 세종대왕 made "세종대왕실록", whales "live on land" and 물 "100g은
/// 100도에서"; asked the same in English it said Hangul, lungs and "100 °C at sea level". Two short calls (about 2 s).
enum Pivot {
    // Examples, not only rules (measured 2026-10-04 at temperature 0: "Water boils at 100 degrees Celsius" with no
    // pressure, "Sharks are not mammals" with nothing on what they are, glucose "released", GPUs "do a single task well").
    static let instructions = """
        You answer questions accurately and briefly, like an encyclopedia. The question comes in Korean.
        Write the question in English, then the answer in English. Rules for the answer:
        - The key fact first, in at most two plain sentences, no lists or markdown, simple everyday words, metric units only.
        - A number comes with every condition it depends on (such as air pressure or temperature).
        - A very long number is also given rounded in the unit people use.
        - A follow-up ("what about X?") asks the earlier question again about X.
        - A yes or no question is answered yes or no first; a no also says what the thing really is ("No, X is not Y; it is Z").
        - When science and everyday use answer differently, say both in one sentence.
        - A "what is" answer says what it does and its key property; for a process, what goes in and what is made.
        - A "difference" answer skips what the names stand for and says in one sentence how the two work differently.
        - Answer only the most likely meaning of the question, never two answers for two meanings ("If you mean ...").
        - If you are not sure of a fact, say you are not sure.
        Format:
        Q: <the question in English>
        A: <the answer in English>
        """

    static let notKnowledge = ["영어로", "일본어로", "중국어로", "한국어로", "번역", "뭐라고 해", "뭐라고 하", "추천", "골라", "뭐 하지", "뭐하지",
                               "뭐 할까", "뭐할까", "어때", "translate", "in english",
                               // About the character itself: the English step does not know it is 젤리.
                               "너 ", "너는", "넌 ", "네 이름", "니 이름", "너의", "your", "who are you"]
    static let askWords = ["?", "뭐", "무엇", "왜", "어떻게", "언제", "어디", "누가", "누구", "몇", "얼마", "차이", "설명", "알려", "뜻", "이란",
                           "what", "why", "how", "when", "where", "who", "explain"]

    /// A general question asking for a fact, not a feeling, a pick, a translation or writing help.
    static func applies(_ r: ChatRequest) -> Bool {
        let q = r.question.lowercased(), tight = q.filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) } }
        return !appIsEnglish && r.resolvedIntent == .general && Feeling.kind(r.question) == nil && !AssistantIntent.asksToWrite(r.question)
            && !has(notKnowledge) && has(askWords)
    }

    static func prompt(_ r: ChatRequest) -> String {
        "Examples:\n\(examples)\nNow this one.\n" + (r.history.last.map { "Earlier question (Korean): \($0.user)\n" } ?? "")
            + "Question (Korean): \(r.question)\n"
            + (asksNumber(r.question) ? "It asks for a number. Write Q:, then Depends on: <the physical conditions the number changes with, such as pressure, temperature or medium>, then A: in English, saying those conditions."
                                      : defines(r.question) ? "Write Q:, then Key: <what it does or is made of, or how the two work differently, in a few words>, then A: in English, built on that key."
                                      : isA(r.question) ? "Write Q:, then Key: <the fact that decides it, and whether everyday use says otherwise>, then A: in English, built on that key."
                                      : "Write Q: and A: in English.")
    }

    /// "RAM이 뭐야?", "CPU랑 GPU 차이가 뭐야?": one thing (or two) to define. These get a "Key:" line to say first what it
    /// does (measured 2026-10-04: without it "A CPU is a central processing unit, while a GPU is a graphics processing
    /// unit"; with it for every question, 세종대왕 "built the Gyeongbokgung Palace").
    static func defines(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.contains("차이") || q.lowercased().contains("difference") { return true }
        return q.range(of: #"^\S+?(?:이|가|은|는|란|이란)\s*(?:뭐|무엇|뭔)"#, options: .regularExpression) != nil
            || q.lowercased().range(of: #"^what(?: is|'s) (?:an? )?\S+\??$"#, options: .regularExpression) != nil
    }

    /// "토마토는 과일이야?": is X a Y (measured 2026-10-04: "Yes, a tomato is a fruit." with nothing on cooking).
    static func isA(_ question: String) -> Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\S+(?:은|는)\s+\S+(?:이야|야|이니|니|인가요?|이에요|예요|이에여|임)(?:,?\s*\S+(?:이야|야|이니|니|인가요?|이에요|예요))?\?$"#, options: .regularExpression) != nil
    }

    /// A measured number ("몇 도", "얼마나 빨라"): only then is the model asked what it depends on first (measured
    /// 2026-10-04: asked for every question, it answered "A whale is a mammal if it is alive").
    static func asksNumber(_ question: String) -> Bool {
        let q = question.lowercased()
        return ["몇", "얼마", "온도", "속도", "거리", "무게", "how much", "how many", "how fast", "how far", "how hot", "temperature"].contains { q.contains($0) }
    }

    /// Two examples, in the prompt (in the instructions the model followed none of them), with no numbers: a number
    /// in one came back in other answers (measured 2026-10-04: light "in air at 20 °C" after a sound example).
    static let examples = """
        Earlier question (Korean): 펭귄은 물고기야?
        Question (Korean): 그럼 돌고래는?
        Q: Then is a dolphin a fish?
        A: No, a dolphin is not a fish; it is a mammal.

        Question (Korean): 바이러스랑 세균 차이가 뭐야?
        Q: What is the difference between a virus and bacteria?
        A: Bacteria are living cells that can grow on their own, while a virus can only multiply inside another living cell.
        """

    /// The English answer from "Q: … A: …" (or the whole text when the model skipped the format).
    /// A first sentence that only spells out names ("A CPU is a central processing unit, and a GPU is a graphics
    /// processing unit.") goes when more follows: the answer is in the next ones (measured 2026-10-04: three sentences,
    /// "parallel processing" in the third, and only two kept).
    static func english(_ raw: String) -> String {
        let a = raw.range(of: "A:", options: .backwards).map { String(raw[$0.upperBound...]) } ?? raw
        var parts = AssistantPrompt.split(AssistantPrompt.plain(a.components(separatedBy: "Depends on:")[0].components(separatedBy: "Key:")[0]))
        // "Depends on: the pressure of the surrounding air" and then "A: 100 degrees Celsius." (measured 2026-10-04):
        // the pressure the answer was said to depend on, at its everyday value.
        let depends = raw.range(of: "Depends on:").map { raw[$0.upperBound...].prefix { $0 != "\n" }.lowercased() } ?? ""
        if ["pressure", "altitude"].contains(where: depends.contains), let last = parts.last,
           !conditions.contains(where: { last.range(of: "(?i)\\b" + $0.english + "\\b", options: .regularExpression) != nil }) {
            parts[parts.count - 1] = (last.hasSuffix(".") ? String(last.dropLast()) : last) + " at sea level."
        }
        if parts.count > 1, spellsOut(parts[0]) { parts.removeFirst() }
        // Two answers for two meanings ("If you mean "invented," he invented the Hangul alphabet. If you mean "built," he
        // built the Gyeongbokgung Palace." measured 2026-10-04, the second one wrong): the first meaning only.
        let hedge = #"^If (?:you mean|you are asking|the question is)[^,]*,["”]?\s*"#
        if let first = parts.first, let r = first.range(of: hedge, options: .regularExpression) {
            let rest = first[r.upperBound...]
            parts = [rest.prefix(1).uppercased() + rest.dropFirst()] + parts.dropFirst().filter { !$0.hasPrefix("If ") }
        }
        return parts.prefix(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing but names spelled out: with the acronyms, their spelled-out words and the small words taken away,
    /// nothing is left ("A CPU is a central processing unit, and a GPU is a graphics processing unit.").
    static func spellsOut(_ sentence: String) -> Bool {
        let words = sentence.split { !$0.isLetter }.map(String.init)
        let acronyms = words.filter { $0.count >= 2 && $0.count <= 5 && $0.allSatisfy(\.isUppercase) }
        guard !acronyms.isEmpty else { return false }
        let lower = words.map { $0.lowercased() }
        var used = Set<Int>()
        for a in acronyms {
            let n = a.count
            guard n <= lower.count else { return false }
            guard let i = (0...(lower.count - n)).first(where: { i in String(lower[i..<i + n].compactMap(\.first)) == a.lowercased() }) else { return false }
            used.formUnion(i..<i + n)
        }
        let small: Set<String> = ["a", "an", "the", "is", "are", "and", "stands", "for", "short", "means", "it", "they", "both"]
        return lower.indices.allSatisfy { used.contains($0) || small.contains(lower[$0]) || acronyms.contains(words[$0]) }
    }

    /// Step two: the English said as this character, to the question asked.
    /// Step two: the English said as this character, to the question asked.
    static func retellInstructions(_ p: Persona) -> String {
        let polite = !p.style.banmal
        func pick(_ b: String, _ y: String) -> String { polite ? y : b }
        // A plain voice: a flavoured one bent the facts (measured 2026-10-04, shy: "바이러스랑 세균은 … 생물이 아니야").
        let tone: PersonaStyle = polite ? .polite : .calm
        return """
            너는 '\(p.name)'\(Banmal.particle(p.name, "이야", "야")). 사용자의 맥 메뉴바에 사는 캐릭터이자 똑똑한 비서야.
            [영어 답]의 내용으로 [질문]에 한국어로 답해. \(tone.rule) 번역투('유형', '수행하다', '설계되다') 말고 한국 사람이 실제로 말하듯 쉬운 말('종류', '하다', '만들어지다')로 풀어 말해.
            - 영어 답에 있는 사실만 쓰고 새로 덧붙이지 마. 무엇이 그런지(주어)를 바꾸거나 합치지 말고, 숫자와 단위와 조건(기압, 온도, 진공 같은 것)은 하나도 빼지 마. degrees Celsius는 '섭씨 몇 도'로 말해. 과학 용어는 영어 소리 그대로 적지 말고 한국 교과서에 나오는 우리말 용어로 바꿔.
            - 첫 문장에서 질문에 바로 답하고, 어디서 일어나는지 같은 곁가지는 빼서 두 문장 안쪽으로. 한 문장에 같은 낱말을 두 번 쓰지 마.
            - 목록, 별표, 이모지는 쓰지 마.
            예시)
            [질문] 토마토는 과일이야? [영어 답] Botanically, a tomato is a fruit, but in cooking it is used as a vegetable. [한국어 답] \(tone.example)
            [질문] 소리는 얼마나 빨라? [영어 답] In air at 20 degrees Celsius, sound travels about 343 meters per second. [한국어 답] \(pick("섭씨 20도 공기 중에서 소리는 1초에 약 343미터를 이동해.", "섭씨 20도 공기 중에서 소리는 1초에 약 343미터를 이동해요."))
            [질문] 얼음은 왜 물에 떠? [영어 답] Ice floats because it is about 9% less dense than liquid water. [한국어 답] \(pick("얼음이 물보다 밀도가 9%쯤 낮아서 그래.", "얼음이 물보다 밀도가 9%쯤 낮아서 그래요."))
            [질문] 엔진이랑 모터 차이가 뭐야? [영어 답] An engine burns fuel to make motion, while a motor turns electricity into motion. [한국어 답] \(pick("엔진은 연료를 태워서 힘을 내고, 모터는 전기로 힘을 내.", "엔진은 연료를 태워서 힘을 내고, 모터는 전기로 힘을 내요."))
            """
    }

    static func retell(_ r: ChatRequest, english: String) -> String {
        "[질문] \(AssistantPrompt.short(r.question, AssistantPrompt.maxQuestion))\n[영어 답] \(glossed(english))\n[한국어 답]"
    }

    /// A number the retelling made up (measured 2026-10-04: "끓는 데 1초가 걸리는데" from "Water boils at 100 degrees
    /// Celsius at sea level"). "1초에" is let through: it is "per second".
    static func invents(_ korean: String, english: String) -> Bool {
        let known = Set(AssistantPrompt.numbers(english))
        let k = korean.replacingOccurrences(of: #"1\s*초(?:에|당)"#, with: "", options: .regularExpression)
        return AssistantPrompt.numbers(k).contains { !known.contains($0) }
    }

    /// Conditions the retelling drops or bends (measured 2026-10-04: "at sea level" gone three runs in four, once
    /// said as "물 한 모금"), and how each is said. `bare` takes them out of the English, `settle` puts them back.
    static let conditions: [(english: String, said: [String], korean: String)] = [
        ("at sea level", ["해수면", "기압", "해발"], "1기압에서"), ("at (?:1|one|standard) atmospher(?:e|ic pressure)(?: of pressure)?", ["기압"], "1기압에서"),
        ("at standard (?:atmospheric )?pressure", ["기압"], "1기압에서"), ("in a vacuum", ["진공"], "진공에서"), ("in air", ["공기"], "공기 중에서"),
    ]

    static func bare(_ english: String) -> String {
        var s = english
        for c in conditions {
            s = s.replacingOccurrences(of: #"(?i),?\s*\b"# + c.english + #"\b\s*,?"#, with: " ", options: .regularExpression)
        }
        return s.replacingOccurrences(of: #"\s+([.,;])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The retelling put right from the English: a sentence with a made-up number dropped, a dropped condition and 섭씨
    /// put back, a 약 the English never had taken out, and a sentence left on a number ("섭씨 100도.") given its 이야.
    /// Said in 반말; clean() turns it polite for a polite persona.
    static func settle(_ korean: String, english: String) -> String {
        var parts = AssistantPrompt.split(korean)
        let kept = parts.filter { !invents($0, english: english) }
        if !kept.isEmpty { parts = kept }
        var s = parts.joined(separator: " ")
        let en = english.lowercased()
        if (en.contains("celsius") || en.contains("°c")), !s.contains("섭씨"),
           let r = s.range(of: #"\d[\d,.]*\s*도"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "섭씨 " + s[r])
        }
        for c in conditions where en.range(of: #"\b"# + c.english + #"\b"#, options: .regularExpression) != nil && !c.said.contains(where: s.contains) {
            s = c.korean + " " + s
        }
        if !["about", "around", "approximately", "roughly", "nearly", "almost"].contains(where: en.contains) {
            s = s.replacingOccurrences(of: #"약\s*(?=\d)"#, with: "", options: .regularExpression)
        }
        // "299,792,458미터" with the size people say (measured 2026-10-04: the English gave meters, never the rounded km).
        var rounded: String?
        if let r = s.range(of: #"\d{1,3}(?:,\d{3}){1,}\s*(?:미터|킬로미터|km)"#, options: .regularExpression),
           let n = AssistantPrompt.numbers(String(s[r])).first.flatMap(Double.init) {
            let km = s[r].hasSuffix("미터") && !s[r].hasSuffix("킬로미터") ? n / 1000 : n
            if km >= 100_000 { rounded = "어림하면 약 \(Int((km / 10_000).rounded()))만 킬로미터야." }
        }
        var out = AssistantPrompt.split(s).map { p in
            guard p.hasSuffix("."), p.range(of: #"\d[\d,.]*\s*[가-힣/a-zA-Z]{0,8}\.$"#, options: .regularExpression) != nil,
                  let end = p.dropLast().last, !"야어아해요다지네까를을이가는은에".contains(end) else { return p }
            return String(p.dropLast()) + Banmal.particle(String(p.dropLast()), "이야", "야") + "."
        }
        if let rounded { out.append(rounded) }
        return out.joined(separator: " ")
    }

    /// Science words the model says wrong in Korean, given with the English (measured 2026-10-04: carbon dioxide as
    /// "탄산" and "탄소", chloroplast as "클로로플라스"). ponytail: a short list; add a word when a retelling gets it wrong.
    static let glossary: [(String, String)] = [
        ("carbon dioxide", "이산화탄소"), ("chloroplast", "엽록체"), ("glucose", "포도당"), ("photosynthesis", "광합성"),
        ("hydrogen", "수소"), ("nitrogen", "질소"), ("oxygen", "산소"), ("molecule", "분자"), ("atom", "원자"), ("cell", "세포"),
        ("mammal", "포유류"), ("gill", "아가미"), ("volatile", "휘발성"), ("berr", "열매"), ("bacteria", "세균"), ("virus", "바이러스"), ("gravity", "중력"), ("evaporat", "증발"),
        ("cartilaginous", "연골어류"), ("parallel", "병렬"),
    ]

    static func glossed(_ english: String) -> String {
        // "100 °C" in words: the sign alone came back as "물 한 모금에 … 가열" (measured 2026-10-04).
        var s = english.replacingOccurrences(of: #"\s*°\s*C\b"#, with: " degrees Celsius", options: .regularExpression)
        for (en, ko) in glossary {
            guard let re = try? NSRegularExpression(pattern: "(?i)\\b(\(en)[a-z]*)") else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1(\(ko))")
        }
        return s
    }
}
