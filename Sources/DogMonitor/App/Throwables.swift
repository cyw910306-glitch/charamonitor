import AppKit
import AVFoundation
import SwiftUI

// 던지기 놀이: a click on a friend in the room (친구 상주) throws the chosen 투척물 at them in an arc, and a friend
// thrown into another hits that one too. Each hit goes to the one hit, whose Mac counts it (StunRule): enough hits
// close together knock them out (기절) for a moment, and that Mac tells every friend so all show the stars. 고유행동
// instead walks my character over to 겁주기 (out at once) or 뽀뽀 (hearts). Only small integers travel (the item's
// `wire`); every Mac draws the item from its own copy of the art. Off by default: off, nothing is thrown, a hit that
// comes is dropped, and no timer runs. Pure parts tested in ThrowTests.
// Keys: social.throw (OFF), social.throw.item, social.throw.guard (OFF), social.throw.move ("" = 던지기).

// MARK: Items

/// One thing to throw, in code pixels (Wardrobe.ink). `wire` is what travels; never renumber one.
struct ThrowItem: Equatable {
    let wire: Int
    /// "t-…"; a season one is also a SeasonCatalog id, given by the 시즌 뽑기판.
    let id: String
    let name: String
    let art: [String]
    let sound: ThrowSound.Kind
    var season = false
}

enum Throwables {
    static let items: [ThrowItem] = [
        ThrowItem(wire: 1, id: "t-paper", name: L("종이 뭉치"), art: ["..KKKK..", ".KWWcWK.", "KWcKWWcK", "KWWWcKWK", "KcKWWWcK", ".KWcWKK.", "..KKKK.."], sound: .crinkle),
        ThrowItem(wire: 2, id: "t-ball", name: L("탱탱볼"), art: ["..KKKK..", ".KPPWPK.", "KPPPPWPK", "KPPPPPPK", "KPPPPPPK", ".KPPPPK.", "..KKKK.."], sound: .boing),
        ThrowItem(wire: 3, id: "t-pillow", name: L("베개"), art: ["KK....KK", "KWKKKKWK", "KWWWWWWK", "KWWcWWWK", "KWWWWcWK", "KWKKKKWK", "KK....KK"], sound: .thump),
        ThrowItem(wire: 4, id: "t-gummy", name: L("젤리"), art: ["...KK...", "..KGGK..", ".KGWGGK.", "KGGGGGGK", "KGGGGGGK", ".KKKKKK."], sound: .boing),
        ThrowItem(wire: 5, id: "t-sock", name: L("양말"), art: [".KKKK...", ".KWWK...", ".KBBK...", ".KWWK...", ".KBBKK..", ".KBBBBK.", ".KBBBBK.", "..KKKK.."], sound: .thump),
        ThrowItem(wire: 6, id: "t-eraser", name: L("지우개"), art: ["KKKKKKKK", "KLLLWWWK", "KLLLWWWK", "KKKKKKKK"], sound: .tap),
        ThrowItem(wire: 7, id: "t-acorn", name: L("도토리"), art: ["...K....", ".KKKKK..", "KnnnnnK.", "KnnnnnK.", ".KYYYK..", ".KYYYK..", "..KYK...", "...K...."], sound: .tap),
        ThrowItem(wire: 8, id: "t-tangerine", name: L("귤"), art: ["....G...", "..KKGK..", ".KYYYYK.", "KYWYYYYK", "KYYYYYYK", "KYYYYYyK", ".KYYyyK.", "..KKKK.."], sound: .thump),
        ThrowItem(wire: 9, id: "t-snowball", name: L("눈뭉치"), art: ["..KKKK..", ".KWWWcK.", "KWWcWWWK", "KWWWWWcK", "KcWWWWWK", ".KWWcWK.", "..KKKK.."], sound: .crinkle, season: true),
        ThrowItem(wire: 10, id: "t-pinecone", name: L("솔방울"), art: ["...gg...", "..KnnK..", ".KnynnK.", ".KnnynK.", ".KnynnK.", "..KnnK..", "...KK..."], sound: .tap, season: true),
    ]

