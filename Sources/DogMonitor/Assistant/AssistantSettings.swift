import Foundation

/// How often the character speaks up on its own (먼저 말 걸기). The cooldown between two lines.
enum NudgeFrequency: String, CaseIterable, Codable {
    case off, rarely, normal, often

    var label: String {
        switch self {
        case .off: return L("끄기")
        case .rarely: return L("가끔")
        case .normal: return L("보통")
        case .often: return L("자주")
        }
    }

    /// 자주 = the 20 minute floor of the spec; the others space lines out more.
    var cooldown: TimeInterval? {
        switch self {
        case .off: return nil
        case .rarely: return 90 * 60
        case .normal: return 40 * 60
        case .often: return 20 * 60
        }
    }
}

enum PhoneService: String, CaseIterable, Codable {
    case ntfy, pushover
    var label: String { self == .ntfy ? L("ntfy (무료)") : L("Pushover (내 키)") }
}

/// What the iPhone is told about. Each can be switched off.
enum PhoneEvent: String, CaseIterable, Codable {
    case batteryLow, hot, taskDone, pet

    var label: String {
        switch self {
        case .batteryLow: return L("배터리 10%")
        case .hot: return L("맥이 뜨거울 때")
        case .taskDone: return L("오래 걸린 작업이 끝났을 때")
        case .pet: return L("펫이 부를 때")
        }
    }
}

/// AI 비서 options, in AppDefaults.store under "assistant.*". Every integration is off until the user turns it on.
final class AssistantSettings: ObservableObject {
    static let shared = AssistantSettings()
    private let d: UserDefaults

    @Published var persona: PersonaStyle { didSet { d.set(persona.rawValue, forKey: "assistant.persona") } }
    @Published var voice: Bool { didSet { d.set(voice, forKey: "assistant.voice") } }
    @Published var nudges: NudgeFrequency { didSet { d.set(nudges.rawValue, forKey: "assistant.nudges") } }
    /// 먼저 말 걸기 lines written by the on-device AI (assistant); off = template lines.
    @Published var aiNudges: Bool { didSet { d.set(aiNudges, forKey: "assistant.aiNudges") } }
    @Published var calendar: Bool { didSet { d.set(calendar, forKey: "assistant.calendar") } }
    /// Minutes before an event its alert comes, one alert per lead ([15, 5]: 15 and 5 minutes before).
    @Published var calendarLeads: [Int] { didSet { d.set(calendarLeads, forKey: "assistant.calendarLeads") } }
    /// 출근·점심·퇴근 인사 (all off until turned on).
    @Published var workHours: WorkHours { didSet { d.set(try? JSONEncoder().encode(workHours), forKey: "assistant.workHours") } }
    /// 아침에 오늘의 운세 (Fortune.morningCheck), off until turned on.
    @Published var fortuneMorning: Bool { didSet { d.set(fortuneMorning, forKey: "assistant.fortuneMorning") } }
    @Published var reminders: Bool { didSet { d.set(reminders, forKey: "assistant.reminders") } }
    @Published var mail: Bool { didSet { d.set(mail, forKey: "assistant.mail") } }
    @Published var phone: Bool { didSet { d.set(phone, forKey: "assistant.phone") } }
    @Published var phoneService: PhoneService { didSet { d.set(phoneService.rawValue, forKey: "assistant.phoneService") } }
    @Published var phoneEvents: Set<PhoneEvent> { didSet { d.set(phoneEvents.map(\.rawValue).sorted(), forKey: "assistant.phoneEvents") } }
    /// Made once, random: anyone who knows a ntfy topic can read it.
    @Published var ntfyTopic: String { didSet { d.set(ntfyTopic, forKey: "assistant.ntfyTopic") } }
    @Published var pushoverUser: String { didSet { d.set(pushoverUser, forKey: "assistant.pushoverUser") } }
    @Published var pushoverToken: String { didSet { d.set(pushoverToken, forKey: "assistant.pushoverToken") } }
    /// 잠시 조용히: no bubbles at all until then.
    @Published var mutedUntil: Date? { didSet { d.set(mutedUntil, forKey: "assistant.mutedUntil") } }
    /// charamonitor://say may make the character talk. Off until the user turns it on: any web page can open the link.
    @Published var urlSay: Bool { didSet { d.set(urlSay, forKey: "assistant.urlSay") } }
    /// 대사 고치기: the user's own template lines by LinePick key (LineOverrides). Bubble only, never in a prompt.
    @Published var lines: [String: String] { didSet { d.set(lines, forKey: "assistant.lines") } }
    /// Why an integration switched itself off (permission taken back, e.g. after an update), until 비서 설정 shows it.
    @Published var integrationNotice: String?

