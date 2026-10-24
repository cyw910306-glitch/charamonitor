import Foundation

/// One of the four 펫 키우기 gauges, 0...100, higher is better (배부름 low = hungry).
enum PetGauge: String, CaseIterable, Codable {
    case food, mood, energy, clean

    var title: String {
        switch self {
        case .food: return L("배부름")
        case .mood: return L("기분")
        case .energy: return L("기운")
        case .clean: return L("청결")
        }
    }

    var symbol: String {
        switch self {
        case .food: return "fork.knife"
        case .mood: return "heart.fill"
        case .energy: return "bolt.fill"
        case .clean: return "drop.fill"
        }
    }

    /// Points lost per hour with nothing happening.
    var decayPerHour: Double {
        switch self {
        case .food: return 5
        case .mood: return 4
        case .energy: return 3
        case .clean: return 2.5
        }
    }
}

/// Things counted per day: the daily missions read these, and the 성장 일기 line is written from them.
enum PetMissionKind: String, CaseIterable, Codable {
    case breaks, feed, cleaner, pet, focus, wash, speedTest

    var title: String {
        switch self {
        case .breaks: return L("쉬는 시간 \(target)번 갖기")
        case .feed: return L("밥 \(target)번 주기")
        case .cleaner: return L("클리너 \(target)번 돌리기")
        case .pet: return L("쓰다듬기 \(target)번")
        case .focus: return L("25분 집중 \(target)번")
        case .wash: return L("씻기기 \(target)번")
        case .speedTest: return L("인터넷 속도 \(target)번 재기")
        }
    }

    var target: Int {
        switch self {
        case .breaks, .pet: return 3
        case .feed: return 2
        case .cleaner, .focus, .wash, .speedTest: return 1
        }
    }

    var reward: Int {
        switch self {
        case .focus, .cleaner: return 20
        case .breaks: return 15
        case .feed, .pet, .wash, .speedTest: return 10
        }
    }

    /// Three different missions a day, rotating through the pool. Day 0 (and every 7th) is 쉬는 시간 · 클리너 · 집중.
    static func missions(forDay day: Int) -> [PetMissionKind] {
        #if MAS   // no cleaner in the App Store build, so no 클리너 mission (6 left, offsets 0/2/4 still differ)
        let pool = allCases.filter { $0 != .cleaner }
        #else
        let pool = allCases
        #endif
        let n = ((day % pool.count) + pool.count) % pool.count
        return [pool[n], pool[(n + 2) % pool.count], pool[(n + 4) % pool.count]]
    }
}

/// Evolution step: an accessory over the (unchanged) character at level 5, 15 and 30.
enum PetStage: Int, Codable, Comparable, CaseIterable {
    case baby, ribbon, flowers, crown

    static func < (a: PetStage, b: PetStage) -> Bool { a.rawValue < b.rawValue }

    static func forLevel(_ level: Int) -> PetStage { level >= 30 ? .crown : level >= 15 ? .flowers : level >= 5 ? .ribbon : .baby }

    var level: Int { [1, 5, 15, 30][rawValue] }

    var title: String {
        switch self {
        case .baby: return L("아기")
        case .ribbon: return L("리본")
        case .flowers: return L("꽃 화관")
        case .crown: return L("왕관")
        }
    }
}

/// Counters of one calendar day.
struct PetDay: Codable, Equatable {
    var day: Int
    var counts: [PetMissionKind: Int] = [:]
    var done: Set<PetMissionKind> = []
    var coins = 0
    var levelUps = 0
    /// Coins from the 시즌 extras (숨 고르기, 이모트) today, held under their cap.
    var bonus = 0

    subscript(_ kind: PetMissionKind) -> Int { counts[kind] ?? 0 }
    var missions: [PetMissionKind] { PetMissionKind.missions(forDay: day) }
}

struct PetDiaryEntry: Codable, Equatable, Identifiable {
    var day: Int
    var date: Date
    var text: String
    var id: Int { day }
}

/// 집중 타이머 펫: 25 minutes of work, then 5 of rest.
struct PetFocus: Codable, Equatable {
    enum Mode: String, Codable { case work, rest }
    var mode: Mode
    var endsAt: Date

    static let work: TimeInterval = 25 * 60
    static let rest: TimeInterval = 5 * 60
}