    static func item(_ wire: Int) -> ThrowItem? { items.first { $0.wire == wire } }
    static func item(id: String) -> ThrowItem? { items.first { $0.id == id } }

    /// The ids a season.json may give.
    static var seasonIDs: [String] { items.filter(\.season).map(\.id) }

    /// What can be picked here: every everyday one, and the season ones won.
    static func usable(owned: Set<String>) -> [ThrowItem] { items.filter { !$0.season || owned.contains($0.id) } }
}

// MARK: Rules

enum ThrowRules {
    /// Wire numbers that are not items: a thrown friend, 겁주기 (out at once) and 뽀뽀 (hearts, no hit).
    static let friend = 0, scare = 90, kiss = 91

    static func valid(_ wire: Int) -> Bool { wire == friend || wire == scare || wire == kiss || Throwables.item(wire) != nil }

    /// Flight time: distance over `speed` plus `base`. Arc height: `arcRatio` of the distance within `arcRange`.
    /// The knobs to tune by hand.
    static let speed: CGFloat = 1600, base: TimeInterval = 0.18
    static let arcRatio: CGFloat = 0.18, arcRange: ClosedRange<CGFloat> = 24...96
    /// 고유행동: how fast my character walks over, and how long it may take at most.
    static let walkSpeed: CGFloat = 700, walkMost: TimeInterval = 2.5

    static func seconds(_ distance: CGFloat) -> TimeInterval { Double(max(0, distance) / speed) + base }
    static func arc(_ distance: CGFloat) -> CGFloat { min(max(distance * arcRatio, arcRange.lowerBound), arcRange.upperBound) }

    /// Where an item is `u` (0...1) of the way from `a` to `b`: a straight line lifted by a parabola, highest halfway.
    static func point(from a: CGPoint, to b: CGPoint, u: Double) -> CGPoint {
        let k = CGFloat(min(1, max(0, u)))
        let h = arc(hypot(b.x - a.x, b.y - a.y))
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k + 4 * h * k * (1 - k))
    }

    /// The others a thrown friend at `flying` touches: overlapping by more than `inset` on each side (the panels'
    /// clear margins should not count), not yet hit this flight, sorted.
    static let inset: CGFloat = 8
    static func hits(_ flying: CGRect, others: [String: CGRect], already: Set<String>) -> [String] {
        let f = flying.insetBy(dx: inset, dy: inset)
        return others.filter { !already.contains($0.key) && f.intersects($0.value.insetBy(dx: inset, dy: inset)) }.keys.sorted()
    }
}

/// 기절: `hits` within the last `window` seconds knock out for `seconds`. Hits while out do not count, and the count
/// starts over after. Times are system uptime (a clock change cannot knock anyone out).
struct StunRule {
    static let window: TimeInterval = 10, hits = 5, seconds: TimeInterval = 6

    private(set) var recent: [TimeInterval] = []
    private(set) var until: TimeInterval = -.infinity

    func isOut(at t: TimeInterval) -> Bool { t < until }

    /// One hit at `t`. True when it knocks out.
    mutating func hit(at t: TimeInterval) -> Bool {
        guard !isOut(at: t) else { return false }
        recent.removeAll { t - $0 >= Self.window || $0 > t }
        recent.append(t)
        guard recent.count >= Self.hits else { return false }
        knockOut(at: t)
        return true
    }

    /// Out now, whatever the count (겁주기).
    mutating func knockOut(at t: TimeInterval) {
        until = t + Self.seconds
        recent = []
    }
}

/// 던지기 가드: while on, a click on a friend opens the chat as usual and throws only for `seconds` after 던질 준비.
struct ThrowGuard {
    static let seconds: TimeInterval = 10
    private(set) var until: TimeInterval = -.infinity