    /// The day each 출근·점심·퇴근 인사 was last said, {kind: "yyyy-MM-dd"}: once a day each.
    var workAlerts: [String: String] {
        get { d.dictionary(forKey: "assistant.workAlerts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "assistant.workAlerts") }
    }

    /// The 알림 시점 choices for calendar alerts.
    static let leadPresets = SetupFile.calendarLeadPresets
    static func leadLabel(_ leads: [Int]) -> String {
        let list = leads.map(String.init).joined(separator: "·")
        return L("\(list)분 전")
    }

    /// Keys only an app before 2.1 can have written by now (2.0 sets claudeTokenCleared on its first launch).
    /// This object is made in applicationWillFinishLaunching, before 2.1 itself writes any of them.
    #if MAS   // a new app on the App Store: nobody updates into it from 2.0
    static let upgradeMarkers: [String] = []
    #else
    static let upgradeMarkers = ["claudeTokenCleared", "character", "profile", "proLicenseKey", "proLicenses"]
    #endif

    /// 먼저 말 걸기 for someone who never chose: off for an update from 2.0 (they did not ask for a talking character),
    /// 가끔 for a new install. Decided once and saved, so later launches do not change it.
    static func firstNudges(_ d: UserDefaults) -> NudgeFrequency {
        upgradeMarkers.contains { d.object(forKey: $0) != nil } ? .off : .rarely
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        d = defaults
        persona = defaults.string(forKey: "assistant.persona").flatMap(PersonaStyle.init) ?? .auto
        voice = defaults.bool(forKey: "assistant.voice")
        if let saved = defaults.string(forKey: "assistant.nudges").flatMap(NudgeFrequency.init) {
            nudges = saved
        } else {
            let first = Self.firstNudges(defaults)
            nudges = first
            defaults.set(first.rawValue, forKey: "assistant.nudges")
        }
        urlSay = defaults.bool(forKey: "assistant.urlSay")
        lines = defaults.dictionary(forKey: "assistant.lines") as? [String: String] ?? [:]
        aiNudges = defaults.object(forKey: "assistant.aiNudges") as? Bool ?? true
        calendar = defaults.bool(forKey: "assistant.calendar")
        calendarLeads = (defaults.array(forKey: "assistant.calendarLeads") as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? [10]
        workHours = defaults.data(forKey: "assistant.workHours").flatMap { try? JSONDecoder().decode(WorkHours.self, from: $0) } ?? WorkHours()
        fortuneMorning = defaults.bool(forKey: "assistant.fortuneMorning")
        reminders = defaults.bool(forKey: "assistant.reminders")
        mail = defaults.bool(forKey: "assistant.mail")
        phone = defaults.bool(forKey: "assistant.phone")
        phoneService = defaults.string(forKey: "assistant.phoneService").flatMap(PhoneService.init) ?? .ntfy
        phoneEvents = Set((defaults.stringArray(forKey: "assistant.phoneEvents") ?? PhoneEvent.allCases.map(\.rawValue)).compactMap(PhoneEvent.init))
        pushoverUser = defaults.string(forKey: "assistant.pushoverUser") ?? ""
        pushoverToken = defaults.string(forKey: "assistant.pushoverToken") ?? ""
        mutedUntil = defaults.object(forKey: "assistant.mutedUntil") as? Date
        if let t = defaults.string(forKey: "assistant.ntfyTopic"), !t.isEmpty {
            ntfyTopic = t
        } else {
            ntfyTopic = Phone.newTopic()
            defaults.set(ntfyTopic, forKey: "assistant.ntfyTopic")
        }
    }

    func isMuted(now: Date = Date()) -> Bool { mutedUntil.map { now < $0 } ?? false }
}

/// 대사 고치기: the user's own words for a few template lines, by LinePick key, with {이름} for the
/// moment's numbers and names. Shown in the bubble as written (no flavor, no 울음소리), never put into a prompt.
enum LineOverrides {
    struct Slot: Identifiable {
        let id: String        // the LinePick key
        let label: String
        let vars: [String]    // the {이름} it may use
        let sample: String    // the default line, for the empty field
    }

    static let maxLength = 80

    static var slots: [Slot] {
        func nudge(_ n: Nudge, _ label: String) -> Slot {
            Slot(id: n.lineKey, label: label, vars: n.lineValues.keys.sorted(), sample: n.templates(polite: false)[0])
        }
        func pet(_ e: PetEvent, _ label: String, _ vars: [String] = []) -> Slot {
            Slot(id: PetModel.lineKey(e), label: label, vars: vars, sample: PetModel.lines(e)[0])
        }
        return [nudge(.batteryLow(10), L("배터리 부족")), nudge(.hot, L("맥이 뜨거울 때")), nudge(.taskDone(minutes: 12), L("오래 걸린 작업 끝")),
                nudge(.calendar(title: L("팀 회의"), minutes: 10), L("일정 알림")), nudge(.reminder(L("약 먹기")), L("미리알림")),
                nudge(.morning(), WorkHours.Kind.morning.label), nudge(.lunch, WorkHours.Kind.lunch.label),
                nudge(.leave(minutes: 10), WorkHours.Kind.leave.label),
                pet(.hungry, L("펫이 배고플 때")), pet(.cameHome, L("펫이 돌아왔을 때")), pet(.focusDone(coins: 5), L("집중 끝"), ["코인"]),
                pet(.restDone, L("쉬는 시간 끝")), pet(.eyeRest, L("눈 쉬기"))]
    }

    /// The {이름} in `text` that `allowed` does not have, in order.
    static func unknown(_ text: String, allowed: [String]) -> [String] {
        names(text).map(\.name).filter { !allowed.contains($0) }
    }

    /// Each {이름} put in from `values` in one pass (a title holding "{분}" stays as typed); unknown ones stay.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for n in names(text).reversed() { if let v = values[n.name] { out.replaceSubrange(n.range, with: v) } }
        return out
    }

    /// The edited line for `key`, filled in; nil when it is not edited.
    static func line(_ key: String, _ values: [String: String] = [:], saved: [String: String]? = nil) -> String? {
        guard let t = (saved ?? AssistantSettings.shared.lines)[key], !t.isEmpty else { return nil }
        return fill(t, values)
    }

    static func edited(_ key: String) -> Bool { line(key) != nil }

    private static func names(_ text: String) -> [(name: String, range: Range<String.Index>)] {
        let re = try! NSRegularExpression(pattern: #"\{([^{}\s]{1,10})\}"#)
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range, in: text), let n = Range(m.range(at: 1), in: text) else { return nil }
            return (String(text[n]), r)
        }
    }
}

/// 먼저 말 걸기 spacing. Pure: the caller passes the time. A line held back (muted, or `urgent` false inside the
/// cooldown) does not use up the cooldown; the caller keeps it for later.
struct NudgeGate {
    enum Answer: Equatable { case say, wait, never }
    private(set) var last: Date?