/// What a change did, for speech bubbles and the menu bar. The state itself never talks.
enum PetEvent: Equatable {
    case attended(coins: Int, streak: Int)
    case levelUp(Int)
    case evolved(PetStage)
    case missionDone(PetMissionKind, coins: Int)
    case hungry
    case wentAway
    case cameHome
    case focusDone(coins: Int)
    case restDone
    case eyeRest
}

/// The whole pet, as saved (JSON in AppDefaults). Pure: every change takes `now`, nothing reads the clock.
struct PetState: Codable, Equatable {
    var food = 80.0, mood = 80.0, energy = 80.0, clean = 80.0
    var level = 1, xp = 0, coins = 0
    /// Last time the gauges were brought up to date.
    var updated: Date
    /// Last 밥 · 쓰다듬기 · 씻기기. 72 h without care and an empty 배부름 sends the pet out for a walk.
    var lastCare: Date
    /// Set while the pet is out (가출). Gauges stand still; 밥 brings it back.
    var awaySince: Date?
    /// The page has been opened once. Until then the pet stays quiet: no speech, no menu bar hint.
    var adopted = false

    // Room
    var wallpaper = PetCatalog.starterWallpaper
    var floor = PetCatalog.starterFloor
    var owned: Set<String> = PetCatalog.starterItems
    /// Six furniture slots: 0...2 on the wall, 3...5 on the floor.
    var slots: [String?] = [nil, nil, nil, PetCatalog.starterBed, nil, nil]

    // Days
    var today: PetDay
    var diary: [PetDiaryEntry] = []
    /// 집중 잔디: finished 25-minute rounds per past day (day number to count), days with none left out.
    var focusLog: [Int: Int] = [:]
    var attendStreak = 0
    var lastAttendDay: Int?

    // Extras
    var focus: PetFocus?
    var eyeRest = false
    /// Start of the current stretch at the screen (input within the last minute), for 20-20-20.
    var activeSince: Date?
    var resting = false
    var hungryNoted = false

    static let slotCount = 6
    static let wallSlots = 0..<3
    /// Absence counted at most this far back, so a week away is not a starved pet.
    static let maxOffline: TimeInterval = 12 * 3600
    /// Longest gap a signal's own effect (charging, busy, resting) is applied over.
    static let maxLive: TimeInterval = 60
    static let awayAfter: TimeInterval = 72 * 3600
    static let breakIdle: TimeInterval = 5 * 60
    static let restIdle: TimeInterval = 2 * 60
    static let eyeRestEvery: TimeInterval = 20 * 60
    static let maxDiary = 60
    /// Days of 집중 잔디 kept, a year and a week (the page shows 12 weeks).
    static let focusLogDays = 371

    init(now: Date) {
        updated = now
        lastCare = now
        today = PetDay(day: Self.dayNumber(now))
    }