    mutating func arm(at t: TimeInterval) { until = t + Self.seconds }
    func allows(at t: TimeInterval, guarded: Bool) -> Bool { !guarded || t < until }
}

/// The same impact sound at most every `gap` seconds, and `perSecond` of them in all.
struct SoundGap {
    static let gap: TimeInterval = 0.08, perSecond = 8
    private var last: [ThrowSound.Kind: TimeInterval] = [:]
    private var recent: [TimeInterval] = []

    mutating func allow(_ kind: ThrowSound.Kind, at t: TimeInterval) -> Bool {
        recent.removeAll { t - $0 >= 1 }
        guard recent.count < Self.perSecond, t - (last[kind] ?? -.infinity) >= Self.gap else { return false }
        last[kind] = t
        recent.append(t)
        return true
    }
}

// MARK: Sound

/// Impact sounds made in memory like FriendCry: a soft thump, a springy boing, a dry tap, a paper crinkle.
enum ThrowSound {
    enum Kind: CaseIterable { case thump, boing, tap, crinkle }

    static let sampleRate = 22_050
    /// Loudness, the knob to tune by ear.
    static let volume: Float = 0.45

    static func kind(_ wire: Int) -> Kind? {
        switch wire {
        case ThrowRules.friend: return .thump
        case ThrowRules.scare: return .boing
        case ThrowRules.kiss: return nil
        default: return Throwables.item(wire)?.sound
        }
    }

    static func make(_ kind: Kind) -> Data {
        var rng = SplitMix64(seed: 12)
        let seconds: Double
        switch kind {
        case .thump: seconds = 0.18
        case .boing: seconds = 0.32
        case .tap: seconds = 0.07
        case .crinkle: seconds = 0.2
        }
        let n = Int(seconds * Double(sampleRate))
        var lp = 0.0, phase = 0.0
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let u = Double(i) / Double(n), t = Double(i) / Double(sampleRate)
            let attack = min(1, t / 0.002)
            var v: Double
            switch kind {
            case .thump:   // a low drop with a breath of noise
                phase += 2 * .pi * (150 - 80 * u) / Double(sampleRate)
                lp += 0.06 * (Double.random(in: -1...1, using: &rng) - lp)
                v = (sin(phase) * 0.9 + lp * 1.4) * exp(-t * 22)
            case .boing:   // up and wobbling
                phase += 2 * .pi * 260 * (1 + 0.5 * u) * (1 + 0.12 * sin(2 * .pi * 14 * t)) / Double(sampleRate)
                v = sin(phase) * pow(1 - u, 1.5) * 0.7
            case .tap:   // a short high knock
                phase += 2 * .pi * 1700 / Double(sampleRate)
                v = (sin(phase) * 0.6 + Double.random(in: -1...1, using: &rng) * 0.3) * exp(-t * 70)
            case .crinkle:   // crackles thinning out
                lp += 0.5 * (Double.random(in: -1...1, using: &rng) - lp)
                v = lp * (0.5 + 0.5 * sin(2 * .pi * 55 * t)) * pow(1 - u, 1.2) * 1.3
            }
            let s = Int16(max(-1, min(1, v * attack)) * 26_000)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return ChimeSound.wav(pcm, sampleRate: sampleRate)
    }

    private static var players: [Kind: AVAudioPlayer] = [:]
    private static var gap = SoundGap()

    /// The sound of `wire` landing, within SoundGap; never while 효과음 is off or the bubble is muted.
    static func play(_ wire: Int) {
        guard let kind = kind(wire), AppSettings.shared.friendSounds, !SpeechBubbleCenter.shared.isMuted(),
              gap.allow(kind, at: ProcessInfo.processInfo.systemUptime),
              let p = players[kind] ?? (try? AVAudioPlayer(data: make(kind))) else { return }
        players[kind] = p
        p.volume = volume
        p.currentTime = 0
        p.play()
    }
}

