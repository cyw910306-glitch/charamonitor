import Foundation

// AI 비서: what a question is about, decided by keywords before any model runs. The intent picks which facts go
// into the prompt (a question about whales gets no CPU numbers) and which questions never reach the model at all
// (things it cannot do, live data it cannot know, a vague "이거 괜찮아?"). Pure, so all of it is tested.
// Measured (assistant-eval, 2026-10-03): without this the on-device model invented exchange rates, mail and texts,
// and pasted Mac numbers into unrelated answers.

enum AssistantIntent: String, Equatable, CaseIterable {
    case action     // "회의 잡아 줘": the character cannot do it (template, never the model)
    case focus      // "집중 시작", "집중 그만": the 집중 타이머 on the desktop friend (FocusCenter, no model)
    case todoProgress   // "오늘 할 일 얼마나 했어?": today's ticked reminders of all (TodoProgress, this Mac only)
    case inbox      // received mail, texts, notifications (AssistantContext.inbox, InboxReport), said as the app has them
    case schedule   // today's calendar and reminders (ChatRequest.personal)
    case mac        // this Mac's numbers, only the asked-about ones
    case calc       // arithmetic the app works out (Calc), the model only words it
    case realtime   // exchange rates, weather, news... (unknown) and the time or date (answered from the clock)
    case joke       // "재밌는 얘기 해 줘": a riddle from a list (measured: the model told no joke, or a long unfinished story)
    case dance      // "춤춰 줘": a line and the menu bar character's special moment (fixed, no model)
    case cheer      // "응원해 줘": the same, cheering
    case vague      // "이거 괜찮아?" with nothing before it: ask back
    case general    // knowledge, translation, small talk: the model, no Mac numbers