    /// .never: 먼저 말 걸기 is off. .wait: not now (muted, or too soon after the last line). .say: spends the cooldown.
    /// `urgent` lines (battery, heat) are not spaced out, only switched off with the rest.
    mutating func check(_ frequency: NudgeFrequency, muted: Bool, urgent: Bool = false, now: Date) -> Answer {
        guard let cooldown = frequency.cooldown else { return .never }
        if muted { return .wait }
        if !urgent, let last, now.timeIntervalSince(last) < cooldown, now >= last { return .wait }
        last = now
        return .say
    }

    mutating func allow(_ frequency: NudgeFrequency, now: Date) -> Bool { check(frequency, muted: false, now: now) == .say }
}

/// Things worth one line, found from the 10 s samples (PetSignals.sample) and the heat state. Pure.
enum Nudge: Equatable {
    case batteryLow(Int)
    case hot
    case taskDone(minutes: Int)
    case runaway(String)
    case calendar(title: String, minutes: Int, place: String = "")
    case reminder(String)
    case mail(count: Int, senders: [String])
    /// 출근 인사, with today's count of events and reminders (CalendarLink.brief) when those are on.
    case morning(brief: String = "")
    case lunch
    case leave(minutes: Int)

    /// What happened, in plain words, for the AI to put in the character's voice.
    var situation: String {
        switch self {
        case .batteryLow(let p): return "맥 배터리가 \(p)% 남았고 충전기가 꽂혀 있지 않다."
        case .hot: return "맥이 뜨거워져서 성능을 낮추고 있다."
        case .taskDone(let m): return "\(m)분 동안 바빴던 맥이 이제 조용해졌다. 오래 걸린 작업이 끝난 것 같다."
        case .runaway(let n): return "'\(n)' 프로세스가 몇 분째 CPU를 많이 쓰고 있다."
        case .calendar(let t, let m, _): return "\(m)분 뒤에 '\(t)' 일정이 있다."
        case .reminder(let t): return "곧 '\(t)' 미리알림 시간이다."
        case .mail(let c, let s): return "새 메일이 \(c)통 왔다" + (s.isEmpty ? "." : ". 보낸 사람: \(s.joined(separator: ", ")).")
        case .morning: return "출근 시간이다. 하루를 시작하는 아침 인사를 한다."
        case .lunch: return "점심시간이다. 점심 먹고 오라고 말한다."
        case .leave(let m): return "\(m)분 뒤면 퇴근 시간이다."
        }
    }