// MARK: Settings and the one hit

/// 고유행동: walk over instead of throwing.
enum ThrowMove: String, CaseIterable {
    case scare, kiss
    var label: String { self == .scare ? L("다가가서 겁주기") : L("다가가서 뽀뽀") }
    var wire: Int { self == .scare ? ThrowRules.scare : ThrowRules.kiss }
}

/// My side: the switches, 던질 준비, and the hits that land on me (counted here; a 기절 goes to every friend).
final class ThrowCenter {
    static let shared = ThrowCenter()
    static let key = "social.throw", itemKey = "social.throw.item", guardKey = "social.throw.guard", moveKey = "social.throw.move"
    /// Hits counted from one 원격 모임 poll at most (a poll can bring many at once).
    static let maxPerPoll = 8

    var defaults: UserDefaults { SocialBus.shared.defaults }
    var isOn: Bool { defaults.bool(forKey: Self.key) }
    var guarded: Bool { defaults.bool(forKey: Self.guardKey) }
    var move: ThrowMove? { defaults.string(forKey: Self.moveKey).flatMap(ThrowMove.init) }
    /// The chosen item, the paper ball when the chosen one is not usable (a season one not won).
    var item: ThrowItem {
        let usable = Throwables.usable(owned: Set(SeasonCenter.shared.state.owned))
        return usable.first { $0.wire == defaults.integer(forKey: Self.itemKey) } ?? usable[0]
    }
    func choose(_ i: ThrowItem) { defaults.set(i.wire, forKey: Self.itemKey) }

    private var rule = StunRule()
    private var guardRule = ThrowGuard()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func arm() { guardRule.arm(at: now) }
    /// A click on a friend throws (else it opens the chat).
    var clickThrows: Bool { isOn && guardRule.allows(at: now, guarded: guarded) }

    /// A hit on me by `name` (a friend's nickname or a 원격 모임 name). Dropped while off, unknown, or in a call or a
    /// recording. A 기절 is told to every friend (근처 and 원격) and shown over my character.
    func hit(_ wire: Int, by name: String) {
        guard isOn, ThrowRules.valid(wire), !FriendVisit.quiet() else { return }
        ThrowSound.play(wire)
        if wire == ThrowRules.kiss {
            StunOverlay.shared.show(.hearts)
            SpeechBubbleCenter.shared.say(text: L("\(name)\(Banmal.particle(name, "이", "가")) 뽀뽀했어!"), source: .system, aloud: false, repeats: true, seconds: 3,
                                          anchor: StunOverlay.anchor)
            return
        }
        let out: Bool
        // A 겁주기 while already out counts for nothing, like a hit: no new 기절 to tell everyone.
        if wire == ThrowRules.scare { out = !rule.isOut(at: now); if out { rule.knockOut(at: now) } } else { out = rule.hit(at: now) }
        guard out else { StunOverlay.shared.show(.bonk); return }
        let s = Int(StunRule.seconds)
        StunOverlay.shared.show(.out(StunRule.seconds))
        SpeechBubbleCenter.shared.say(text: L("\(name)에게 맞아서 기절!"), source: .system, aloud: false, repeats: true,
                                      seconds: StunRule.seconds, anchor: StunOverlay.anchor)
        let bus = SocialBus.shared   // version 1 closes the link on a case it can not read
        RoomRules.emoteTargets(online: bus.online, versions: bus.versions).forEach { bus.send(.ko(seconds: s), to: $0) }
        RemoteMeet.shared.sendKO(s)
    }

    /// 근처 친구 ▸ 투척물 ▸ …, with the chosen one checked.
    func itemMenu() -> NSMenuItem {
        let picked = item.wire
        return FriendMenu.submenu(L("투척물"), Throwables.usable(owned: Set(SeasonCenter.shared.state.owned)).map { i in
            FriendMenu.item(i.name, on: i.wire == picked) { [weak self] in self?.choose(i) }
        })
    }
}