    static func dayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.ordinality(of: .day, in: .era, for: date) ?? 0
    }

    var stage: PetStage { PetStage.forLevel(level) }
    var isAway: Bool { awaySince != nil }
    static func xpNeeded(_ level: Int) -> Int { 20 + level * 10 }

    func value(_ g: PetGauge) -> Double {
        switch g {
        case .food: return food
        case .mood: return mood
        case .energy: return energy
        case .clean: return clean
        }
    }

    mutating func add(_ g: PetGauge, _ delta: Double) {
        func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
        switch g {
        case .food: food = clamp(food + delta)
        case .mood: mood = clamp(mood + delta)
        case .energy: energy = clamp(energy + delta)
        case .clean: clean = clamp(clean + delta)
        }
    }

    // MARK: Time

    /// Brings the gauges, the day, the focus timer and 가출 up to `now`.
    /// Returns the live span in hours (at most `maxLive`) that a signal arriving now may apply its own effect over.
    /// A clock set back is taken as it is (no decay, no reward): `updated`, the last care and a focus timer move back
    /// with it, so the gauges keep going from there. The day and 출석 only ever move forward (rollDay, attend), so going
    /// to a later date and back pays nothing twice.
    @discardableResult
    mutating func advance(to now: Date, events: inout [PetEvent]) -> Double {
        let elapsed = now.timeIntervalSince(updated)
        guard elapsed > 0 else {
            if elapsed < 0 {
                updated = now
                if lastCare > now { lastCare = now }
                if let a = activeSince, a > now { activeSince = now }
                if let f = focus, f.endsAt > now.addingTimeInterval(PetFocus.work) { focus = nil }
            }
            return 0
        }
        updated = now
        if !isAway {
            let hours = min(elapsed, Self.maxOffline) / 3600
            for g in PetGauge.allCases { add(g, -g.decayPerHour * hours) }
        }
        rollDay(now)
        finishFocus(now, events: &events, gap: elapsed)
        if !isAway, food <= 10, now.timeIntervalSince(lastCare) >= Self.awayAfter {
            awaySince = now
            focus = nil
            events.append(.wentAway)
        }
        if food < 25, !hungryNoted, !isAway { hungryNoted = true; events.append(.hungry) }
        if food >= 50 { hungryNoted = false }
        return min(elapsed, Self.maxLive) / 3600
    }

    /// A new calendar day: yesterday's line goes in the diary, the counters start over. Forward only: an earlier date
    /// (the clock set back) keeps today's counters and missions until the real date passes them.
    private mutating func rollDay(_ now: Date) {
        let day = Self.dayNumber(now)
        guard day > today.day else { return }
        if adopted {
            let date = Calendar.current.date(byAdding: .day, value: today.day - day, to: now) ?? now   // only labels the day
            diary.insert(PetDiaryEntry(day: today.day, date: date, text: Self.diaryLine(today, level: level)), at: 0)
            if diary.count > Self.maxDiary { diary.removeLast(diary.count - Self.maxDiary) }
        }
        if today[.focus] > 0 { focusLog[today.day] = today[.focus] }
        focusLog = focusLog.filter { $0.key > day - Self.focusLogDays }
        today = PetDay(day: day)
    }

    /// One line about a day, newest facts first.
    static func diaryLine(_ d: PetDay, level: Int) -> String {
        var parts: [String] = []
        if d[.feed] > 0 { parts.append(L("밥 \(d[.feed])번")) }
        if d[.pet] > 0 { parts.append(L("쓰다듬기 \(d[.pet])번")) }
        if d[.wash] > 0 { parts.append(L("목욕 \(d[.wash])번")) }
        if d[.focus] > 0 { parts.append(L("집중 \(d[.focus])번")) }
        if d[.breaks] > 0 { parts.append(L("쉬는 시간 \(d[.breaks])번")) }
        if d[.cleaner] > 0 { parts.append(L("청소 \(d[.cleaner])번")) }
        var line = parts.isEmpty ? L("조용한 하루였어요.") : parts.joined(separator: ", ") + "."
        if !d.done.isEmpty { line += L(" 미션 \(d.done.count)개 완료.") }
        if d.levelUps > 0 { line += L(" 레벨 \(level)까지 컸어요.") }
        if d.coins > 0 { line += L(" 코인 \(d.coins)개.") }
        return line
    }

    // MARK: Signals

    mutating func apply(_ signal: PetSignal, now: Date) -> [PetEvent] {
        var events: [PetEvent] = []
        let live = advance(to: now, events: &events)
        guard !isAway else { return events }
        switch signal {
        case let .sample(battery, load, idle):
            if let b = battery {
                if b.isCharging { add(.food, 25 * live) }   // 충전 중 = 밥
                // 배터리 20% 이하 = 배고픔 두 배.
                if b.percent <= 20, !b.isPluggedIn { add(.food, -PetGauge.food.decayPerHour * live) }
            }
            if load > 0.6 { add(.energy, -8 * load * live) }
            if idle >= Self.restIdle { add(.energy, 20 * live) }
            if idle >= Self.breakIdle {
                if !resting { resting = true; count(.breaks, events: &events) }
            } else if idle < 60 {
                resting = false
            }
            if idle < 60 {
                if activeSince == nil { activeSince = now }
                if eyeRest, let since = activeSince, now.timeIntervalSince(since) >= Self.eyeRestEvery {
                    activeSince = now
                    events.append(.eyeRest)
                }
                attend(now, events: &events)
            } else {
                activeSince = nil
            }
        case .cleaned(let bytes):
            add(.clean, min(40, 10 + Double(bytes) / 1e9 * 10))
            count(.cleaner, events: &events)
        case .speedTest:
            add(.mood, 15)
            count(.speedTest, events: &events)
        }
        return events
    }

    // MARK: Care

    enum Care { case feed, pet, wash }

    /// 밥 · 쓰다듬기 · 씻기기. 밥 also brings a pet home from its walk. XP only when the gauge really needed it.
    mutating func care(_ c: Care, now: Date) -> [PetEvent] {
        var events: [PetEvent] = []
        advance(to: now, events: &events)
        lastCare = now
        switch c {
        case .feed:
            if isAway {
                awaySince = nil
                mood = max(mood, 40)
                events.append(.cameHome)
            }
            let before = food
            add(.food, 30)
            if food - before >= 5 { gainXP(3, events: &events) }
            count(.feed, events: &events)
            if food >= 50 { hungryNoted = false }
        case .pet:
            guard !isAway else { return events }
            let before = mood
            add(.mood, 20)
            if mood - before >= 5 { gainXP(2, events: &events) }
            count(.pet, events: &events)
        case .wash:
            guard !isAway else { return events }
            let before = clean
            add(.clean, 35)
            if clean - before >= 5 { gainXP(2, events: &events) }
            count(.wash, events: &events)
        }
        attend(now, events: &events)
        return events
    }

    // MARK: Progress

    mutating func gainXP(_ n: Int, events: inout [PetEvent]) {
        xp += n
        while xp >= Self.xpNeeded(level) {
            xp -= Self.xpNeeded(level)
            let old = stage
            level += 1
            today.levelUps += 1
            earn(10 + level, today: true)
            events.append(.levelUp(level))
            if stage != old { events.append(.evolved(stage)) }
        }
    }

    private mutating func earn(_ n: Int, today counts: Bool) {
        coins += n
        if counts { today.coins += n }
    }

    /// 시즌 extras: `n` coins, at most up to `cap` of them a day in all. Returns what was paid.
    @discardableResult
    mutating func bonus(_ n: Int, cap: Int) -> Int {
        let pay = max(0, min(n, cap - today.bonus))
        today.bonus += pay
        earn(pay, today: true)
        return pay
    }

    /// Coins a 시즌 뽑기판 cell gave (bounded by the 뽑기권 behind it).
    mutating func receive(coins n: Int) { earn(max(0, n), today: true) }

    /// Pays `n` coins (a 뽑기권). False, and nothing taken, when there are not enough.
    mutating func spend(_ n: Int) -> Bool {
        guard n >= 0, coins >= n else { return false }
        coins -= n
        return true
    }

    /// Counts one thing for today and pays any mission it completes (each mission once a day).
    mutating func count(_ kind: PetMissionKind, events: inout [PetEvent]) {
        today.counts[kind, default: 0] += 1
        guard today.missions.contains(kind), !today.done.contains(kind), today[kind] >= kind.target else { return }
        today.done.insert(kind)
        earn(kind.reward, today: true)
        gainXP(5, events: &events)
        events.append(.missionDone(kind, coins: kind.reward))
    }

    /// 출석: the first time today the user is at the Mac (or cares for the pet). A streak pays a little more, up to a week.
    /// Only a day after the last paid one counts, so switching the date back and forth pays once.
    mutating func attend(_ now: Date, events: inout [PetEvent]) {
        let day = Self.dayNumber(now)
        guard day > (lastAttendDay ?? Int.min) else { return }
        attendStreak = lastAttendDay == day - 1 ? attendStreak + 1 : 1
        lastAttendDay = day
        let pay = 10 + min(attendStreak - 1, 6) * 2
        earn(pay, today: true)
        events.append(.attended(coins: pay, streak: attendStreak))
    }

    // MARK: Focus

    mutating func startFocus(now: Date) {
        focus = PetFocus(mode: .work, endsAt: now.addingTimeInterval(PetFocus.work))
    }

    mutating func stopFocus() { focus = nil }

    /// Finished rounds on a day, today's live count included.
    func focusCount(_ day: Int) -> Int { day == today.day ? today[.focus] : focusLog[day] ?? 0 }

    /// The day with the most rounds in `days` (the latest on a tie), nil when none had any.
    func focusBest(_ days: ClosedRange<Int>) -> (day: Int, count: Int)? {
        days.reduce(nil) { best, d in
            let n = focusCount(d)
            return n > 0 && n >= (best?.count ?? 0) ? (d, n) : best
        }
    }

    /// A finished 25 minutes pays and starts the 5-minute rest. A timer that ran out while the app was closed
    /// (over 2 minutes ago), or across a jump of over 2 minutes (the clock moved ahead, or the Mac slept through the end),
    /// is dropped without pay, so neither quitting nor the clock can farm coins. `gap` is the time since the last update.
    mutating func finishFocus(_ now: Date, events: inout [PetEvent], gap: TimeInterval = 0) {
        guard let f = focus, f.endsAt <= now else { return }
        guard now.timeIntervalSince(f.endsAt) < 120, f.mode == .rest || gap < 120 else { focus = nil; return }
        switch f.mode {
        case .work:
            earn(15, today: true)
            events.append(.focusDone(coins: 15))
            gainXP(5, events: &events)
            focus = PetFocus(mode: .rest, endsAt: f.endsAt.addingTimeInterval(PetFocus.rest))
            count(.focus, events: &events)
        case .rest:
            focus = nil
            events.append(.restDone)
        }
    }

    // MARK: Room

    /// Buys with coins (no cash, no random boxes). False when already owned, unknown or too dear.
    mutating func buy(_ id: String) -> Bool {
        guard let item = PetCatalog.item(id), !owned.contains(id), coins >= item.price else { return false }
        coins -= item.price
        owned.insert(id)
        return true
    }

    /// Puts an owned piece in `slot` (nil empties it). Wall pieces only on the wall slots, floor pieces only on the floor.
    /// A piece already standing elsewhere moves.
    mutating func place(_ id: String?, slot: Int) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        if let id {
            guard owned.contains(id), let item = PetCatalog.item(id), item.kind == (Self.wallSlots.contains(slot) ? .wall : .floor) else { return false }
            for i in slots.indices where slots[i] == id { slots[i] = nil }
        }
        slots[slot] = id
        return true
    }

    /// Wallpaper or floor covering, owned ones only.
    mutating func cover(_ id: String) -> Bool {
        guard owned.contains(id), let item = PetCatalog.item(id) else { return false }
        switch item.kind {
        case .wallpaper: wallpaper = id
        case .floorTile: floor = id
        case .wall, .floor: return false
        }
        return true
    }
}