    /// The free line (banmal; polite for the 존댓말 persona), never the same as this moment's last one. The user's own
    /// line (대사 고치기) when there is one.
    func template(polite: Bool) -> String {
        if let own = LineOverrides.line(lineKey, lineValues) { return own + tail }
        let p = LinePick.pick(lineKey, templatePairs)
        return (polite ? p.1 : p.0) + tail
    }

    /// "nudge.<case>": the LinePick and 대사 고치기 key.
    var lineKey: String { "nudge." + String("\(self)".prefix { $0 != "(" }) }

    /// What a 대사 고치기 line may put in by {이름} (LineOverrides.slots lists the same names).
    var lineValues: [String: String] {
        switch self {
        case .batteryLow(let p): return ["배터리": "\(p)"]
        case .taskDone(let m): return ["분": "\(m)"]
        case .calendar(let t, let m, _): return ["제목": t, "분": "\(m)"]
        case .reminder(let t): return ["제목": t]
        case .leave(let m): return ["분": "\(m)"]
        default: return [:]
        }
    }

    /// Every free line for this moment, banmal or 존댓말.
    func templates(polite: Bool) -> [String] { templatePairs.map { (polite ? $0.1 : $0.0) + tail } }

    /// Said after the line as is, written by the AI or not: where a meeting is, the morning's count of events.
    var tail: String {
        switch self {
        case .calendar(_, _, let place): return place.isEmpty ? "" : "\n" + L("장소: \(place)")   // its own line, no emoji (the bubbles use none)
        case .morning(let brief): return brief.isEmpty ? "" : "\n" + brief
        default: return ""
        }
    }