// MARK: Art

/// A thrown item in flight (a SeasonIcon of its id), turning as it goes.
struct ThrowItemView: View {
    let item: ThrowItem
    var turn: Double = 0

    var body: some View {
        SeasonIcon(id: item.id).rotationEffect(.radians(turn)).accessibilityHidden(true)
    }
}

/// 기절: a squashed ring over the head with three stars going round it once every `period`; the back half of the way
/// they are smaller and dimmer. Also a short 퍽 burst. `t` is seconds since it began.
struct StunView: View {
    enum Kind: Equatable { case bonk, out(TimeInterval), hearts }
    let kind: Kind
    let t: Double

    /// Ring size and star path: the knobs.
    static let ring = CGSize(width: 46, height: 22), radius: CGFloat = 19, period: Double = 1.2
    static let size = CGSize(width: 64, height: 40)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch kind {
            case .bonk: Self.bonk(ctx, c, t: t)
            case .hearts: Self.hearts(ctx, c, t: t)
            case .out: Self.stars(ctx, c, t: t)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    private static let yellow = Color(red: 1, green: 0.84, blue: 0.25), ink = Color(red: 0.17, green: 0.17, blue: 0.17)

    /// A 4-point sparkle in pixels: a plus of `px` squares with a bright middle.
    private static func sparkle(_ ctx: GraphicsContext, _ p: CGPoint, px: CGFloat, alpha: Double) {
        let cells: [(Int, Int)] = [(0, -2), (0, -1), (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (0, 1), (0, 2)]
        for (dx, dy) in cells {
            let r = CGRect(x: p.x + CGFloat(dx) * px - px / 2, y: p.y + CGFloat(dy) * px - px / 2, width: px, height: px)
            ctx.fill(Path(r.insetBy(dx: -0.6, dy: -0.6)), with: .color(ink.opacity(alpha)))
        }
        for (dx, dy) in cells {
            let r = CGRect(x: p.x + CGFloat(dx) * px - px / 2, y: p.y + CGFloat(dy) * px - px / 2, width: px, height: px)
            ctx.fill(Path(r), with: .color((dx == 0 && dy == 0 ? Color.white : yellow).opacity(alpha)))
        }
    }

    private static func stars(_ ctx: GraphicsContext, _ c: CGPoint, t: Double) {
        let ringRect = CGRect(x: c.x - ring.width / 2, y: c.y - ring.height / 2, width: ring.width, height: ring.height)
        func star(_ i: Int, front: Bool) {
            let a = (t / period + Double(i) / 3) * 2 * .pi
            let depth = sin(a)   // + in front
            guard (depth >= 0) == front else { return }
            let p = CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * 0.4 * CGFloat(depth))
            sparkle(ctx, p, px: front ? 2 : 1.5, alpha: front ? 1 : 0.55)
        }
        (0..<3).forEach { star($0, front: false) }
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 3))
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(Color(red: 0.62, green: 0.53, blue: 0.93)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2], dashPhase: t * 12))
        (0..<3).forEach { star($0, front: true) }
    }

    /// 퍽: six short rays and a sparkle, gone in `bonkSeconds`.
    static let bonkSeconds = 0.4
    private static func bonk(_ ctx: GraphicsContext, _ c: CGPoint, t: Double) {
        let k = min(1, t / bonkSeconds), alpha = 1 - k * k
        for i in 0..<6 {
            let a = Double(i) / 6 * 2 * .pi + 0.3
            let r0 = 6 + 10 * k, r1 = r0 + 6
            var p = Path()
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a) * r0), y: c.y + CGFloat(sin(a) * r0)))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a) * r1), y: c.y + CGFloat(sin(a) * r1)))
            ctx.stroke(p, with: .color(yellow.opacity(alpha)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        sparkle(ctx, c, px: 2, alpha: alpha)
    }

    private static func hearts(_ ctx: GraphicsContext, _ c: CGPoint, t: Double) {
        for i in 0..<3 {
            let k = max(0, min(1, t / 1.6 - Double(i) * 0.15))
            let p = CGPoint(x: c.x + CGFloat(i - 1) * 14, y: c.y + 10 - CGFloat(k) * 24)
            let s: CGFloat = 2
            let rows = [".PP.PP.", "PPPPPPP", "PPPPPPP", ".PPPPP.", "..PPP..", "...P..."]
            for (r, row) in rows.enumerated() {
                for (col, ch) in row.enumerated() where ch == "P" {
                    let rect = CGRect(x: p.x + CGFloat(col - 3) * s, y: p.y + CGFloat(r - 3) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color(Color(red: 1, green: 0.45, blue: 0.62).opacity(1 - k * k)))
                }
            }
        }
    }

    /// How long a kind stays up.
    static func seconds(_ k: Kind) -> TimeInterval {
        switch k {
        case .bonk: return bonkSeconds
        case .hearts: return 1.8
        case .out(let s): return s
        }
    }
}

