import AppKit

/// 친구들끼리: the rules of the group games (복제 친구 술래잡기·기차놀이, 풀밭 친구들 줄넘기, 단체 춤). Pure and tested
/// (GroupPlayTests); DesktopClones and MeadowFriends run them in their own tick, so nothing new ticks while no game is on.
enum GroupPlay {
    /// After this long between games (seconds) friends with a game switched on start one on their own.
    static func gap(random: Double) -> TimeInterval { 120 + 180 * random }
}

/// 술래잡기: the 술래 runs after the nearest friend, the others run away, a touch passes it on.
enum CloneTag {
    /// A round, then everyone sits down for a rest.
    static let round: TimeInterval = 20
    /// The new 술래 counts this long before it runs.
    static let count: TimeInterval = 1

    /// Who the 술래 at `it` runs after: the nearest, never `immune` (who just passed it on) while another is left.
    static func quarry(it: Int, at points: [CGPoint], immune: Int?) -> Int? {
        guard points.indices.contains(it) else { return nil }
        let others = points.indices.filter { $0 != it }
        let pick = others.count > 1 ? others.filter { $0 != immune } : others
        return pick.min { dist(points[$0], points[it]) < dist(points[$1], points[it]) }
    }

    /// Caught: the nearest one within `reach` of the 술래, never `immune`.
    static func tagged(it: Int, at points: [CGPoint], reach: CGFloat, immune: Int?) -> Int? {
        guard points.indices.contains(it) else { return nil }
        return points.indices.filter { $0 != it && $0 != immune && dist(points[$0], points[it]) <= reach }
            .min { dist(points[$0], points[it]) < dist(points[$1], points[it]) }
    }

    /// Where a runner at `me` runs, `run` points away from the 술래 at `it`, kept within `lo...hi`. Cornered against a
    /// wall it doubles back past the 술래 instead.
    static func flee(me: CGFloat, it: CGFloat, lo: CGFloat, hi: CGFloat, run: CGFloat) -> CGFloat {
        let away: CGFloat = me >= it ? 1 : -1
        let to = me + away * run
        if to >= lo, to <= hi { return to }
        let room = away > 0 ? hi - me : me - lo
        if room > run / 3 { return min(max(to, lo), hi) }
        return min(max(it - away * run, lo), hi)   // no room left: back past it
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// 기차놀이: the way the 커서 친구 went, newest point last; the cars stand along it, one behind another.
struct TrainPath: Equatable {
    private(set) var points: [CGPoint] = []
    /// Longer than this the oldest end is dropped.
    var maxLength: CGFloat

    init(maxLength: CGFloat) { self.maxLength = maxLength }

    /// The leader is at `p` now; a move under 2 points is not a step.
    mutating func add(_ p: CGPoint) {
        if let l = points.last, hypot(p.x - l.x, p.y - l.y) < 2 { return }
        points.append(p)
        var length: CGFloat = 0
        for i in stride(from: points.count - 1, to: 0, by: -1) {
            length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            if length > maxLength { points.removeFirst(i - 1); return }
        }
    }

    /// The point `d` along the path behind the leader; the oldest one when the path is shorter; nil when empty.
    func point(behind d: CGFloat) -> CGPoint? {
        guard var p = points.last else { return nil }
        var left = max(0, d)
        for q in points.dropLast().reversed() {
            let seg = hypot(p.x - q.x, p.y - q.y)
            if seg >= left, seg > 0 {
                let k = left / seg
                return CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)
            }
            left -= seg
            p = q
        }
        return p
    }
}

/// 줄넘기: two friends turn the rope, the rest jump it. The rope starts over their heads and passes their feet halfway
/// round; a jumper hops so it is up in the air then.
struct JumpRope: Equatable {
    /// One turn of the rope.
    static let period: TimeInterval = 1.1
    /// A MeadowWalk hop's time in the air.
    static let airtime = TimeInterval(2 * MeadowWalk.hopSpeed / MeadowWalk.gravity)
    /// A round, about fifteen jumps.
    static let round: TimeInterval = 18
    /// A streak this long gets a cheer.
    static let cheerAt = 10

    var start: TimeInterval

    /// The rope's height now: 1 over their heads, -1 at their feet.
    func swing(at t: TimeInterval) -> CGFloat { CGFloat(cos(2 * .pi * (t - start) / Self.period)) }
    /// Whether the rope is on its way up the far side (drawn behind the friends) or coming down the near one.
    func behind(at t: TimeInterval) -> Bool { sin(2 * .pi * (t - start) / Self.period) > 0 }
    /// When the rope passes their feet for the `k`th time (0 first).
    func under(_ k: Int) -> TimeInterval { start + (Double(k) + 0.5) * Self.period }
    /// When to hop for pass `k`: up at the top of the hop as it passes.
    func hop(_ k: Int) -> TimeInterval { under(k) - Self.airtime / 2 }
    /// The passes over by `t`.
    func passes(at t: TimeInterval) -> Int { max(0, Int(((t - start) / Self.period - 0.5).rounded(.down)) + 1) }
}

/// Jumps in a row: a miss starts over; true once, as the streak reaches JumpRope.cheerAt.
struct RopeStreak: Equatable {
    private(set) var count = 0
    mutating func pass(cleared: Bool) -> Bool {
        count = cleared ? count + 1 : 0
        return count == JumpRope.cheerAt
    }
}

/// 단체 춤 (기념일): the app keeps no birthday, so a celebration (춤춰 줘·응원해 줘·a focus well done) is the day; every
/// friend dances to one beat for `length`.
enum GroupDance {
    static let key = "friends.dance"
    static let length: TimeInterval = 10
    static let beat: TimeInterval = 0.5

    static var on: Bool { AppDefaults.store.bool(forKey: key) }

    /// Beat number `elapsed` into the dance; nil once it is over.
    static func beat(_ elapsed: TimeInterval) -> Int? {
        elapsed >= 0 && elapsed < length ? Int(elapsed / beat) : nil
    }

    /// On beat `n`: which way everyone faces and whether they hop (every other beat, a ♪ every fourth).
    static func move(_ n: Int) -> (facingLeft: Bool, hop: Bool, note: Bool) {
        (n % 2 == 1, n % 2 == 0, n % 4 == 0)
    }
}