    /// First match wins, in the order of the cases above.
    /// `previous`: the question before, so a short follow-up stays on its subject ("그럼 메일은?", "더 보여줘", "왜?" after
    /// "왜 느려?", "그거 몇 시야?" after "오늘 회의 있어?"; measured 2026-10-04: these went to small talk or the clock).
    static func route(_ question: String, hasHistory: Bool, previous: String? = nil) -> AssistantIntent {
        let own = routeAlone(question, hasHistory: hasHistory, previous: previous)
        guard let previous, question.count <= 20, [.general, .vague, .realtime].contains(own), !asksToWrite(question) else { return own }
        let q = question.lowercased(), tight = q.filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) } }
        let pointer = has(pointerWords), follow = own != .realtime && has(followUpWords)
        switch route(previous, hasHistory: false) {
        case .mac where (pointer || follow || MacTopic.mentions(question)) && !has(howWords): return .mac
        case .schedule where pointer || follow: return .schedule
        case .inbox where pointer || follow: return .inbox
        default: return own
        }
    }

    /// Words that carry a short question on from the one before.
    static let followUpWords = ["왜", "어째서", "그럼", "그러면", "그래서", "언제", "몇 시", "누가", "누구", "어디", "why", "when", "who"]

    private static func routeAlone(_ question: String, hasHistory: Bool, previous: String?) -> AssistantIntent {
        let q = question.lowercased()
        let tight = q.filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) || tight.contains($0) } }

        if has(focusStartWords) || has(focusStopWords) { return .focus }
        if has(progressWords), has(["할 일", "할일", "미리알림", "to-do", "todo"]) { return .todoProgress }
        if actionKind(question) != nil { return .action }
        // "미리알림" is a schedule word that contains the inbox word "알림".
        let noReminder = tight.replacingOccurrences(of: "미리알림", with: "")
        let inboxWord = inboxWords.contains(where: { noReminder.contains($0) || q.contains($0) })
        if inboxWord, has(arrivalWords) || (has(tellWords) && !has(howWords)), !asksToWrite(question) { return .inbox }
        // "뭐 왔어?" names nothing, but only something received can have come.
        if has(["뭐 왔", "뭐왔", "머 왔", "머왔", "뭐 온 거", "뭐온거", "새로 온 거", "새로온거", "anything new", "안 읽은", "안읽은", "unread"]),
           !has(scheduleWords),
           MacTopic.asked(question).isEmpty { return .inbox }
        if let previous, question.count <= 20, !has(scheduleWords), MacTopic.asked(question).isEmpty, !asksToWrite(question),
           inboxWord || has(followWords) || InboxQuery.sender(question, follow: true) != nil,
           route(previous, hasHistory: false) == .inbox { return .inbox }
        // "이 문장 다듬어 줘: 내일 회의…" is writing help; "며칠 일정이면 돼?" after a trip question is the trip's plan,
        // not the calendar (measured 2026-10-05 with Claude: both answered "캘린더 연동이 꺼져 있어").
        if has(scheduleWords), !asksToWrite(question), !has(tripPlanWords) { return .schedule }
        if !MacTopic.asked(question).isEmpty { return .mac }
        if Calc.solve(question) != nil { return .calc }
        if realtimeKind(question) != nil { return .realtime }
        if has(jokeWords) { return .joke }
        // "힘내라는 카드 문구 써 줘", "응원하는 방법": text to write or a how-to, answered as one.
        let request = !asksToWrite(question) && !has(howWords)
        if request, has(danceWords) { return .dance }
        if request, has(cheerWords) { return .cheer }
        if !hasHistory, question.count <= 15, has(pointerWords) { return .vague }
        return .general
    }

    // MARK: Keywords (Korean matched with and without spaces, English lowercased)

    static let inboxWords = ["메일", "문자", "메시지", "메세지", "카톡", "카카오톡", "알림", "연락", "디엠", "슬랙", "텔레그램",
                             "부재중", "mail", "message", "text", "notification", "slack", "imessage", "sms", "dm"]
    /// An inbox word alone is not enough ("메일 쓰는 법", "알림 끄는 방법 있어?"): the question must be about something
    /// having arrived. Not 확인, 있어, check or new on their own ("자료 확인 부탁드립니다", "check this text").
    static let arrivalWords = ["왔", "온 거", "온거", "온 게", "온게", "온 것", "새로 온", "새로온", "와?", "새 메일", "새 문자", "새 알림",
                               "받은", "안 읽은", "안읽은", "몇 통", "몇통", "도착", "unread", "received", "any new", "new mail",
                               "new message", "new text", "did i get", "get any",
                               // Asking to be told what came ("문자 내용 읽어줘", measured 2026-10-04: went to the model, which made up counts).
                               "읽어", "내용", "보여 줘", "보여줘", "누구", "read my", "read me", "what did",
                               // Measured 2026-10-04: "나 가장 최근에 온 문자 내역 알랴줘" went to the model, which echoed it back.
                               "내역", "최근", "마지막", "온 문자", "온문자", "온 메일", "온메일", "온 카톡", "온카톡", "온 알림", "온알림",
                               "보낸 문자", "보낸 메일", "누가", "보여죠", "보여 죠", "뭐 와", "머 와", "뭐와", "머와", "latest", "last ", "who"]
    /// "알려줘" counts only when it is not about how to do something ("메일 쓰는 법 알려줘", "알림 끄는 방법 알려줘").
    /// "메일 확인해줘" too (measured 2026-10-04: went to the model, which said it was checking).
    static let tellWords = ["알려", "알랴", "알려죠", "말해", "얘기해", "확인해", "체크해", "tell me", "show me", "check my", "check for"]
    static let howWords = ["방법", "하는 법", "하는법", "쓰는 법", "쓰는법", "어떻게", "설정", "끄", "켜", "주소", "how to", "how do"]
    /// After an inbox question: "더 보여줘", "또 있어?", "나머지는?".
    static let followWords = ["더 ", "더보", "더알", "더읽", "더있", "더없", "또", "나머지", "그 전", "그전", "이전", "다른 거", "more"]
    /// Writing help about a mail or text ("메일인데 다듬어 줘: …", "check this text for typos") is the model's.
    static let writeWords = ["다듬", "고쳐", "번역", "맞춤법", "써 줘", "써줘", "작성", "proofread", "typo", "translate", "rewrite"]

    static func asksToWrite(_ question: String) -> Bool {
        let q = question.lowercased()
        if writeWords.contains(where: { q.contains($0) }) { return true }
        // A body after a colon ("…: 자료 확인 부탁드립니다") is text to work on, not a question about the inbox.
        guard let colon = q.firstIndex(of: ":") else { return false }
        return q[q.index(after: colon)...].trimmingCharacters(in: .whitespaces).count > 10
    }
    static let scheduleWords = ["일정", "회의", "미팅", "약속", "스케줄", "미리알림", "할 일", "할일", "캘린더", "달력", "오늘 뭐 있",
                                "오늘 뭐 해야", "calendar", "meeting", "schedule", "reminder", "appointment", "agenda"]
    /// "일정" as a trip's plan, not the owner's calendar.
    static let tripPlanWords = ["며칠 일정", "여행 일정", "일정 짜", "일정이면", "박 일정", "일 일정", "일정으로", "일정 추천", "코스", "몇 박", "몇박"]
    static let jokeWords = ["농담", "재밌는 얘기", "재미있는 얘기", "웃긴 얘기", "재밌는 이야기", "웃긴 이야기", "넌센스", "난센스", "아재개그",
                            "joke", "something funny"]
    static let focusStartWords = ["집중 시작", "집중시작", "집중할래", "집중 할래", "집중 모드", "집중모드", "뽀모도로", "pomodoro", "start focus", "focus mode"]
    static let focusStopWords = ["집중 그만", "집중그만", "집중 끝", "집중끝", "집중 멈춰", "그만 집중", "stop focus"]
    static let progressWords = ["얼마나 했", "몇 개 했", "몇개 했", "몇 개나 했", "다 했어", "진행률", "how many did", "how much did"]

    /// Asking for it, not about it: request forms only ("춤 좀 배우고 싶어", "힘나게 하는 음식" are not here).
    static let danceWords = ["춤춰", "춤좀춰", "춤보여", "춤좀보여", "춤출래", "댄스해", "댄스보여", "dance for", "dance!"]
    /// Not "힘들어": a feeling gets Feeling's answer, not a dance.
    static let cheerWords = ["응원해", "응원좀", "응원부탁", "힘내라고해", "힘좀줘", "힘나게해", "격려해", "cheer me", "cheer for me"]
    static let pointerWords = ["이거", "그거", "저거", "이게", "그게", "저게", "이건", "그건", "저건", "걔", "this", "that", " it"]

    // MARK: Things the character cannot do

    enum ActionKind: Equatable { case schedule, alarm, send, files, apps, other }

    /// Verbs that always ask the app to do something ("꺼 줘"), and ones that only do with a known object
    /// ("정리해 줘" is an action for files, a summary for text).
    static let strongVerbs = ["잡아", "보내", "꺼", "켜", "열어", "실행해", "종료해", "지워", "삭제해", "비워", "예약해", "답장해", "전화해"]
    static let weakVerbs = ["만들어", "추가해", "등록해", "넣어", "정리해", "설정해", "바꿔", "걸어", "맞춰"]
    static let englishActions = ["send ", "delete ", "turn off", "turn on", "set an alarm", "set a timer", "remind me", "schedule a",
                                 "book a", "quit ", "close the"]
    static let objects: [(ActionKind, [String])] = [
        (.alarm, ["알람", "타이머", "alarm", "timer"]),
        (.schedule, ["일정", "회의", "미팅", "약속", "스케줄", "캘린더", "미리알림", "리마인더", "meeting", "event", "calendar", "reminder", "appointment"]),
        (.send, ["메일", "문자", "메시지", "메세지", "카톡", "답장", "전화", "mail", "message", "text", "call"]),
        (.files, ["파일", "캐시", "휴지통", "저장 공간", "저장공간", "용량", "다운로드", "메모리", "file", "cache", "trash"]),
        (.apps, ["앱", "어플", "프로그램", "사파리", "크롬", "app"]),
    ]

    /// nil when the question asks for nothing to be done.
    static func actionKind(_ question: String) -> ActionKind? {
        let q = question.lowercased()
        let tight = q.filter { !$0.isWhitespace }
        func asks(_ stems: [String]) -> Bool { stems.contains { tight.contains($0 + "줘") || tight.contains($0 + "주") } }
        let strong = asks(strongVerbs) || englishActions.contains { q.contains($0) }
        let weak = asks(weakVerbs)
        guard strong || weak else { return nil }
        if let hit = objects.first(where: { $0.1.contains { q.contains($0) || tight.contains($0) } }) { return hit.0 }
        return strong ? .other : nil
    }

    // MARK: Live data

    enum RealtimeKind: Equatable { case time, date, money, weather, news, sports }

    static let realtimeWords: [(RealtimeKind, [String])] = [
        (.time, ["몇 시", "몇시", "지금 시간", "현재 시간", "what time"]),
        (.date, ["며칠", "몇 월", "몇월", "무슨 요일", "오늘 날짜", "날짜 알려", "what day", "today's date", "what date"]),
        (.money, ["환율", "달러", "엔화", "유로", "주가", "주식", "코스피", "코스닥", "나스닥", "비트코인", "코인", "금값",
                  "exchange rate", "stock", "bitcoin", "crypto"]),
        (.weather, ["날씨", "기온", "비 와", "비와", "눈 와", "미세먼지", "weather", "forecast", "temperature outside"]),
        (.news, ["뉴스", "속보", "헤드라인", "news", "headline"]),
        (.sports, ["경기 결과", "스코어", "몇 대 몇", "score", "who won"]),
    ]

    /// Only questions asking for a value right now: "지금 몇 시야?", "오늘 며칠이야?", "환율 얼마야?", "내일 비 와?".
    /// A topic word alone is not enough (measured 2026-10-05: "돌로미티는 몇월에 가는 게 좋아?" got today's date; "몇 시에
    /// 출발해야 돼?", "주식 공부 어떻게 해?", "날씨 좋은 여행지" would have been cut off the same way).
    static func realtimeKind(_ question: String) -> RealtimeKind? {
        let q = question.lowercased()
        let tight = q.filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) } }
        func matches(_ pattern: String) -> Bool { tight.range(of: pattern, options: .regularExpression) != nil }
        let general = has(generalCues)
        if matches(#"(지금|현재)(몇시|시간)|몇시(야|예요|에요|지|니|인가|일까|쯤이야|쯤이에요|인지)"#) || has(["what time is it", "time is it now"]) {
            return .time
        }
        if dayOffset(question) != nil, matches(#"(며칠|몇일|몇월|날짜|무슨요일|뭔요일|무슨날)"#) || has(["what day", "what date", "today's date"]) {
            return .date
        }
        // "며칠이야?", "몇 월이야?", "무슨 요일이야?" with nothing else: about today.
        if tight.count <= 12, matches(#"^(며칠|몇일|몇월|몇월며칠|무슨요일|뭔요일|날짜)(이야|이에요|예요|이지|인가요?|일까|이니|야)?\??$"#) { return .date }
        if has(["what's the date", "what is the date"]) { return .date }
        if general { return nil }
        let now = has(nowCues)
        for (kind, words) in realtimeWords where [.money, .weather, .news, .sports].contains(kind) && has(words) {
            switch kind {
            case .money where now || has(["얼마", "시세", "올랐", "내렸", "떨어졌", "몇 원", "몇원", "how much"]): return .money
            case .weather where now || has(["와?", "오나", "올까", "와요", "오려나", "몇 도", "몇도", "우산"]): return .weather
            case .news where now || has(["무슨 일", "무슨일", "뭐 있"]): return .news
            case .sports where now || has(["결과", "누가 이겼", "이겼어", "졌어", "who won"]): return .sports
            default: continue
            }
        }
        return nil
    }

    /// The day a date question is about: 0 today, 1 tomorrow, -1 yesterday. nil when it names none.
    static func dayOffset(_ question: String) -> Int? {
        let q = question.lowercased()
        let tight = q.filter { !$0.isWhitespace }
        for (words, n) in [(["오늘", "today", "지금", "현재", "이번달", "이번 달"], 0), (["내일", "tomorrow"], 1), (["모레"], 2), (["글피"], 3),
                           (["어제", "yesterday"], -1), (["그제", "그저께"], -2)] where words.contains(where: { q.contains($0) || tight.contains($0) }) {
            return n
        }
        return nil
    }

    /// Now-words that make a topic word ask for a live value.
    static let nowCues = ["지금", "현재", "오늘", "실시간", "요즘", "최근", "이번 주", "이번주", "내일", "모레", "주말", "now", "today",
                          "current", "latest", "tonight", "tomorrow"]
    /// Asking about the topic, not for its value now ("주식 공부 어떻게 해?", "몇 월에 가는 게 좋아?", "날씨 좋은 여행지").
    static let generalCues = ["몇 월에", "몇월에", "언제 가", "언제가", "계절", "평균", "보통", "기후", "방법", "어떻게", "공부", "뜻",
                              "차이", "이란", "원리", "추천", "좋은 곳", "좋은곳", "여행지", "가기 좋", "가기좋", "how to", "best time",
                              "when to", "difference", "what is a", "recommend"]
}