// MARK: - Lenient loading

/// Saved pets load whatever a newer or older version wrote: a missing field takes its default, an unknown mission or
/// focus mode is dropped, the room always has `slotCount` slots. A pet is never reset because one field changed.
extension PetDay {
    private enum Keys: String, CodingKey { case day, counts, done, coins, levelUps, bonus }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        day = try c.decodeIfPresent(Int.self, forKey: .day) ?? 0
        coins = (try? c.decodeIfPresent(Int.self, forKey: .coins)) ?? 0
        levelUps = (try? c.decodeIfPresent(Int.self, forKey: .levelUps)) ?? 0
        bonus = (try? c.decodeIfPresent(Int.self, forKey: .bonus)) ?? 0
        done = Set(((try? c.decodeIfPresent([String].self, forKey: .done)) ?? []).compactMap(PetMissionKind.init(rawValue:)))
        // A dictionary with enum keys is saved as [key, value, key, value, ...].
        var counts: [PetMissionKind: Int] = [:]
        if var list = try? c.nestedUnkeyedContainer(forKey: .counts) {
            while !list.isAtEnd {
                guard let k = try? list.decode(String.self), let v = try? list.decode(Int.self) else { break }
                if let kind = PetMissionKind(rawValue: k) { counts[kind] = v }
            }
        } else if let keyed = try? c.decodeIfPresent([String: Int].self, forKey: .counts) {
            for (k, v) in keyed { if let kind = PetMissionKind(rawValue: k) { counts[kind] = v } }
        }
        self.counts = counts
    }
}