/// The stars, 퍽 or hearts over my own character (the 커서 친구) when a friend hits me; nothing shows while it is
/// off. Its timer runs only while something shows.
final class StunOverlay {
    static let shared = StunOverlay()
    /// Over the 커서 친구's head while it is out; else the bubble goes to its usual place.
    static let anchor: () -> CGPoint? = { CursorBuddy.shared.head() }

    private var panel: NSPanel?
    private var timer: Timer?
    private var shown: (kind: StunView.Kind, start: Date)?

    func show(_ kind: StunView.Kind) {
        if case .out = shown?.kind, kind == .bonk, let s = shown, Date().timeIntervalSince(s.start) < StunView.seconds(s.kind) { return }
        guard Self.anchor() != nil else { return }
        shown = (kind, Date())
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(origin: .zero, size: StunView.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.sharingType = .none
            panel = p
        }
        let start = shown!.start
        panel?.contentView = NSHostingView(rootView: TimelineView(.animation) { ctx in StunView(kind: kind, t: ctx.date.timeIntervalSince(start)) })
        tick()
        panel?.orderFrontRegardless()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let s = shown, let head = Self.anchor() else { return hide() }
        let t = Date().timeIntervalSince(s.start)
        guard t < StunView.seconds(s.kind) else { return hide() }
        panel?.setFrameOrigin(CGPoint(x: head.x - StunView.size.width / 2, y: head.y - 8))
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        shown = nil
        panel?.orderOut(nil)
    }
}

// MARK: Settings