/// Which of this Mac's numbers a question is about. Empty = not about the Mac. "느려" and "맥 상태" mean all of them.
enum MacTopic: String, CaseIterable {
    case cpu, memory, storage, battery, heat, network, uptime

    /// Words that mean this topic of this Mac on their own ("메모리 부족해?").
    var words: [String] {
        switch self {
        case .cpu: return ["cpu", "씨피유"]
        case .memory: return ["메모리", " 램", " ram", "memory"]
        case .storage: return ["저장 공간", "저장공간", "남은 용량", "용량 남", "디스크", "ssd", " disk"]
        case .battery: return ["배터리", "battery"]
        case .heat: return ["발열", "팬 소리", "팬이"]
        case .network: return ["와이파이", "wifi", "wi-fi"]
        case .uptime: return ["재시동", "재부팅", "uptime", "업타임", "켜진 지", "켜진지"]
        }
    }

    /// Words that mean this topic only next to a Mac anchor ("맥이 뜨거워" yes, "전기차 충전" and "우주 공간" no).
    var anchoredWords: [String] {
        switch self {
        case .cpu: return ["바쁜 앱", "프로세스", "process", "busy app"]
        case .memory: return []
        case .storage: return ["저장", "용량", "storage"]
        case .battery: return ["충전", "전원", "charg"]
        case .heat: return ["뜨거", "heat", " fan"]
        case .network: return ["인터넷", "네트워크", "다운로드", "업로드", "internet", "network"]
        case .uptime: return ["켜진", "켜 둔", "켜둔", "껐다", "restart", "reboot"]
        }
    }