    /// (banmal, 존댓말) per free line.
    var templatePairs: [(String, String)] {
        switch self {
        case .batteryLow(let p):
            return [(L("배터리가 \(p)%밖에 안 남았어. 충전기 꽂아 줘!"), L("배터리가 \(p)% 남았어요. 충전기를 꽂아 주세요.")),
                    (L("배터리 \(p)% 남았어. 꺼지기 전에 충전해 줘!"), L("배터리가 \(p)%뿐이에요. 꺼지기 전에 충전해 주세요.")),
                    (L("배터리가 \(p)%야. 충전기 어디 있어?"), L("배터리가 \(p)%예요. 충전기를 연결해 주세요."))]
        case .hot:
            return [(L("맥이 뜨거워. 무거운 일은 잠깐 쉬어 가자."), L("맥이 뜨거워요. 무거운 작업은 잠깐 쉬어 가요.")),
                    (L("맥이 후끈후끈해. 창 몇 개 닫아 볼까?"), L("맥이 많이 뜨거워요. 창 몇 개를 닫아 보는 건 어때요?")),
                    (L("열이 나서 맥이 속도를 줄였어. 잠깐 쉬게 해 주자."), L("열이 나서 맥이 속도를 줄였어요. 잠깐 쉬게 해 주세요."))]
        case .taskDone(let m):
            return [(L("\(m)분 동안 바빴던 일이 끝난 것 같아."), L("\(m)분 동안 바빴던 작업이 끝난 것 같아요.")),
                    (L("\(m)분 동안 돌던 일, 끝난 것 같아. 확인해 봐!"), L("\(m)분 동안 돌던 작업이 끝난 것 같아요. 확인해 보세요.")),
                    (L("맥이 이제 조용해졌어. \(m)분 걸린 일이 끝났나 봐."), L("맥이 이제 조용해졌어요. \(m)분 걸린 작업이 끝났나 봐요."))]
        case .runaway(let n):
            return [(L("\(n)이(가) 몇 분째 CPU를 많이 써. 클리너에서 볼래?"), L("\(n)이(가) 몇 분째 CPU를 많이 써요. 클리너에서 확인해 보세요."))]
        case .calendar(let t, let m, _):
            return [(L("\(m)분 뒤에 '\(t)' 있어."), L("\(m)분 뒤에 '\(t)' 일정이 있어요.")),
                    (L("'\(t)'까지 \(m)분 남았어. 준비하자!"), L("'\(t)'까지 \(m)분 남았어요. 준비해요.")),
                    (L("곧 '\(t)' 시간이야. \(m)분 뒤에 시작해."), L("곧 '\(t)' 시간이에요. \(m)분 뒤에 시작해요."))]
        case .reminder(let t):
            return [(L("곧 '\(t)' 할 시간이야."), L("곧 '\(t)' 할 시간이에요.")),
                    (L("'\(t)' 잊지 마!"), L("'\(t)' 잊지 마세요.")),
                    (L("미리알림이야: '\(t)'"), L("미리알림이에요: '\(t)'"))]
        case .mail(let c, let s):
            let who = s.isEmpty ? "" : " " + s.joined(separator: ", ")
            return [(L("새 메일 \(c)통 왔어.\(who)"), L("새 메일이 \(c)통 왔어요.\(who)")),
                    (L("메일 \(c)통 도착!\(who)"), L("메일이 \(c)통 도착했어요.\(who)")),
                    (L("메일함에 새 메일 \(c)통 있어.\(who)"), L("메일함에 새 메일이 \(c)통 있어요.\(who)"))]
        case .morning:
            return [(L("좋은 아침! 오늘도 같이 힘내자."), L("좋은 아침이에요. 오늘도 같이 힘내요.")),
                    (L("출근했구나! 오늘 하루도 잘 부탁해."), L("출근하셨네요. 오늘 하루도 잘 부탁드려요.")),
                    (L("왔구나! 물 한 잔 마시고 시작하자."), L("오셨어요? 물 한 잔 마시고 시작해요."))]
        case .lunch:
            return [(L("점심시간이야! 맛있는 거 먹고 와."), L("점심시간이에요. 맛있는 거 드시고 오세요.")),
                    (L("배고프지? 밥 먹고 하자!"), L("배고프시죠? 식사하고 하세요.")),
                    (L("냠냠, 점심 먹을 시간이야."), L("냠냠, 점심 드실 시간이에요."))]
        case .leave(let m):
            return [(L("\(m)분 뒤면 퇴근이야! 조금만 더 힘내."), L("\(m)분 뒤면 퇴근이에요. 조금만 더 힘내요.")),
                    (L("퇴근까지 \(m)분 남았어. 마무리하자!"), L("퇴근까지 \(m)분 남았어요. 마무리해요.")),
                    (L("곧 퇴근이야. \(m)분만 더 버티자!"), L("곧 퇴근이에요. \(m)분만 더 힘내요."))]
        }
    }

