import Foundation

/// The three situations that can swap the normal load pose for an extra motion.
enum Situation: String, CaseIterable, Codable {
    case lowBattery, charging, busy

    var label: String {
        switch self {
        case .lowBattery: return L("배터리 부족")
        case .charging: return L("충전 중")
        case .busy: return L("바쁠 때")
        }
    }

    var defaultMotion: ExtraMotion {
        switch self {
        case .lowBattery: return .hungry
        case .charging: return .eat
        case .busy: return .special
        }
    }

    /// (seconds shown, seconds per cycle) at 보통.
    var cadence: (show: TimeInterval, every: TimeInterval) {
        switch self {
        case .lowBattery: return (8, 40)
        case .charging: return (10, 300)
        case .busy: return (6, 30)
        }
    }
}

enum MotionChoice: Codable, Hashable {
    case standard, off, motion(ExtraMotion)
}

enum MotionFrequency: String, CaseIterable, Codable {
    case often, normal, rarely

    var label: String {
        switch self {
        case .often: return L("자주")
        case .normal: return L("보통")
        case .rarely: return L("가끔")
        }
    }

    /// Multiplies the cycle length; how long a motion shows stays the same.
    var periodScale: Double {
        switch self {
        case .often: return 0.5
        case .normal: return 1
        case .rarely: return 2
        }
    }
}

/// What the user picked per situation.
struct MotionPrefs: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var choice: MotionChoice = .standard
        var frequency: MotionFrequency = .normal
    }

    var lowBattery = Entry()
    var charging = Entry()
    var busy = Entry()

    static let defaults = MotionPrefs()
    static let key = "motionPrefs"

    subscript(_ s: Situation) -> Entry {
        get {
            switch s {
            case .lowBattery: return lowBattery
            case .charging: return charging
            case .busy: return busy
            }
        }
        set {
            switch s {
            case .lowBattery: lowBattery = newValue
            case .charging: charging = newValue
            case .busy: busy = newValue
            }
        }
    }

    /// The motion `s` shows on a character with `available` extras, nil when nothing should show.
    func motion(for s: Situation, available: Set<ExtraMotion>) -> ExtraMotion? {
        let m: ExtraMotion
        switch self[s].choice {
        case .off: return nil
        case .standard: m = s.defaultMotion
        case .motion(let x): m = x
        }
        return available.contains(m) ? m : nil
    }

    static func load(_ defaults: UserDefaults = AppDefaults.store) -> MotionPrefs {
        guard let data = defaults.data(forKey: key), let p = try? JSONDecoder().decode(MotionPrefs.self, from: data) else { return .defaults }
        return p
    }

    func save(_ defaults: UserDefaults = AppDefaults.store) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Decides, once per tick, whether an extra motion replaces the normal pose. Pure: all inputs are passed in,
/// the only state is when each situation started, so cycles line up with the moment it began.
///  - battery <= 20 % and not charging: hungry 8 s every 40 s
///  - charging: eat for 20 s when charging starts, then 10 s every 5 min
///  - pose sprint/exhausted on a character with .special: special 6 s every 30 s
///  - no battery (desktop Mac): never hungry or eat
/// Priority when two overlap: charging, then low battery, then busy. A moment from play() beats all three.
struct SituationEngine {
    static let lowThreshold = 20
    static let chargeBurst: TimeInterval = 20
    static let burstCap: TimeInterval = 15

    /// The one-off moment playing now (play), shared by every engine. Main thread.
    static var burst: (prefer: [ExtraMotion], until: Date)?

    /// Plays the first motion of `prefer` the character has, for `seconds` (at most 15), over any situation; none
    /// of them drawn = no change. For events: SituationEngine.play([.special]) on a calendar alert. Main thread.
    static func play(_ prefer: [ExtraMotion], seconds: TimeInterval = 8, now: Date = Date()) {
        burst = (prefer, now.addingTimeInterval(min(max(0, seconds), burstCap)))
    }

    /// Whether a moment from play() shows now (출근·퇴근 인사 never cut a calendar alert short). Main thread.
    static func playing(now: Date = Date()) -> Bool { burst.map { now < $0.until } ?? false }

    var prefs: MotionPrefs = .defaults
    private(set) var since: [Situation: Date] = [:]

    init(prefs: MotionPrefs = .defaults) { self.prefs = prefs }

    static func active(_ s: Situation, battery: BatteryStats?, pose: DogPose) -> Bool {
        switch s {
        case .lowBattery: return battery.map { $0.percent <= lowThreshold && !$0.isCharging } ?? false
        case .charging: return battery?.isCharging ?? false
        case .busy: return pose == .sprint || pose == .exhausted
        }
    }

    /// Whether the cycle of `s`, `elapsed` seconds after it began, is in its showing part.
    func showing(_ s: Situation, elapsed: TimeInterval) -> Bool {
        let c = s.cadence
        let every = c.every * prefs[s].frequency.periodScale
        if s == .charging {
            if elapsed < Self.chargeBurst { return true }
            return elapsed >= every && elapsed.truncatingRemainder(dividingBy: every) < c.show
        }
        return elapsed.truncatingRemainder(dividingBy: every) < c.show
    }

    /// The extra motion to show at `now`, or nil for the normal pose. Call every tick (any rate); keeps start times.
    mutating func update(battery: BatteryStats?, pose: DogPose, available: Set<ExtraMotion>, now: Date = Date()) -> ExtraMotion? {
        var result: ExtraMotion?
        for s in [Situation.charging, .lowBattery, .busy] {
            guard Self.active(s, battery: battery, pose: pose) else { since[s] = nil; continue }
            let start = since[s] ?? now
            since[s] = start
            if result == nil, let m = prefs.motion(for: s, available: available),
               showing(s, elapsed: now.timeIntervalSince(start)) {
                result = m
            }
        }
        if let b = Self.burst {
            if now >= b.until { Self.burst = nil }
            else if let m = b.prefer.first(where: available.contains) { return m }
        }
        return result
    }
}
