import CharaCore
import CoreGraphics
import Foundation

/// What the character does by itself on the home screen, like the Mac menu bar: charging = eat, low battery = hungry,
/// night = sleepy, else a stroll. Pure; the tests feed it.
enum Idle: Equatable {
    case stroll, eat, hungry, sleepy

    /// The Mac's SituationEngine threshold: 20 % and not charging is hungry.
    static let lowBattery = 0.2

    /// `battery` 0...1, nil when unknown (the simulator); `hour` 0...23. Charging wins, then low battery, then night.
    static func now(battery: Double?, charging: Bool, hour: Int) -> Idle {
        if charging { return .eat }
        if let b = battery, b <= lowBattery { return .hungry }
        if hour >= 23 || hour < 6 { return .sleepy }
        return .stroll
    }

    var pose: DogPose { self == .sleepy ? .lying : .slowWalk }

    var extra: ExtraMotion? {
        switch self {
        case .eat: .eat
        case .hungry: .hungry
        default: nil
        }
    }

    var label: String {
        switch self {
        case .stroll: L("느긋하게 산책 중이에요")
        case .eat: L("충전하며 냠냠 먹는 중이에요")
        case .hungry: L("배고파요, 충전해 주세요")
        case .sleepy: L("밤이라 쿨쿨 자는 중이에요")
        }
    }
}

/// What a tap does: the Mac 커서 친구's Reactions (DesktopKit), their move and the mark over the head.
enum Reaction: String, CaseIterable {
    case hearts, jump, spin, blush, surprised, giggle, sneeze, dizzy, pout

    /// The everyday ones, picked at random; `dizzy` and `pout` come from tapping again and again (TapCombo).
    static let cute: [Reaction] = [.hearts, .jump, .spin, .blush, .surprised, .giggle, .sneeze]

    var duration: TimeInterval {
        switch self {
        case .jump: 0.9
        case .spin, .surprised: 1.0
        case .hearts, .giggle, .sneeze: 1.2
        case .blush: 1.4
        case .dizzy, .pout: 2.2
        }
    }

    /// Its frames: the happy 특기 ones, the hungry ones for a pout (the Mac's sulk), else the pose it is in.
    var extra: ExtraMotion? {
        switch self {
        case .hearts, .giggle, .blush: .special
        case .pout: .hungry
        default: nil
        }
    }

    var mark: String? {
        switch self {
        case .hearts: "♥"
        case .surprised: "!"
        case .blush: "///"
        case .giggle: "♪"
        case .sneeze: L("에취!")
        case .dizzy: "@"
        case .pout: L("흥!")
        case .jump, .spin: nil
        }
    }

    /// What it says, before its persona dresses it (the Mac's MeadowReaction lines).
    var lines: [String] {
        switch self {
        case .dizzy: [L("어질어질…"), L("세상이 빙글빙글 돌아요"), L("눈앞이 핑핑 돌아요")]
        case .pout: [L("그만 눌러요, 흥!"), L("이제 안 놀아 줄 거예요")]
        default: [L("헤헤, 불렀어요?"), L("안녕! 오늘도 같이 놀아요"), L("간지러워요"), L("뭐 하고 있어요?"), L("저 여기 있어요!")]
        }
    }

    /// Long-pressed (쓰다듬기).
    static var petLines: [String] { [L("쓰담쓰담 좋아요"), L("헤헤, 기분 좋아요"), L("더 쓰다듬어 주세요")] }