    /// The moment the menu bar character plays with the line (SituationEngine.play), nil = none.
    var motion: [ExtraMotion]? {
        switch self {
        case .calendar, .leave: return [.special]
        case .lunch: return [.eat]
        default: return nil
        }
    }

    /// How long the bubble stays, nil = long enough to read (SpeechBubbleWindow.duration). A meeting: until it
    /// starts, 1 to 2 minutes.
    var seconds: TimeInterval? {
        guard case .calendar(_, let m, _) = self else { return nil }
        return min(Double(m) * 60, 120)
    }

    /// Whether Persona.flavor may dress the free line: not held lines (they must read cleanly), nor mail, which ends
    /// with the senders' names (a tail would read as a remark about them).
    var flavored: Bool {
        if case .mail = self { return false }
        return !holdsBubble && tail.isEmpty
    }

    /// Lines that keep the bubble (SpeechLine.hold) and read cleanly, so Persona.flavor leaves them alone.
    var holdsBubble: Bool {
        switch self {
        case .calendar, .reminder: return true
        default: return isUrgent
        }
    }

    /// Warnings worth saying even inside the 먼저 말 걸기 cooldown (each fires once until its condition clears).
    var isUrgent: Bool {
        switch self {
        case .batteryLow, .hot: return true
        default: return false
        }
    }

    /// The same moment `seconds` later, for a line held back while muted; nil once it no longer holds
    /// (the meeting has started).
    func aged(by seconds: TimeInterval) -> Nudge? {
        switch self {
        case .calendar(let title, let minutes, let place):
            let left = minutes - Int(seconds / 60)
            return left >= 1 ? .calendar(title: title, minutes: left, place: place) : nil
        case .leave(let minutes):
            let left = minutes - Int(seconds / 60)
            return left >= 1 ? .leave(minutes: left) : nil
        default: return self
        }
    }

    /// Which iPhone switch sends this one, nil = never sent to the phone.
    var phoneEvent: PhoneEvent? {
        switch self {
        case .batteryLow: return .batteryLow
        case .hot: return .hot
        case .taskDone: return .taskDone
        default: return nil
        }
    }
}

/// Watches the samples for the moments above. Fires each once until the condition clears.
struct NudgeDetector {
    static let lowBattery = 10
    static let busyLoad = 0.6, quietLoad = 0.25
    static let busyFor: TimeInterval = 5 * 60, quietFor: TimeInterval = 30

    private var batteryFired = false
    private var hotFired = false
    private var busySince: Date?
    private var quietSince: Date?
    private var lastBusy: Date?

    mutating func feed(battery: BatteryStats?, load: Double, thermal: ProcessInfo.ThermalState, now: Date) -> [Nudge] {
        var out: [Nudge] = []
        if let b = battery, b.percent <= Self.lowBattery, !b.isCharging, !b.isPluggedIn {
            if !batteryFired { batteryFired = true; out.append(.batteryLow(b.percent)) }
        } else if (battery?.percent ?? 100) > Self.lowBattery + 5 || battery?.isPluggedIn == true {
            batteryFired = false
        }
        if thermal == .serious || thermal == .critical {
            if !hotFired { hotFired = true; out.append(.hot) }
        } else if thermal == .nominal {
            hotFired = false
        }
        // Busy for 5 minutes, then quiet for 30 s: a long build or export just finished.
        if load >= Self.busyLoad {
            busySince = busySince ?? now
            lastBusy = now
            quietSince = nil
        } else if load <= Self.quietLoad, let start = busySince, let end = lastBusy {
            quietSince = quietSince ?? now
            if now.timeIntervalSince(quietSince!) >= Self.quietFor {
                if end.timeIntervalSince(start) >= Self.busyFor { out.append(.taskDone(minutes: Int(end.timeIntervalSince(start) / 60))) }
                busySince = nil; lastBusy = nil; quietSince = nil
            }
        }
        return out
    }
}

/// 출근·점심·퇴근 인사 (먼저 말 걸기): times in minutes after midnight, workdays as Calendar weekdays (1 = 일요일).
/// Each greeting is off until turned on. Pure: the caller passes the time.
struct WorkHours: Codable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case morning, lunch, leave