extension PetState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        // Without a time stamp the save is not a pet at all.
        let updated: Date = try c.decode(Date.self, forKey: .updated)
        self.init(now: updated)
        food = get(.food) ?? food; mood = get(.mood) ?? mood; energy = get(.energy) ?? energy; clean = get(.clean) ?? clean
        level = get(.level) ?? level; xp = get(.xp) ?? xp; coins = get(.coins) ?? coins
        lastCare = get(.lastCare) ?? updated
        awaySince = get(.awaySince)
        adopted = get(.adopted) ?? adopted
        wallpaper = get(.wallpaper) ?? wallpaper
        floor = get(.floor) ?? floor
        owned = get(.owned) ?? owned
        let saved: [String?] = get(.slots) ?? slots
        slots = Array((saved + Array(repeating: nil, count: Self.slotCount)).prefix(Self.slotCount))
        today = get(.today) ?? today
        diary = get(.diary) ?? diary
        focusLog = get(.focusLog) ?? focusLog
        attendStreak = get(.attendStreak) ?? attendStreak
        lastAttendDay = get(.lastAttendDay)
        focus = get(.focus)
        eyeRest = get(.eyeRest) ?? eyeRest
        activeSince = get(.activeSince)
        resting = get(.resting) ?? resting
        hungryNoted = get(.hungryNoted) ?? hungryNoted
    }
}
