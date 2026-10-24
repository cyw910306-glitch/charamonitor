import AppKit
import QuartzCore

// MARK: Rules (pure)

/// A star (or a treat, worth more) to pick up, its middle in screen points (y up).
struct StarSpot: Equatable {
    var center: CGPoint
    var treat = false
    /// Game seconds when it goes and another one comes somewhere else (its edge may have moved away).
    var until: TimeInterval = 0

    var points: Int { treat ? StarRules.treatPoints : 1 }
}

/// 별 줍기's rules: where stars may come out, so each one can be reached from the ground, and what a touch picks up.
/// Pure and tested (StarGameTests).
enum StarRules {
    static let seconds: TimeInterval = 60
    static let onScreen = 5
    static let life: ClosedRange<TimeInterval> = 9...14
    static let treatPoints = 3
    /// Highest a hop carries the feet over the edge it left: a double jump peaks near 279 pt, minus room for error.
    static let hop: CGFloat = 220
    /// Furthest sideways from one edge to the next in one jump (walking speed for a double jump's time in the air).
    static let sideways: CGFloat = 160
    /// A star in mid-air sits this far over the middle of a player standing on its edge: some need the double jump.
    static let lift: ClosedRange<CGFloat> = 70...200
    static let bestKey = "play.bestStars"

    /// The edges a player can get onto from the solid ground: each one within a hop up (or anything below) and
    /// `sideways` across from one already reached.
    static func reachable(_ all: [PlayPlatform]) -> [PlayPlatform] {
        var reached = all.filter(\.solid), left = all.filter { !$0.solid }
        func near(_ p: PlayPlatform, _ q: PlayPlatform) -> Bool {
            p.y - q.y <= hop && max(p.minX - q.maxX, q.minX - p.maxX) <= sideways
        }
        while let i = left.firstIndex(where: { p in reached.contains { near(p, $0) } }) { reached.append(left.remove(at: i)) }
        return reached
    }

    /// A new spot on a reachable edge or in mid-air over one, for a star `radius` round and a player `body` big, under
    /// `top` (the visible frame's top) and not on top of `avoid` (the other stars, the players). nil with nowhere to go.
    static func spawn<R: RandomNumberGenerator>(on platforms: [PlayPlatform], top: CGFloat, radius: CGFloat, body: CGSize,
                                                avoid: [CGPoint], using rng: inout R) -> StarSpot? {
        let inset = max(radius, body.width / 2)
        let edges = reachable(platforms).filter { $0.maxX - $0.minX >= inset * 2 && $0.y + body.height / 2 + radius <= top }
        guard !edges.isEmpty else { return nil }
        var best: StarSpot?
        for _ in 0..<12 {
            let e = edges.randomElement(using: &rng)!
            let up = Double.random(in: 0...1, using: &rng) < 0.4 ? CGFloat.random(in: lift, using: &rng) : 0
            let c = CGPoint(x: CGFloat.random(in: e.minX + inset...e.maxX - inset, using: &rng),
                            y: min(e.y + body.height / 2 + up, top - radius))
            let spot = StarSpot(center: c, treat: Double.random(in: 0...1, using: &rng) < 0.2)
            best = spot
            if avoid.allSatisfy({ hypot($0.x - c.x, $0.y - c.y) >= radius * 3 }) { break }
        }
        return best
    }