        var label: String {
            switch self {
            case .morning: return L("출근 인사")
            case .lunch: return L("점심시간 알림")
            case .leave: return L("퇴근 10분 전 알림")
            }
        }
    }

    var start = 9 * 60, lunch = 12 * 60, end = 18 * 60
    var days: Set<Int> = [2, 3, 4, 5, 6]
    var greet: Set<Kind> = []

    /// 출근 인사 comes in the first 3 hours after `start` (a "좋은 아침" at 4 p.m. reads wrong), 점심 within the hour,
    /// 퇴근 in the last 10 minutes.
    static let morningFor = 180, lunchFor = 60, leaveFor = 10

    /// Whether `kind` is due at `now`: switched on, a workday that is no holiday, inside its window.
    /// start >= end (a night shift typed backwards): no 출근 or 퇴근 line.
    func due(_ kind: Kind, now: Date, calendar: Calendar = .current) -> Bool {
        guard greet.contains(kind), days.contains(calendar.component(.weekday, from: now)),
              !Self.krHolidays.contains(Self.day(now, calendar: calendar)) else { return false }
        let m = minute(now, calendar: calendar)
        switch kind {
        case .morning: return start < end && (start..<min(end, start + Self.morningFor)).contains(m)
        case .lunch: return (lunch..<lunch + Self.lunchFor).contains(m)
        case .leave: return start < end && (end - Self.leaveFor..<end).contains(m)
        }
    }

    /// Whether `now` is inside the work day, once any 업무 시간 line is switched on (the 커서 친구 plays half as often then).
    func working(_ now: Date, calendar: Calendar = .current) -> Bool {
        guard !greet.isEmpty, start < end, days.contains(calendar.component(.weekday, from: now)),
              !Self.krHolidays.contains(Self.day(now, calendar: calendar)) else { return false }
        return (start..<end).contains(minute(now, calendar: calendar))
    }

    /// Minutes until `end` (the 퇴근 line).
    func minutesToEnd(_ now: Date, calendar: Calendar = .current) -> Int { end - minute(now, calendar: calendar) }

    private func minute(_ now: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    }

    /// "2026-09-25", the key of workAlerts and krHolidays.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 대한민국 공휴일, 대체공휴일 and election days included.
    /// ponytail: hardcoded through 2027, extend in each year-end release.
    static let krHolidays: Set<String> = [
        "2026-01-01", "2026-02-16", "2026-02-17", "2026-02-18", "2026-03-01", "2026-03-02", "2026-05-01", "2026-05-05",
        "2026-05-24", "2026-05-25", "2026-06-03", "2026-06-06", "2026-07-17", "2026-08-15", "2026-08-17", "2026-09-24",
        "2026-09-25", "2026-09-26", "2026-10-03", "2026-10-05", "2026-10-09", "2026-12-25",
        "2027-01-01", "2027-02-06", "2027-02-07", "2027-02-08", "2027-02-09", "2027-03-01", "2027-05-01", "2027-05-05",
        "2027-05-13", "2027-06-06", "2027-07-17", "2027-07-19", "2027-08-15", "2027-08-16", "2027-09-14", "2027-09-15",
        "2027-09-16", "2027-10-03", "2027-10-04", "2027-10-09", "2027-10-11", "2027-12-25", "2027-12-27",
    ]
}