    /// The move `t` seconds in: `lift` as a share of its height, a turn in radians, and a squash. Flat when done.
    func pose(_ t: TimeInterval) -> (lift: CGFloat, angle: CGFloat, sx: CGFloat, sy: CGFloat) {
        guard t >= 0, t < duration else { return (0, 0, 1, 1) }
        func arc(_ over: TimeInterval) -> CGFloat {   // one hop over the first `over` seconds, 0...1
            guard t < over else { return 0 }
            let u = CGFloat(t / over)
            return 4 * u * (1 - u)
        }
        let deg = CGFloat.pi / 180
        switch self {
        case .hearts: return (arc(0.4) * 0.15, 0, 1, 1)
        case .jump: return (arc(0.6) * 0.6, 0, 1, 1)
        case .spin: return t < 0.6 ? (arc(0.6) * 0.15, 2 * .pi * CGFloat(t / 0.6), 1, 1) : (0, 0, 1, 1)
        case .surprised: return (arc(0.3) * 0.25, 0, t < 0.3 ? 0.94 : 1, t < 0.3 ? 1.08 : 1)
        case .giggle: return (0, 4 * deg * CGFloat(sin(t * 40)), 1, 1)
        case .blush: return (0, 3 * deg * CGFloat(sin(t * 8)), 1, 0.97)
        case .dizzy: return (0, 8 * deg * CGFloat(sin(t * 6)), 1, 1)
        case .sneeze:
            if t < 0.5 { let u = CGFloat(t / 0.5); return (0, 0, 1 + 0.05 * u, 1 - 0.15 * u) }   // 에... gathering
            let v = max(0, 1 - CGFloat((t - 0.5) / 0.3))   // 취! a jolt that fades
            return (0, 0, 1 + 0.1 * v, 1 - 0.1 * v)
        case .pout: return (0, 0, 1, 1)
        }
    }
}

/// Taps in a row (the Mac's ClickCombo): each within `gap` of the last counts up. The third makes it dizzy, the fifth
/// makes it pout and starts over; the rest are a random cute reaction.
struct TapCombo {
    static let gap: TimeInterval = 0.7
    private(set) var count = 0
    private var last: TimeInterval = -10

    mutating func tap(at t: TimeInterval, pick: ([Reaction]) -> Reaction = { $0.randomElement()! }) -> Reaction {
        count = t - last <= Self.gap ? count + 1 : 1
        last = t
        if count == 3 { return .dizzy }
        if count >= 5 { count = 0; return .pout }
        return pick(Reaction.cute)
    }
}

/// The 집중 타이머's words and numbers. Pure.
enum FocusTalk {
    /// The phone's own calendar day ("2026-10-23"), not UTC's.
    static func day(_ date: Date, in zone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day())
    }

    /// The kept tally (`day`, minutes) after a run of `minutes` that ended on `day`: it counts on that day, even when
    /// the app hears of it a day later. A run from before the day already counting is dropped.
    static func tally(_ minutes: Int, on day: String, kept: (day: String, minutes: Int)) -> (day: String, minutes: Int) {
        if day == kept.day { return (day, kept.minutes + minutes) }
        return day > kept.day ? (day, minutes) : kept
    }

    /// "05:00", "25:00".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded(.up)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The friend talking, by how far the run is (`left` of `total` seconds) and the time of day (the Mac's mood).
    static func mood(left: TimeInterval, total: TimeInterval, hour: Int) -> String {
        if hour >= 23 || hour < 5 { return L("늦은 밤 집중 🌙") }
        let m = (total - left) / 60
        if m < 5 { return (6..<9).contains(hour) ? L("아침 집중 ☀️") : L("시작이 반!") }
        if left < 5 * 60 { return L("거의 다 왔어요!") }
        if m < 20 { return L("집중 시작!") }
        return L("몰입 중이에요 ✨")
    }

    /// The home screen's 오늘 line, by the hour and the minutes focused today.
    static func today(hour: Int, focused: Int) -> String {
        let hello = switch hour {
        case 5..<11: L("좋은 아침이에요")
        case 11..<17: L("좋은 오후예요")
        case 17..<23: L("오늘도 수고했어요")
        default: L("늦은 밤이에요, 푹 쉬어요")
        }
        return focused > 0 ? L("\(hello) · 오늘 \(focused)분 집중했어요") : hello
    }
}