/// 던지기 놀이, in 설정 > 플러그인 > 근처 친구 and 원격 모임.
struct ThrowSettings: View {
    @AppStorage(ThrowCenter.key, store: AppDefaults.store) private var on = false
    @AppStorage(ThrowCenter.itemKey, store: AppDefaults.store) private var item = 1
    @AppStorage(ThrowCenter.guardKey, store: AppDefaults.store) private var guarded = false
    @AppStorage(ThrowCenter.moveKey, store: AppDefaults.store) private var move = ""
    @ObservedObject private var season = SeasonCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("던지기 놀이 (명중·기절)"), isOn: $on).toggleStyle(.switch).controlSize(.small)
            note(L("친구 캐릭터를 누르면 투척물을 던져요. 10초 안에 다섯 번 맞으면 6초 동안 기절하고, 모두의 화면에 별이 돌아요. 친구가 친구에게 날아가 부딪혀도 맞아요."))
            if on {
                HStack(spacing: 6) {
                    ForEach(Throwables.usable(owned: Set(season.state.owned)), id: \.wire) { i in
                        Button { item = i.wire } label: {
                            ThrowItemView(item: i).frame(width: 22, height: 22).padding(3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(item == i.wire ? Color.accentColor.opacity(0.25) : .clear))
                        }
                        .buttonStyle(.plain).help(i.name).accessibilityLabel(i.name)
                    }
                }
                note(L("눈뭉치·솔방울은 시즌 뽑기판에서 모아요."))
                Picker(L("누르면"), selection: $move) {
                    Text(L("투척물 던지기")).tag("")
                    ForEach(ThrowMove.allCases, id: \.rawValue) { m in Text(m.label).tag(m.rawValue) }
                }
                .fixedSize()
                Toggle(L("던지기 가드"), isOn: $guarded).toggleStyle(.switch).controlSize(.small)
                note(L("켜면 평소엔 눌러도 대화창이 열리고, 친구 캐릭터 오른쪽 클릭 > 던질 준비 뒤 10초 동안만 던져요."))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: QA

#if !MAS
/// `--render-throw <폴더>`: the items, an arc, the 기절 stars as they turn, a 퍽, a seat knocked out and the settings,
/// light and dark.
enum ThrowQA {
    static func render(to dir: URL) throws {
        let d = AppDefaults.store
        d.set(true, forKey: ThrowCenter.key)
        d.set(3, forKey: ThrowCenter.itemKey)
        d.set(true, forKey: ThrowCenter.guardKey)
        var s = SeasonState()
        s.owned = ["t-snowball"]
        SeasonCenter.shared.seed(SeasonManifest.bundled, s)
        let grid = VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(Throwables.items.dropFirst(row * 5).prefix(5), id: \.wire) { i in
                        VStack(spacing: 3) {
                            ThrowItemView(item: i).frame(width: 40, height: 40)
                            Text(verbatim: i.name).font(.system(size: 10))
                        }
                        .frame(width: 58)
                    }
                }
            }
        }
        .padding(12)
        let arc = Canvas { ctx, size in
            let a = CGPoint(x: 20, y: size.height - 16), b = CGPoint(x: size.width - 20, y: size.height - 16)
            for k in 0...10 {
                let p = ThrowRules.point(from: a, to: b, u: Double(k) / 10)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: size.height - p.y - 3, width: 6, height: 6)), with: .color(.secondary))
            }
        }
        .frame(width: 320, height: 110)
        let stars = HStack(spacing: 6) {
            ForEach([0, 0.2, 0.4, 0.6, 0.8, 1.0], id: \.self) { t in StunView(kind: .out(6), t: t).background(Color.gray.opacity(0.12)) }
        }
        .padding(8)
        let effects = HStack(spacing: 6) {
            ForEach([0.05, 0.15, 0.3], id: \.self) { t in StunView(kind: .bonk, t: t).background(Color.gray.opacity(0.12)) }
            ForEach([0.3, 0.9], id: \.self) { t in StunView(kind: .hearts, t: t).background(Color.gray.opacity(0.12)) }
        }
        .padding(8)
        let friend = SocialFriend(id: "qa", nickname: "보리", look: .fallback, status: .working, pairedAt: Date())
        let out = RoomSeat(friend), hit = RoomSeat(friend)
        out.koUntil = Date() + 6
        hit.bonkAt = Date()
        let seats = HStack(alignment: .bottom, spacing: 12) {
            RoomFriendView(seat: out, t: 0.35)
            RoomFriendView(seat: hit, t: 0.12)
        }
        .padding(8)
        let shots: [(String, AnyView)] = [
            ("items", AnyView(grid)), ("arc", AnyView(arc.padding(8))), ("stars", AnyView(stars)), ("effects", AnyView(effects)),
            ("seats", AnyView(seats)), ("settings", AnyView(ThrowSettings().frame(width: 360).padding())),
            ("prize", AnyView(SeasonIcon(id: "t-snowball").frame(width: 48, height: 48).padding(8))),
        ]
        for (name, view) in shots {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try DashboardSnapshot.snapshot(view, appearance: appearance, to: dir.appendingPathComponent("throw-\(name)-\(suffix).png"))
            }
        }
    }
}
#endif