    /// The SystemSnapshotText line(s) for this topic.
    var factPrefixes: [String] {
        switch self {
        case .cpu: return ["CPU:", "바쁜 앱:"]
        case .memory: return ["메모리:"]
        case .storage: return ["저장 공간:"]
        case .battery: return ["배터리:"]
        case .heat: return ["발열:"]
        case .network: return ["네트워크:"]
        case .uptime: return ["켜진 지:"]
        }
    }

    /// Words in SystemSnapshotText.verdicts that belong to this topic.
    var hintWords: [String] {
        switch self {
        case .cpu: return ["CPU", "느릴"]
        case .memory: return ["메모리"]
        case .storage: return ["저장"]
        case .battery: return ["배터리"]
        case .heat: return ["뜨거"]
        case .network: return []
        case .uptime: return ["오래 켜"]
        }
    }

    /// This Mac, named: "내 맥 상태 어때?" means all of it, and makes the anchored words count.
    static let anchors = ["내 맥", "이 맥", "맥 상태", "맥북", "맥이", "맥은", "맥 괜찮", "내 컴퓨터", "이 컴퓨터", "내 노트북", "이 노트북",
                          "my mac", "this mac", "mac ok", "my computer", "this computer", "my laptop",
                          // "지금 내컴퓨터 상태 어때" (measured 2026-10-04: no space, so it went to small talk).
                          "내컴퓨터", "내맥", "이컴퓨터", "내노트북", "컴퓨터 상태", "컴퓨터상태", "노트북 상태", "노트북상태", "pc 상태", "pc상태",
                          "내 pc", "컴퓨터 괜찮", "노트북 괜찮", "컴퓨터 어때", "노트북 어때", "my pc"]