    /// The stars a player drawn at `player` touches (its sides trimmed: the drawing has air round it).
    static func touched(_ stars: [StarSpot], radius: CGFloat, by player: CGRect) -> [Int] {
        let hit = player.insetBy(dx: player.width * 0.15, dy: 0)
        return stars.indices.filter {
            hit.intersects(CGRect(x: stars[$0].center.x - radius, y: stars[$0].center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// 별 대결 over the network: the `index`th star from `seed`, the same on both Macs: across the ground (0...1 of
    /// the visible frame's width), how far up in points (0 or `lift`), a treat or not, and how long it stays.
    static func netSpot(seed: UInt64, index: Int) -> (x: CGFloat, up: CGFloat, treat: Bool, life: TimeInterval) {
        var rng = SplitMix64(seed: seed ^ UInt64(index) &* 0x9E3779B97F4A7C15)
        let up = Double.random(in: 0...1, using: &rng) < 0.4 ? CGFloat.random(in: lift, using: &rng) : 0
        let x = CGFloat.random(in: 0...1, using: &rng), treat = Double.random(in: 0...1, using: &rng) < 0.2
        return (x, up, treat, .random(in: life, using: &rng))
    }

    /// The saved 별 줍기 best; anything that is not a count reads as none yet.
    static func best(in store: UserDefaults) -> Int { max(0, store.integer(forKey: bestKey)) }

    /// Saves `score` when it beats the best; true when it did.
    @discardableResult
    static func record(_ score: Int, in store: UserDefaults) -> Bool {
        guard score > best(in: store) else { return false }
        store.set(score, forKey: bestKey)
        return true
    }
}

/// A seeded generator, so two Macs draw the same numbers (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: The game

/// 별 줍기 (one player, 60 seconds, the best saved) and 2인 대결 (P2 on WASD, separate scores) on 놀이 모드: stars on
/// window tops, the ground over the Dock and in mid-air, a small HUD at the top of the session's screen (an overlay
/// layer, no window of its own), a sparkle and a chime per pickup. Esc, time up or anything else that ends the
/// session ends the game with a result bubble. 별 대결 (같이 놀기) is a duel with a `seed`: the stars come from it,
/// along the ground, so both Macs show the same ones; P2 is the friend's Mac (NetPlay), which scores itself. Nothing exists or runs outside a game.
final class StarGame {
    static let shared = StarGame()

    private(set) var isOn = false
    private var duel = false
    private var stars: [(spot: StarSpot, layer: CATextLayer, id: Int)] = []
    private var seed: UInt64?
    private var spawned = 0
    private var names = ["1P", "2P"]
    /// [P1, P2]; in 별 대결 P2 is the friend's score as their Mac sends it.
    private(set) var scores = [0, 0]
    private var clock: TimeInterval = 0
    private var hud: CATextLayer?
    private var shown = ""
    private var best = 0
    private var radius: CGFloat = 14
    private var scale: CGFloat = 2

    /// Starts 놀이 모드 from `source` when it is not on, then the game; nothing while a game is on.
    /// `seed` and `rival` (the friend's name) for 별 대결.
    func start(duel: Bool, from source: PlayMode.Source = .buddy, seed: UInt64? = nil, rival: String? = nil) {
        let play = PlayMode.shared
        guard !isOn else { return }
        if !play.isPlaying { play.start(source) }
        guard play.isPlaying, let world = play.overlay() else { return }
        play.twoPlayer = duel && seed == nil   // 별 줍기 is one player's score; in 별 대결 P2 is on the friend's Mac
        isOn = true
        self.duel = duel
        scores = [0, 0]
        self.seed = seed
        spawned = 0
        names = seed == nil ? ["1P", "2P"] : [SocialBus.shared.nickname, rival ?? "2P"]
        clock = 0
        shown = ""
        stars = []
        best = StarRules.best(in: AppDefaults.store)
        let body = play.player()?.size ?? CGSize(width: 48, height: 48)
        radius = max(10, body.height * 0.22)
        scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: play.visible.midX, y: play.visible.midY)) }?.backingScaleFactor ?? 2
        let h = CALayer(), label = CATextLayer()
        h.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        h.cornerRadius = 10
        label.contentsScale = scale
        label.alignmentMode = .center
        for l in [h, label] { l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()] }
        h.addSublayer(label)
        world.addSublayer(h)
        hud = label
        play.onTick.append { [weak self] dt in self?.tick(dt) }
        play.onEnd.append { [weak self] in self?.finish() }
        refill()
        drawHUD()
    }

    private func tick(_ dt: TimeInterval) {
        let play = PlayMode.shared
        clock += dt
        for i in 0..<(duel && seed == nil ? 2 : 1) {
            guard let r = play.player(i) else { continue }
            for j in StarRules.touched(stars.map(\.spot), radius: radius, by: r).reversed() { pick(j, by: i) }
        }
        for j in stars.indices.reversed() where stars[j].spot.until <= clock { stars.remove(at: j).layer.removeFromSuperlayer() }
        refill()
        drawHUD()
        if clock >= StarRules.seconds { play.end() }   // finish() runs from onEnd
    }

    private func pick(_ j: Int, by player: Int) {
        let (spot, layer, id) = stars.remove(at: j)
        layer.removeFromSuperlayer()
        scores[player] += spot.points
        if seed != nil { NetPlay.shared.took(id) }
        if let world = PlayMode.shared.overlay() {
            let r = radius * 2
            FriendMark.pop(spot.treat ? "♥" : "✦", color: .systemYellow, over: CGRect(x: spot.center.x - r, y: spot.center.y - r, width: r * 2, height: r * 2),
                           in: world, still: DesktopKit.reduceMotion, scale: scale)
        }
        ChimeSound.play(scores[player], volume: 0.4)
    }

    /// The stars out now, by id (QA, tests).
    var spots: [(id: Int, spot: StarSpot)] { stars.map { ($0.id, $0.spot) } }

    /// P1's score, for the friend's Mac.
    var score: Int { scores[0] }

    /// 별 대결: the friend picked up that star (gone here too) or now has that many points.
    func remote(took id: Int) {
        guard isOn, let j = stars.firstIndex(where: { $0.id == id }) else { return }
        stars.remove(at: j).layer.removeFromSuperlayer()
    }

    func remote(score: Int) {
        guard isOn, seed != nil else { return }
        scores[1] = max(0, score)
    }