    /// Slow words as their endings, so 디렉터리, 컬렉션 or flag never count ("렉 걸려", "lag" as a whole word).
    static let slowWords = ["느려", "느리", "느린데", "느림", "버벅", "렉 걸", "렉걸", "렉이", "렉 심", "렉심", "렉 있", "렉있", "멈춰", "끊겨", "slow"]

    /// "왜 느려?": answered from SystemSnapshotText.verdicts by the template (measured: the model said a Mac at 3 % CPU
    /// was slow *because* of the low CPU, 2 runs of 3).
    static func isSlow(_ question: String) -> Bool {
        let q = question.lowercased()
        let tight = q.filter { !$0.isWhitespace }
        if q.range(of: #"\blag(s|gy|ging)?\b"#, options: .regularExpression) != nil { return true }
        return slowWords.contains { q.contains($0) || tight.contains($0.filter { !$0.isWhitespace }) }
    }

    static func anchored(_ question: String) -> Bool {
        let q = " " + typosFixed(question.lowercased())
        return anchors.contains { q.contains($0) }
    }

    /// Slips that keep a Mac question from matching ("맥 상테 어떄", measured 2026-10-04: went to the template's "모르겠어").
    static let typos = [("상테", "상태"), ("어떄", "어때"), ("어떼", "어때"), ("컴터", "컴퓨터"), ("괜잖", "괜찮")]
    static func typosFixed(_ q: String) -> String { typos.reduce(q) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }

    /// "무슨 앱이 제일 많이 먹어?": which app takes the most.
    static let hogWords = ["많이 먹", "제일 먹", "잡아먹", "많이 써", "많이 쓰", "차지", "바쁜", "무거운", "hog", "using the most"]
    /// "RAM이 뭐야?", "CPU랑 GPU 차이": the idea, not this Mac's numbers, unless the question asks about now or how much.
    static let conceptWords = ["뭐야", "뭔데", "뭐예요", "뭐에요", "뭔가요", "무엇", "차이", "뜻", "이란", "란 ", "설명", "what is", "what's a",
                               "difference", "explain", "mean"]
    /// How-to and tips: the idea, not the reading ("배터리 오래 쓰는 법", "메모리 아끼는 팁").
    static let adviceWords = ["쓰는 법", "쓰는법", "하는 법", "하는법", "방법", "팁", "오래 쓰", "오래쓰", "아끼", "늘리는", "관리법", "how to", "tips"]
    static let usageWords = ["얼마", "몇", "써", "쓰", "사용", "남", "상태", "괜찮", "부족", "많이", "높", "낮", "지금", "현재", "how much", "now", "usage"]

    /// "무슨 앱이 제일 많이 먹어?": which app takes the most ("먹어" is as often memory as CPU, so both are said).
    static func isHog(_ question: String) -> Bool {
        let q = typosFixed(question.lowercased()), tight = q.filter { !$0.isWhitespace }
        func has(_ w: String) -> Bool { (" " + q).contains(w) || (!w.contains(" ") && tight.contains(w)) }
        return ["앱", "app", "프로그램"].contains(where: has) && hogWords.contains(where: has)
    }

    /// Names a topic at all, anchored or not ("충전해야 돼?" after a battery question).
    static func mentions(_ question: String) -> Bool {
        let q = " " + question.lowercased(), tight = q.filter { !$0.isWhitespace }
        return allCases.contains { ($0.words + $0.anchoredWords).contains { q.contains($0) || (!$0.contains(" ") && tight.contains($0)) } }
    }

    static func asked(_ question: String) -> Set<MacTopic> {
        let q = typosFixed(question.lowercased())
        let tight = q.filter { !$0.isWhitespace }
        func has(_ w: String) -> Bool { (" " + q).contains(w) || (!w.contains(" ") && tight.contains(w)) }
        let anchor = anchored(question)
        if isHog(question) { return [.cpu, .memory] }
        if !anchor, conceptWords.contains(where: has), !usageWords.contains(where: has), !isSlow(question) { return [] }
        // "배터리 오래 쓰는 법": advice, not this Mac's numbers (measured 2026-10-05: "배터리는 99% 남았어.").
        if adviceWords.contains(where: has), !["지금", "현재", "얼마", "몇 ", "남았", "남은"].contains(where: has) { return [] }
        // Slow: everything but the network rates (measured: the model blamed a 2 kB/s download for a slow Mac).
        if isSlow(question) {
            let net = (MacTopic.network.words + MacTopic.network.anchoredWords).contains(where: has)
            return Set(allCases).subtracting(net ? [] : [.network])
        }
        let picked = Set(allCases.filter { $0.words.contains(where: has) || (anchor && $0.anchoredWords.contains(where: has)) })
        if !picked.isEmpty { return picked }
        return anchor ? Set(allCases) : []
    }

    /// The facts and hints for these topics (everything when all topics are asked).
    static func focus(facts: [String], hints: [String], on topics: Set<MacTopic>) -> (facts: [String], hints: [String]) {
        guard topics.count < allCases.count else { return (facts, hints) }
        let prefixes = topics.flatMap(\.factPrefixes), words = topics.flatMap(\.hintWords)
        var picked = hints.filter { h in words.contains { h.contains($0) } }
        // verdicts only name heat when it is a problem; say so when it is not (measured: "뜨거워진 건 보통이야").
        if topics.contains(.heat), !picked.contains(where: { $0.contains("뜨거") }) { picked.append("발열은 정상 범위, 걱정 없음") }
        return (facts.filter { f in prefixes.contains { f.hasPrefix($0) } }, picked)
    }
}

/// What other parts of the app hand the chat. InboxCenter sets `inbox` at launch: for an `.inbox` question it reads
/// the received texts, notifications and mail right then (InboxReport). Its contents never go to the cloud.
/// nil = nothing to look in: the chat says it cannot see them.
enum AssistantContext {
    static var inbox: (InboxQuery) async -> InboxReport? = { _ in nil }
}

/// Arithmetic in a question, worked out by the app (measured: the on-device model got 1234 × 56 wrong 3 times of 3).
/// ponytail: + - × ÷ with precedence and "A의 B%", no brackets or powers; add them when people ask for them.
enum Calc {
    static let words: [(String, String)] = [("곱하기", "*"), ("나누기", "/"), ("더하기", "+"), ("빼기", "-"), ("플러스", "+"), ("마이너스", "-"),
                                            ("×", "*"), ("÷", "/"), ("multiplied by", "*"), ("divided by", "/"), ("times", "*"),
                                            ("plus", "+"), ("minus", "-")]
    /// A question with only - or / needs one of these ("3-4시", "10/3" are not sums).
    static let cues = ["얼마", "계산", "=", "몇이", "빼기", "나누기", "마이너스", "what is", "calculate"]