    /// Up to `onScreen` stars, each new one away from the rest and the players.
    private func refill() {
        let play = PlayMode.shared
        guard let world = play.overlay(), let body = play.player()?.size else { return }
        let players = (0..<2).compactMap { play.player($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        var rng = SystemRandomNumberGenerator()
        while stars.count < StarRules.onScreen {
            var s: StarSpot
            if let seed {   // ponytail: along the ground only, never kept apart, so both Macs agree with nothing sent
                let n = StarRules.netSpot(seed: seed, index: spawned), v = play.visible, inset = max(radius, body.width / 2)
                s = StarSpot(center: CGPoint(x: v.minX + inset + n.x * (v.width - inset * 2), y: min(v.minY + body.height / 2 + n.up, v.maxY - radius)),
                             treat: n.treat, until: clock + n.life)
            } else {
                guard let spot = StarRules.spawn(on: play.platforms(), top: play.visible.maxY, radius: radius, body: body,
                                                 avoid: stars.map(\.spot.center) + players, using: &rng) else { return }
                s = spot
                s.until = clock + .random(in: StarRules.life)
            }
            let l = CATextLayer()
            l.string = s.treat ? "🍪" : "⭐"
            l.fontSize = radius * 1.6
            l.alignmentMode = .center
            l.contentsScale = scale
            l.frame = CGRect(x: s.center.x - radius * 1.2, y: s.center.y - radius * 1.1, width: radius * 2.4, height: radius * 2.2)
            if !DesktopKit.reduceMotion {   // a gentle bob, run by Core Animation (no timer of ours)
                let bob = CABasicAnimation(keyPath: "position.y")
                bob.byValue = radius * 0.3
                bob.duration = 0.8
                bob.autoreverses = true
                bob.repeatCount = .infinity
                bob.timeOffset = .random(in: 0...0.8)
                l.add(bob, forKey: nil)
            }
            world.addSublayer(l)
            stars.append((s, l, spawned))
            spawned += 1
        }
    }

    /// Redrawn only when what it says changed (once a second, or a pickup).
    private func drawHUD() {
        guard let hud else { return }
        let left = Int(max(0, StarRules.seconds - clock).rounded(.up))
        let text = duel ? "\(names[0]) ⭐ \(scores[0])   :   \(scores[1]) ⭐ \(names[1])     ⏱ \(left)"
            : "⭐ \(scores[0])     " + L("최고 \(best)") + "     ⏱ \(left)"
        guard text != shown else { return }
        shown = text
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white])
        let size = s.size()
        let v = PlayMode.shared.visible
        hud.string = s
        hud.frame = CGRect(x: 0, y: 6, width: size.width + 28, height: size.height)   // CATextLayer draws from its top: the pill pads it
        hud.superlayer?.frame = CGRect(x: v.midX - size.width / 2 - 14, y: v.maxY - size.height - 22, width: size.width + 28, height: size.height + 12)
    }

    /// The session is over (Esc, time up, a click elsewhere): the score, the best, the winner, in a bubble once the
    /// friend is back.
    private func finish() {
        guard isOn else { return }
        isOn = false
        seed = nil
        stars = []; hud = nil   // their layers go with the overlay
        let (a, b) = (scores[0], scores[1])
        let persona = AssistantModel.persona()
        let polite = !persona.style.banmal
        var card: PoseCard?
        let line: String
        if duel {
            card = a == b ? nil : .cheer
            line = a == b ? (polite ? L("비겼어요! \(a) 대 \(b)") : L("비겼다! \(a) 대 \(b)"))
                : polite ? L("\(a > b ? names[0] : names[1])가 이겼어요! \(a) 대 \(b)") : L("\(a > b ? names[0] : names[1])가 이겼다! \(a) 대 \(b)")
        } else if StarRules.record(a, in: AppDefaults.store) {
            card = .cheer
            line = polite ? L("새 기록이에요! 별 \(a)개 🎉") : L("새 기록이다! 별 \(a)개 🎉")
        } else if a > 0 {
            card = .proud
            line = polite ? L("별을 \(a)개 모았어요!") : L("별을 \(a)개 모았어!")
        } else {
            line = polite ? L("별을 못 모았어요. 다음엔 꼭 모아 봐요!") : L("별을 못 모았네. 다음엔 꼭 모아 보자!")
        }
        DispatchQueue.main.async {   // after PlayMode gives the friend back, so the bubble points at it
            if card == .cheer { DesktopKit.celebrate.send(.cheer) }
            SpeechBubbleCenter.shared.say(text: persona.exclaim(line), source: .system, aloud: false, repeats: true, card: card,
                                          anchor: DesktopFriends.speaker)
        }
    }

    /// 놀이 모드, 별 줍기 and 2인 대결 for a friend's menu (`source`: who plays).
    static func menuItems(_ source: PlayMode.Source) -> [NSMenuItem] {
        [FriendMenu.item(L("놀이 모드")) { PlayMode.shared.start(source) },
         FriendMenu.item(L("별 줍기")) { StarGame.shared.start(duel: false, from: source) },
         FriendMenu.item(L("2인 대결")) { StarGame.shared.start(duel: true, from: source) }]
    }
}