    /// "1234 곱하기 56은 얼마야?" -> "1234 × 56 = 69,104". nil when there is no sum (or one divides by zero).
    static func solve(_ question: String) -> String? {
        var s = question.lowercased()
        for (w, op) in words { s = s.replacingOccurrences(of: w, with: " \(op) ") }
        s = s.replacingOccurrences(of: #"(\d)\s*x\s*(\d)"#, with: "$1 * $2", options: .regularExpression)
        while let r = s.range(of: #"(\d),(\d{3})"#, options: .regularExpression) {
            s.replaceSubrange(r, with: s[r].replacingOccurrences(of: ",", with: ""))
        }
        // "8만" -> 80000 (measured 2026-10-04: "8만원의 15%는?" went to the model).
        for (unit, times) in [("억", 100_000_000.0), ("만", 10_000.0), ("천", 1_000.0)] {
            while let r = s.range(of: #"\d+(?:\.\d+)?\s*"# + unit, options: .regularExpression),
                  let n = Double(s[r].dropLast().trimmingCharacters(in: .whitespaces)) {
                s.replaceSubrange(r, with: format(n * times).replacingOccurrences(of: ",", with: ""))
            }
        }
        let number = #"\d+(?:\.\d+)?"#
        // "80000원의 15%", "15% of 80000".
        for (pattern, baseFirst) in [("(\(number))\\s*원?\\s*의\\s*(\(number))\\s*%", true), ("(\(number))\\s*%\\s*of\\s*(\(number))", false)] {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
                  let a = Double(s[r1]), let b = Double(s[r2]) else { continue }
            let (base, pct) = baseFirst ? (a, b) : (b, a)
            return "\(format(base))의 \(format(pct))% = \(format(base * pct / 100))"
        }
        guard let r = s.range(of: "\(number)(?:\\s*[-+*/]\\s*\(number))+", options: .regularExpression) else { return nil }
        let expr = String(s[r])
        let ops = expr.filter { "+-*/".contains($0) }
        let q = question.lowercased()
        if !ops.contains(where: { "+*".contains($0) }), !cues.contains(where: { q.contains($0) }) { return nil }
        let nums = expr.components(separatedBy: CharacterSet(charactersIn: "+-*/")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard nums.count == ops.count + 1, let first = Double(nums[0]) else { return nil }
        var terms = [first]
        for (i, op) in ops.enumerated() {
            guard let n = Double(nums[i + 1]) else { return nil }
            switch op {
            case "*": terms[terms.count - 1] *= n
            case "/": guard n != 0 else { return nil }; terms[terms.count - 1] /= n
            case "-": terms.append(-n)
            default: terms.append(n)
            }
        }
        let shown = zip(nums, ops.map { ["*": "×", "/": "÷"][String($0)] ?? String($0) } + [""]).map { $0 + ($1.isEmpty ? "" : " \($1) ") }.joined()
        return "\(shown) = \(format(terms.reduce(0, +)))"
    }

    static func format(_ x: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: x)) ?? String(x)
    }

    /// The result part of solve ("69,104").
    static func result(_ question: String) -> String? {
        solve(question)?.components(separatedBy: " = ").last
    }
}
