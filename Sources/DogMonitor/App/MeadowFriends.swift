import AppKit
import Combine
import QuartzCore

// MARK: Settings

struct MeadowPrefs: Codable, Equatable {
    var on = false
    var count = 4
    /// Who stands where (HangSlot.x = where across the screen it starts); charm, rope and length are not used here.
    var slots = MeadowPrefs.defaultSlots
    /// Above other windows; off = on the desktop, behind windows.
    var onTop = false
    /// 친구들끼리: now and then two turn a rope and the others jump it (3 or more out).
    var jumpRope = false

    static let maxCount = 6
    static let defaultSlots: [HangSlot] = (0..<maxCount).map {
        HangSlot(character: nil, imagePath: nil, charm: .none, rope: .thread, x: Double($0 + 1) / Double(maxCount + 1), length: 90, display: nil)
    }
}

extension MeadowPrefs {
    /// Settings saved before a field existed keep everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeadowPrefs()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? d.count
        slots = (try c.decodeIfPresent([HangSlot].self, forKey: .slots) ?? d.slots).map(\.clamped)
        onTop = try c.decodeIfPresent(Bool.self, forKey: .onTop) ?? d.onTop
        jumpRope = try c.decodeIfPresent(Bool.self, forKey: .jumpRope) ?? d.jumpRope
    }
}

final class MeadowStore: ObservableObject {
    static let shared = MeadowStore()
    static let key = "meadowFriends"

    private let defaults: UserDefaults
    @Published var prefs: MeadowPrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(MeadowPrefs.self, from: $0) } ?? MeadowPrefs()
        if prefs.slots.count < MeadowPrefs.maxCount { prefs.slots += MeadowPrefs.defaultSlots.dropFirst(prefs.slots.count) }
    }
}

// MARK: Walking along the floor

/// One friend on the floor band: across (`x`, its middle) and up (`y`, 0 = standing on the floor). Walks to `target`,
/// stands, sits, hops (a parabola) or falls after a drop. Pure; step it with the time.
struct MeadowWalk: Equatable {
    enum State: Equatable { case idle, walk, sit, hop }

    /// The usual stroll; `speed` can be raised for a run (복제 친구 chasing).
    static let speed: CGFloat = 45
    static let gravity: CGFloat = 1800
    static let hopSpeed: CGFloat = 360

    var x: CGFloat
    var target: CGFloat
    var state = State.idle
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var speed = MeadowWalk.speed
    /// Points per second across, + right (for facing and the walk frames).
    private(set) var vx: CGFloat = 0

    init(x: CGFloat) { self.x = x; target = x }

    var airborne: Bool { y > 0 || vy > 0 }

    mutating func walk(to t: CGFloat) { guard !airborne else { return }; target = t; state = .walk }
    mutating func hop() { guard !airborne else { return }; state = .hop; vy = Self.hopSpeed }
    /// Let go `height` above the floor: falls.
    mutating func drop(from height: CGFloat) { y = max(0, height); vy = 0; state = .hop; vx = 0 }

    mutating func step(dt: TimeInterval) {
        let h = CGFloat(min(0.1, max(0, dt)))
        if airborne || state == .hop {
            vy -= Self.gravity * h
            y += vy * h
            if y <= 0 { y = 0; vy = 0; state = .idle }
            return
        }
        guard state == .walk else { vx = 0; return }
        let d = target - x
        if abs(d) <= speed * h { x = target; vx = 0; state = .idle } else { vx = d > 0 ? speed : -speed; x += vx * h }
    }

    /// Neighbours at least `gap` apart (each `widths[i]` wide), all within `lo...hi`: an overlapping pair is pushed apart
    /// by half the overlap each. A friend being held (`pinned`) does not move; the other takes the whole push.
    static func separate(_ walks: inout [MeadowWalk], widths: [CGFloat], gap: CGFloat, lo: CGFloat, hi: CGFloat, pinned: Int? = nil) {
        guard walks.count == widths.count else { return }
        for _ in 0..<2 {
            let order = walks.indices.sorted { walks[$0].x < walks[$1].x }
            for (a, b) in zip(order, order.dropFirst()) {
                let need = (widths[a] + widths[b]) / 2 + gap, have = walks[b].x - walks[a].x
                guard have < need else { continue }
                let push = need - have
                switch pinned {
                case a: walks[b].x += push
                case b: walks[a].x -= push
                default: walks[a].x -= push / 2; walks[b].x += push / 2
                }
            }
            for i in walks.indices where i != pinned {
                walks[i].x = min(max(walks[i].x, lo + widths[i] / 2), hi - widths[i] / 2)
                if walks[i].state == .walk { walks[i].target = min(max(walks[i].target, lo + widths[i] / 2), hi - widths[i] / 2) }
            }
        }
    }

    /// The one standing nearest to `i` (`xs` across), within `reach`: it turns and hops when `i` is clicked.
    static func neighbour(of i: Int, in xs: [CGFloat], reach: CGFloat) -> Int? {
        guard xs.indices.contains(i) else { return nil }
        return xs.indices.filter { $0 != i && abs(xs[$0] - xs[i]) <= reach }.min { abs(xs[$0] - xs[i]) < abs(xs[$1] - xs[i]) }
    }
}

// MARK: Clicked and petted

/// What a 풀밭 친구 does when clicked: one of the 커서 친구's Reactions (its move and mark) in one of the friend's own poses.
struct MeadowReaction: Equatable {
    var reaction: Reaction
    var gait: BuddyGait

    /// The everyday ones: a happy 특기 move, a snack, a jump with its legs going, a spin, a flop down for a sit...
    static let plays: [MeadowReaction] = [
        .init(reaction: .hearts, gait: .special),
        .init(reaction: .giggle, gait: .eat),
        .init(reaction: .jump, gait: .walk),
        .init(reaction: .spin, gait: .stand),
        .init(reaction: .blush, gait: .special),
        .init(reaction: .surprised, gait: .stand),
        .init(reaction: .sneeze, gait: .stand),
        .init(reaction: .hearts, gait: .sleep),   // sits down for a while (sits): no move, no mark
    ]
    /// Rubbed with the cursor (쓰다듬기), and what it says then.
    static let pet = MeadowReaction(reaction: .blush, gait: .special)
    static var petLines: [String] { [L("쓰담쓰담 좋아요"), L("헤헤, 기분 좋아요"), L("더 쓰다듬어 주세요")] }

    var duration: TimeInterval { reaction.duration }
    /// The flop down: a sit of a few seconds (MeadowWalk's), not a timed move.
    var sits: Bool { gait == .sleep }

    /// The everyday ones a friend with poses `has` can show; the standing ones at least.
    static func plays(has: (BuddyGait) -> Bool) -> [MeadowReaction] {
        let p = plays.filter { has($0.gait) }
        return p.isEmpty ? plays.filter { $0.gait == .stand } : p
    }

    /// A click at `t`: the combo's dizzy (3rd, its dizzy frames) or pout (5th, standing with its back turned), else an everyday one `has` can show,
    /// never the one `key` gave last time (LinePick; tests pass their own `pick`).
    static func click(_ combo: inout ClickCombo, at t: TimeInterval, has: (BuddyGait) -> Bool, key: String,
                      pick: (([MeadowReaction]) -> MeadowReaction)? = nil) -> MeadowReaction {
        var play: MeadowReaction?
        let r = combo.click(at: t) { _ in
            let choices = plays(has: has), p = pick?(choices) ?? LinePick.pick(key, choices)
            play = p
            return p.reaction
        }
        // A pout stands (its sulk frames are the hungry ones, a bowl and their own "?"): the turned back and a slump say it.
        return play ?? MeadowReaction(reaction: r, gait: r == .pout ? .stand : r.gait)
    }

    /// What it says, before its persona dresses it (a pack's own "say" lines for its 특기 and 냠냠 frames go first).
    var lines: [String] {
        switch (reaction, gait) {
        case (.dizzy, _): return [L("어질어질…"), L("세상이 빙글빙글 돌아요"), L("눈앞이 핑핑 돌아요")]
        case (.pout, _): return [L("그만 눌러요, 흥!"), L("이제 안 놀아 줄 거예요")]
        case (_, .eat): return [L("냠냠, 맛있어요"), L("간식 먹는 중이에요")]
        case (_, .sleep): return [L("잠깐 앉아서 쉴래요"), L("풀밭이 폭신해요")]
        default: return [L("헤헤, 불렀어요?"), L("안녕! 오늘도 같이 놀아요"), L("간지러워요"), L("뭐 하고 있어요?"), L("저 여기 있어요!")]
        }
    }
}

/// Rubbing the cursor back and forth over one friend (쓰다듬기): the way it covers on that friend adds up, and a pause or
/// moving off starts over. Enough of it is a pet, once, then it starts over. Pure; feed it every mouse move.
struct PetRub {
    /// Points of rubbing for one pet.
    static let need: CGFloat = 220
    /// Still this long: it starts over.
    static let pause: TimeInterval = 0.5

    private var last: (p: CGPoint, t: TimeInterval, who: Int)?
    private(set) var rubbed: CGFloat = 0

    /// The cursor at `p` over friend `who` (nil: over none). True when that makes a pet.
    mutating func feed(_ p: CGPoint, over who: Int?, at t: TimeInterval) -> Bool {
        guard let who else { last = nil; rubbed = 0; return false }
        if let l = last, l.who == who, l.p == p { return false }   // a tick looking again, not a move
        defer { last = (p, t, who) }
        guard let l = last, l.who == who, t - l.t <= Self.pause else { rubbed = 0; return false }
        rubbed += hypot(p.x - l.p.x, p.y - l.p.y)
        guard rubbed >= Self.need else { return false }
        rubbed = 0
        return true
    }
}

// MARK: Friends on the floor

/// "풀밭 친구들" (데스크톱 친구): 1~6 friends live along the bottom of the main screen, above the Dock, on the desktop
/// (windows cover them) or on top. Each bobs where it stands; some stroll, sit or hop now and then; they keep a little
/// room between them. A click is a MeadowReaction in one of its own poses with a line over it (combos as the 커서 친구:
/// dizzy, then a pout), and the nearest one turns to look and hops; rubbing the cursor over one pets it. ⌥ click (or its
/// menu) opens 퀵물어보기 over that friend, a drag picks it up and it falls when let go, a right click is its menu.
/// No background art: the user's own desktop shows through. Under 동작 줄이기 they stand still: poses and marks only.
final class MeadowFriends {
    static let shared = MeadowFriends()
    /// QA renders only: the panel stays see-through (alpha 0).
    static var qaHidden = false

    fileprivate final class Friend {
        let slot: Int
        var walk: MeadowWalk
        var frames: [BuddyGait: [NSImage]] = [:]
        /// Standing about: its first walk frame, or (every third one) its 냠냠 frames.
        var rest = BuddyGait.stand
        /// A pack's own "say" lines for its 특기 and 냠냠 frames.
        var says: [BuddyGait: [String]] = [:]
        /// Its original's id (nil = the character chosen now): its 말투 is looked up when it talks, so a change shows.
        var character: String?
        var size = CGSize.zero
        let layer = CALayer()
        let phase = Double.random(in: 0..<(2 * .pi))
        /// Odd places stroll about more; the others mostly stand.
        var walker: Bool { slot % 2 == 1 }
        var frame = 0, clock: TimeInterval = 0
        var think: TimeInterval = 0, sitUntil: TimeInterval = 0
        var facingLeft = false
        var held = false
        var react: (r: MeadowReaction, start: TimeInterval)?
        var combo = ClickCombo()
        var shown: NSImage?

        init(slot: Int, x: CGFloat) { self.slot = slot; walk = MeadowWalk(x: x) }

        /// How high its reaction lifts it now, in points.
        func lift(_ now: TimeInterval, still: Bool) -> CGFloat {
            react.map { $0.r.reaction.pose(now - $0.start, still: still).lift * size.height } ?? 0
        }

        func has(_ g: BuddyGait) -> Bool { !(frames[g] ?? []).isEmpty }

        var gait: BuddyGait {
            // Clicks only pick poses it has; a pet without 특기 frames, or a dizzy without dizzy ones, just stands.
            if let r = react?.r { return has(r.gait) ? r.gait : .stand }
            if walk.state == .walk || walk.airborne { return .walk }
            return walk.state == .sit ? .sleep : rest
        }
        var moving: Bool { walk.state == .walk || walk.airborne }
    }

    private var panel: NSPanel?
    private var friends: [Friend] = []
    private var hits: [ObjectIdentifier: AlphaHit] = [:]
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var bag: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var started = false
    private var asleep = false
    private var still = DesktopKit.reduceMotion
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var clicks = ClickRecognizer()
    private var pressed: Friend?
    private var grab = CGVector.zero
    private var rub = PetRub()
    /// Everyday lines at most this often, so clicks in a row are not a wall of bubbles (dizzy and pout always talk).
    private var talkAfter: TimeInterval = 0

    // 친구들끼리: 줄넘기 or 단체 춤, run from `tick` (30 fps while one is on, nothing extra otherwise).
    private struct RopeRound {
        var holders: [Friend], jumpers: [Friend]
        /// Where each one stands for it, in `holders + jumpers` order.
        var spots: [CGFloat]
        /// Nil while they are still getting into place.
        var rope: JumpRope?
        var gatherUntil: TimeInterval, until: TimeInterval
        var streak = RopeStreak()
        var hopped = -1, judged = -1
    }
    private var ropeRound: RopeRound?
    private var dance: (start: TimeInterval, beat: Int)?
    /// When 줄넘기 starts on its own next.
    private var gameAt: TimeInterval = 0
    private var playing: Bool { ropeRound != nil || dance != nil }
    private lazy var rope: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = NSColor(red: 0.95, green: 0.5, blue: 0.35, alpha: 1).cgColor
        l.lineWidth = 2.5
        l.lineCap = .round
        l.actions = ["path": NSNull(), "zPosition": NSNull()]
        return l
    }()

    private struct Built: Equatable {
        var slots: [HangSlot]
        var look: SpriteLook
        var colors: [String: [String: RGBColor]]
        /// The screen's frame and visible frame: the Dock moving, resizing or hiding changes only the second.
        var screen: [CGRect]
    }
    private var built: Built?

    private var store: MeadowStore { .shared }
    private var enabled: Bool { store.prefs.on && !asleep }
    /// Feet this far above the panel's bottom (the Dock's top).
    private static let floor: CGFloat = 4

    func start() {
        guard !started else { return }
        started = true
        MeadowStore.shared.objectWillChange
            .merge(with: AppSettings.shared.objectWillChange, CustomCharacterStore.shared.objectWillChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        let nc = NSWorkspace.shared.notificationCenter
        for (name, sleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            nc.publisher(for: name).sink { [weak self] _ in self?.asleep = sleep; self?.refresh() }.store(in: &bag)
        }
        DesktopKit.displayOptionsChanged
            .sink { [weak self] in self?.still = DesktopKit.reduceMotion; self?.wake() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .filter { [weak self] in ($0.object as? NSWindow) === self?.panel }
            .sink { [weak self] _ in self?.wake() }
            .store(in: &bag)
        DesktopKit.celebrate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cheer(party: true) }
            .store(in: &bag)
        refresh()
    }

    /// The top middle of friend `i` on screen; nil while off or when there is no such friend.
    func head(_ i: Int) -> CGPoint? {
        guard let p = panel, p.isVisible, friends.indices.contains(i) else { return nil }
        let f = friends[i]
        let lift = f.lift(ProcessInfo.processInfo.systemUptime, still: still)
        return CGPoint(x: p.frame.minX + f.walk.x, y: p.frame.minY + Self.floor + f.walk.y + lift + f.size.height)
    }

    /// 춤춰 줘·응원해 줘 (and 다 같이 뛰기 from the menu): they hop one after another; hearts only under 동작 줄이기. With
    /// 단체 춤 a celebration has them all dance to one beat for 10 s instead.
    private func cheer(party: Bool = false) {
        if party, GroupDance.on, !still, !friends.isEmpty {
            endGames()
            friends.filter { !$0.held }.forEach { $0.react = nil; $0.walk = MeadowWalk(x: $0.walk.x) }
            dance = (ProcessInfo.processInfo.systemUptime, -1)
            wake()
            return
        }
        for (i, f) in friends.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) { [weak self] in
                guard let self, !f.held else { return }
                if self.still { self.pop("♥", .systemPink, over: f) } else { f.walk.hop(); self.wake() }
            }
        }
    }

    // MARK: Building

    private func refresh() {
        // The menu bar's screen, not NSScreen.main (whichever has the key window): a settings change must not move them.
        guard enabled, let screen = NSScreen.screens.first else { teardown(); return }
        let prefs = store.prefs
        let now = Built(slots: Array(prefs.slots.prefix(max(1, min(MeadowPrefs.maxCount, prefs.count)))), look: SpriteLook(AppSettings.shared),
                        colors: AppSettings.shared.characterColors, screen: [screen.frame, screen.visibleFrame])
        let level = prefs.onTop ? .floating : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if now != built { build(now, screen: screen) }
        if panel?.level != level { panel?.level = level }
        if ropeRound != nil, !prefs.jumpRope { endGames() }
        wake()
    }

    private func build(_ now: Built, screen: NSScreen) {
        built = now
        pressed = nil
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(Self.panelFrame(screen), display: false)
        p.orderFrontRegardless()
        friends.forEach { $0.layer.removeFromSuperlayer() }
        hits = [:]
        dropGames()
        gameAt = ProcessInfo.processInfo.systemUptime + GroupPlay.gap(random: .random(in: 0..<1)) / 2
        let target = screen.frame.height / 8   // about an eighth of the screen tall
        friends = now.slots.enumerated().map { makeFriend($0, $1, width: p.frame.width, target: target, scale: screen.backingScaleFactor) }
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.hover() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.hover(); return e }) { monitors.append(l) }
        }
        separate()
        friends.forEach(layout)
    }

    /// The bottom third of the screen, from the top of the Dock.
    static func panelFrame(_ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX, y: screen.visibleFrame.minY, width: screen.frame.width, height: screen.frame.height / 3)
    }

    private func teardown() {
        timer?.invalidate(); timer = nil; interval = 0
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        friends.forEach { $0.layer.removeFromSuperlayer() }
        dropGames()
        friends = []; pressed = nil; built = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = MeadowPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // until the cursor is over a friend (hover)
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let v = MeadowView(frame: .zero)
        v.owner = self
        v.wantsLayer = true
        p.contentView = v
        return p
    }

    /// Sprites for `character` (an original's id; nil = the character chosen now) at `pixelSize`.
    static func cache(character: String?, pixelSize px: CGFloat) -> DogSpriteCache {
        let id = character.map { RenderStyle.paired($0, RenderStyle.current, has: RenderStyle.hasOriginal) }
        return id.flatMap(OriginalCatalog.character)
            .map { DogSpriteCache(CharacterColors.apply(character.flatMap { AppSettings.shared.characterColors[$0] }, to: $0), pixelSize: px) }
            ?? DogSpriteCache(SpriteLook(AppSettings.shared), pixelSize: px)
    }

    /// How `character` (an original's id; nil = the character chosen now) talks: its own 말투 and sounds under its name.
    static func persona(character: String?) -> Persona {
        let id = character.map { RenderStyle.paired($0, RenderStyle.current, has: RenderStyle.hasOriginal) }
        guard let id, let o = OriginalCatalog.character(id) else { return AssistantModel.persona() }
        return Persona.resolve(name: o.displayName, character: .original, id: id, chosen: AssistantSettings.shared.persona,
                               own: o.voice, cries: o.cries)
    }

    private func makeFriend(_ i: Int, _ slot: HangSlot, width: CGFloat, target: CGFloat, scale: CGFloat) -> Friend {
        let f = Friend(slot: i, x: width * CGFloat(slot.x))
        var smooth = false
        if let path = slot.imagePath, let picture = NSImage(contentsOfFile: path) {
            let one = [HangingFriends.framed(picture)]
            f.frames = [.walk: one, .stand: one, .sleep: one, .special: one, .dizzy: one, .sulk: one]
            smooth = true
        } else {
            func cache(_ px: CGFloat) -> DogSpriteCache { Self.cache(character: slot.character, pixelSize: px) }
            let base = cache(1).imageSize.height
            let c = cache(max(1, (target / max(1, base)).rounded()))
            f.frames = BuddyGait.frames(c).filter { !$0.value.isEmpty }
            // Every third one holds something of its own (its 냠냠 frames: a cup, a snack) while it stands.
            if i % 3 == 2, f.has(.eat) { f.rest = .eat }
            f.says = [.special: c.lines(forExtra: .special, variant: 0), .eat: c.lines(forExtra: .eat, variant: 0)].filter { !$0.value.isEmpty }
            f.character = slot.character
            smooth = c.smooth
        }
        f.size = f.frames[.walk]?.first?.size ?? .zero
        f.layer.contentsScale = scale
        f.layer.magnificationFilter = smooth ? .linear : .nearest
        f.layer.bounds = CGRect(origin: .zero, size: f.size)
        f.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        f.layer.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "bounds": NSNull()]
        f.think = ProcessInfo.processInfo.systemUptime + .random(in: 1...5)
        panel?.contentView?.layer?.addSublayer(f.layer)
        return f
    }

    // MARK: Ticking

    private func wake() {
        guard !friends.isEmpty, enabled else { return }
        schedule(1.0 / 30)
    }

    private func schedule(_ every: TimeInterval) {
        guard every != interval else { return }
        timer?.invalidate()
        interval = every
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        handle(clicks.poll(at: now))
        games(now: now)
        var busy = false, waiting = false
        for f in friends where !f.held {
            if let r = f.react, now - r.start >= r.r.duration { f.react = nil }
            if !still, f.react == nil, !playing { think(f, now: now) }
            f.walk.step(dt: dt)
            if f.walk.state == .sit, now >= f.sitUntil { f.walk.state = .idle }
            if f.walk.vx < -1 { f.facingLeft = true } else if f.walk.vx > 1 { f.facingLeft = false }
            // Under 동작 줄이기 a reaction is a still pose: it only has to end on time, not move.
            busy = busy || f.moving || f.react != nil && !still
            waiting = waiting || f.react != nil || f.walk.state == .sit
        }
        separate()
        for f in friends {
            f.clock += dt
            let per: TimeInterval = switch f.gait {
            case .walk: 0.12
            case .eat: DogSpriteCache.extraFrameDuration(.eat)
            case .special: DogSpriteCache.extraFrameDuration(.special)
            case .sulk: DogSpriteCache.extraFrameDuration(.hungry)
            case .dizzy: 0.12
            default: 0.5
            }
            if !still, f.clock >= per { f.clock = 0; f.frame += 1 }
            layout(f, now: now)
        }
        hover()
        // Walking, falling or reacting: 30 fps. Standing about: 2 a second, the pace of its idle frames and of thinking
        // what to do next (the bounce is Core Animation's), and the pace that ends a still pose or a sit under 동작 줄이기.
        // Still with nothing to end, or behind every window: nothing until a change. A game nobody sees ends.
        let visible = panel?.occlusionState.contains(.visible) ?? false
        if !visible, playing { endGames() }
        busy = busy || playing
        if still && !busy && !waiting && pressed == nil || !visible && !busy { timer?.invalidate(); timer = nil; interval = 0; return }
        schedule(busy || pressed != nil ? 1.0 / 30 : 0.5)
    }

    /// Now and then an idle friend picks something to do: a stroll (walkers more often), a sit, a hop, or nothing.
    private func think(_ f: Friend, now: TimeInterval) {
        guard now >= f.think, f.walk.state == .idle, let w = panel?.frame.width else { return }
        f.think = now + .random(in: 3...8)
        let r = Double.random(in: 0..<1)
        let stroll = f.walker ? 0.6 : 0.15
        if r < stroll {
            f.walk.walk(to: min(max(f.walk.x + .random(in: -220...220), f.size.width / 2), w - f.size.width / 2))
        } else if r < stroll + 0.2, f.has(.sleep) {
            f.walk.state = .sit
            f.sitUntil = now + .random(in: 4...9)
        } else if r < stroll + 0.3 {
            f.walk.hop()
        }
    }

    // MARK: 친구들끼리

    /// 줄넘기: the two at the ends walk out to hold the rope, the ones between line up in the middle to jump it.
    @discardableResult
    private func startRope(now: TimeInterval) -> Bool {
        guard !still, store.prefs.jumpRope, friends.count >= 3, !friends.contains(where: \.held), let w = panel?.frame.width,
              let layer = panel?.contentView?.layer else { return false }
        let line = friends.sorted { $0.walk.x < $1.walk.x }
        let holders = [line[0], line[line.count - 1]], jumpers = Array(line.dropFirst().dropLast())
        let size = friends.map(\.size.width).max() ?? 40, step = size + 10
        let half = CGFloat(jumpers.count - 1) / 2 * step + size + 20   // the middle to a holder
        let mid = min(max(line[line.count / 2].walk.x, half + size / 2), w - half - size / 2)
        let spots = [mid - half, mid + half] + jumpers.indices.map { mid + (CGFloat($0) - CGFloat(jumpers.count - 1) / 2) * step }
        for (f, x) in zip(holders + jumpers, spots) {
            f.react = nil
            f.walk = MeadowWalk(x: f.walk.x)
            f.walk.walk(to: x)
        }
        ropeRound = RopeRound(holders: holders, jumpers: jumpers, spots: spots, gatherUntil: now + 8, until: now + 8 + JumpRope.round)
        rope.contentsScale = panel?.backingScaleFactor ?? 2
        rope.path = nil
        layer.addSublayer(rope)
        return true
    }

    /// Over: everyone back to wandering a little later.
    private func endGames() {
        let now = ProcessInfo.processInfo.systemUptime
        if ropeRound != nil { friends.forEach { $0.think = now + .random(in: 3...8) } }
        dropGames()
    }

    private func dropGames() {
        ropeRound = nil; dance = nil
        rope.removeFromSuperlayer()
    }

    /// One step of the game on, or (at the standing-about pace) now and then a new one.
    private func games(now: TimeInterval) {
        if still, playing { endGames() }   // 동작 줄이기 came on
        if ropeRound != nil { stepRope(now: now) }
        if let d = dance {
            guard let n = GroupDance.beat(now - d.start) else { dance = nil; return }
            guard n != d.beat else { return }
            dance = (d.start, n)
            let m = GroupDance.move(n)
            for f in friends where !f.held && f.react == nil {
                f.facingLeft = m.facingLeft
                if m.hop { f.walk.hop() }
                if m.note { pop("♪", .systemPurple, over: f) }
            }
        }
        guard !playing, !still, store.prefs.jumpRope, now >= gameAt else { return }
        gameAt = now + GroupPlay.gap(random: .random(in: 0..<1))
        startRope(now: now)
    }

    private func stepRope(now: TimeInterval) {
        guard var r = ropeRound else { return }
        let all = r.holders + r.jumpers
        guard now < r.until, !r.holders.contains(where: \.held), all.allSatisfy({ f in friends.contains { $0 === f } }) else { endGames(); return }
        defer { ropeRound = r; drawRope(r, now: now) }
        guard let turning = r.rope else {
            let there = zip(all, r.spots).allSatisfy { f, x in f.walk.state != .walk && abs(f.walk.x - x) < 3 || f.react != nil }
            guard there || now >= r.gatherUntil else { return }
            r.rope = JumpRope(start: now)
            r.until = now + JumpRope.round
            r.holders[0].facingLeft = false; r.holders[1].facingLeft = true
            return
        }
        let next = turning.passes(at: now)
        if next > r.hopped, now >= turning.hop(next) {   // hop for the coming pass; now and then one is late
            r.hopped = next
            for f in r.jumpers where !f.held && f.react == nil && Double.random(in: 0..<1) >= 0.06 { f.walk.hop() }
        }
        guard next - 1 > r.judged else { return }   // a pass is just over: everyone up in the air cleared it
        r.judged = next - 1
        let missed = r.jumpers.filter { !$0.held && !$0.walk.airborne }
        missed.forEach { pop(L("앗"), .systemOrange, over: $0) }
        guard r.streak.pass(cleared: missed.isEmpty) else { return }
        all.forEach { pop("♥", .systemPink, over: $0) }
        r.holders.forEach { $0.walk.hop() }
        if let j = r.jumpers.first, let i = friends.firstIndex(where: { $0 === j }) {
            SpeechBubbleCenter.shared.say(text: Self.persona(character: j.character).dress(L("열 번 연속 성공! 우리 최고예요")), source: .system,
                                          aloud: false, anchor: { [weak self] in self?.head(i) })
        }
    }

    /// The rope from hand to hand: over their heads, round behind them, under their feet and back in front.
    private func drawRope(_ r: RopeRound, now: TimeInterval) {
        guard let turning = r.rope, let a = r.holders.first, let b = r.holders.last else { rope.path = nil; return }
        let tall = r.jumpers.map(\.size.height).max() ?? a.size.height
        let hand = Self.floor + a.size.height * 0.45
        let s = turning.swing(at: now)
        let middle = s > 0 ? s * (Self.floor + tall * 1.3 - hand) : s * (hand - 2)   // the middle's height over the hands
        let p = CGMutablePath()
        p.move(to: CGPoint(x: a.walk.x + a.size.width * 0.3, y: hand))
        p.addQuadCurve(to: CGPoint(x: b.walk.x - b.size.width * 0.3, y: hand), control: CGPoint(x: (a.walk.x + b.walk.x) / 2, y: hand + 2 * middle))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rope.path = p
        rope.zPosition = turning.behind(at: now) ? -1 : 1
        CATransaction.commit()
    }

    private func separate() {
        guard let w = panel?.frame.width else { return }
        var walks = friends.map(\.walk)
        MeadowWalk.separate(&walks, widths: friends.map { $0.size.width * 0.8 }, gap: 6, lo: 0, hi: w,
                            pinned: friends.firstIndex { $0.held })
        for (f, walk) in zip(friends, walks) { f.walk = walk }
    }

    private func layout(_ f: Friend) { layout(f, now: ProcessInfo.processInfo.systemUptime) }

    private func layout(_ f: Friend, now: TimeInterval) {
        guard let set = f.frames[f.gait] ?? f.frames[.walk], !set.isEmpty else { return }
        let image = set[still ? 0 : f.frame % set.count]
        var turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat) = (0, 1, 1), pivot: CGFloat = 0
        let lift = f.lift(now, still: still)
        if let r = f.react {
            let p = r.r.reaction.pose(now - r.start, still: still)
            turn = (p.angle, p.sx, p.sy)
            if r.r.reaction == .spin { pivot = 0.5 }
            if r.r.reaction == .pout, !still { turn.sx = 1.04; turn.sy = 0.94 }   // slumped, its back to you
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if f.shown !== image { f.layer.contents = image; f.shown = image }
        f.layer.position = CGPoint(x: f.walk.x, y: Self.floor + f.walk.y + lift)
        let flip = f.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        f.layer.setAffineTransform(flip.concatenating(BuddyMath.transform(angle: turn.angle, sx: turn.sx, sy: turn.sy,
                                                                          pivot: CGPoint(x: f.size.width / 2, y: f.size.height * pivot),
                                                                          anchor: f.layer.anchorPoint, size: f.size)))
        // A small bounce where it stands; none under 동작 줄이기, while held, sitting, reacting or in the air. Core Animation
        // runs it, so a meadow of idle friends needs no fast timer of ours.
        let bob = !(still || f.held || f.walk.airborne || f.walk.state == .sit || f.react != nil)
        if bob, f.layer.animation(forKey: "bob") == nil {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0; a.toValue = 2
            a.duration = .pi / 6   // up and back down in pi/3 s, like |sin 3t|
            a.autoreverses = true
            a.repeatCount = .infinity
            a.isAdditive = true
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.timeOffset = f.phase / 3
            f.layer.add(a, forKey: "bob")
        } else if !bob, f.layer.animation(forKey: "bob") != nil {
            f.layer.removeAnimation(forKey: "bob")
        }
        CATransaction.commit()
    }

    /// A mark (♥, !, 에취!) rising over `f`'s head (`dx` to one side). Under 동작 줄이기 it does not rise, so it starts above
    /// the head instead of on the face (the mark is 35 % of the height tall and starts that far under the top).
    private func pop(_ text: String, _ color: NSColor, over f: Friend, dx: CGFloat = 0) {
        guard let layer = panel?.contentView?.layer else { return }
        let up = still ? f.size.height * 0.35 : 0
        let rect = CGRect(x: f.walk.x - f.size.width / 2 + dx, y: Self.floor + f.walk.y + up, width: f.size.width, height: f.size.height)
        FriendMark.pop(text, color: color, over: rect, in: layer, still: still, scale: panel?.backingScaleFactor ?? 2)
    }

    // MARK: Reacting

    /// `r` in place, its mark over it and (now and then) a line in a bubble over its head. It stops what it was doing
    /// for it: up in the air (a hop, or the last reaction's jump) it falls back down meanwhile; under 동작 줄이기 the
    /// pose and the mark only. The flop down is a sit of a few seconds instead, with no mark.
    private func react(_ f: Friend, _ r: MeadowReaction, now: TimeInterval, line: String? = nil) {
        guard !f.held, let i = friends.firstIndex(where: { $0 === f }) else { return }
        if r.reaction == .pout { f.facingLeft.toggle() }   // turns its back on you
        let up = f.walk.y + f.lift(now, still: still)
        f.walk = MeadowWalk(x: f.walk.x)
        if up > 0, !still { f.walk.drop(from: up) }
        f.frame = 0; f.clock = 0
        if r.sits {
            f.react = nil
            f.walk.state = .sit
            f.sitUntil = now + .random(in: 4...6)
        } else {
            f.react = (r, now)
            if let m = r.reaction.mark { pop(m.text, m.color, over: f) }
        }
        layout(f, now: now)
        let combo = r.reaction == .dizzy || r.reaction == .pout
        guard combo || now >= talkAfter else { return }
        talkAfter = now + 4
        let own = f.says[r.gait] ?? [], persona = Self.persona(character: f.character)
        let text = line.map { persona.dress($0) }
            ?? (own.isEmpty || combo ? persona.dress(LinePick.pick("meadow.\(r.reaction.rawValue).\(r.gait)", r.lines))
                                     : LinePick.pick("meadow.say.\(f.slot).\(r.gait)", own))
        SpeechBubbleCenter.shared.say(text: text, source: .system, aloud: false, repeats: true, anchor: { [weak self] in self?.head(i) })
    }

    /// Clicked: the nearest friend close by turns to look and hops a moment later, with a "?" after a dizzy or a pout.
    private func neighbourLooks(at f: Friend, worried: Bool) {
        guard let i = friends.firstIndex(where: { $0 === f }),
              let j = MeadowWalk.neighbour(of: i, in: friends.map(\.walk.x), reach: f.size.width * 3) else { return }
        let n = friends[j]
        guard !n.held, n.react == nil, !n.walk.airborne else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !n.held, n.react == nil else { return }
            n.walk = MeadowWalk(x: n.walk.x)
            n.facingLeft = f.walk.x < n.walk.x
            if !self.still { n.walk.hop() }
            self.pop(worried ? "?" : "!", worried ? .systemBlue : .systemOrange, over: n)
            n.think = ProcessInfo.processInfo.systemUptime + .random(in: 3...6)
            self.layout(n)
            self.wake()
        }
    }

    // MARK: Mouse

    private func friend(at p: CGPoint) -> Friend? {
        guard let origin = panel?.frame.origin else { return nil }
        return friends.last { f in
            guard let image = f.shown else { return false }
            let id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            var lx = p.x - origin.x - (f.walk.x - f.size.width / 2)
            if f.facingLeft { lx = f.size.width - lx }
            if hits[id]?.hits(CGPoint(x: lx, y: p.y - origin.y - f.layer.position.y), in: f.size) == true { return true }
            // Reacting it may rise off the spot it was clicked on: that spot keeps taking clicks, so the next one of a
            // combo never falls through to the window below.
            let feet = p.y - origin.y - Self.floor - f.walk.y
            return f.react != nil && lx >= 0 && lx <= f.size.width && feet >= 0 && feet <= f.size.height
        }
    }

    /// The mouse moved: the panel takes clicks only over a friend, and rubbing one pets it.
    fileprivate func hover() {
        guard let panel, pressed == nil else { return }
        let p = NSEvent.mouseLocation
        let over = panel.frame.contains(p) ? friend(at: p) : nil
        if panel.ignoresMouseEvents == (over != nil) { panel.ignoresMouseEvents = over == nil }
        let now = ProcessInfo.processInfo.systemUptime
        if rub.feed(p, over: over.flatMap { f in friends.firstIndex { $0 === f } }, at: now), let f = over, f.react == nil {
            react(f, .pet, now: now, line: LinePick.pick("meadow.pet", MeadowReaction.petLines))
            pop("♥", .systemPink, over: f, dx: f.size.width * 0.3)   // beside its blush, not on it
            wake()
        }
    }

    fileprivate func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        switch e.type {
        case .rightMouseDown: showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.option): quickAsk(friend(at: p))   // no press: its release finds nothing
        case .leftMouseDown:
            handle(clicks.mouseDown(p, at: t))
            pressed = friend(at: p)
            if let f = pressed, let o = panel?.frame.origin {
                grab = CGVector(dx: o.x + f.walk.x - p.x, dy: o.y + Self.floor + f.walk.y - p.y)
            }
        case .leftMouseDragged: handle(clicks.mouseMoved(p, at: t))
        case .leftMouseUp:
            var g = clicks.mouseUp(p, at: t)
            if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }   // answered at once: clicks in a row make a combo
            handle(g)
            pressed = nil
        default: break
        }
        wake()
    }

    /// 퀵물어보기 over `f`'s head; again while it is open closes it.
    private func quickAsk(_ f: Friend?) {
        guard let f, let panel, let i = friends.firstIndex(where: { $0 === f }) else { return }
        MainActor.assumeIsolated {
            let ask = FriendQuickAsk.shared
            ask.toggle(from: panel, key: i) { [weak self] in self?.head(i) }
        }
    }

    /// The menu swallows the button's release: a friend held up is put down first, and the press ends, so it never
    /// hangs in the air and the panel goes back to letting clicks through.
    private func showMenu(_ e: NSEvent, at p: CGPoint) {
        handle(clicks.cancel(at: p))
        pressed = nil
        guard let v = panel?.contentView else { return }
        let f = friend(at: p)
        var own: [NSMenuItem] = []
        if let f { own.append(FriendMenu.item(L("퀵물어보기")) { [weak self] in self?.quickAsk(f) }) }
        if store.prefs.jumpRope, friends.count >= 3, !still {
            own.append(FriendMenu.item(L("줄넘기")) { [weak self] in self?.endGames(); self?.startRope(now: ProcessInfo.processInfo.systemUptime); self?.wake() })
        }
        own += [
            FriendMenu.item(L("다 같이 뛰기")) { [weak self] in self?.cheer() },
            FriendMenu.item(L("다른 창보다 위에 두기"), on: store.prefs.onTop) { MeadowStore.shared.prefs.onTop.toggle() },
            FriendMenu.item(L("풀밭 친구들 치우기")) { MeadowStore.shared.prefs.on = false },
        ]
        FriendMenu.pop(own, with: e, for: v)
        hover()   // the cursor may have left the friend while the menu was up
    }

    private func handle(_ gestures: [ClickRecognizer.Gesture]) {
        guard let f = pressed, let panel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for g in gestures {
            switch g {
            case .dragBegan:
                f.held = true
                f.react = nil
                f.walk.state = .idle
            case .dragged(let p):
                f.walk.x = p.x + grab.dx - panel.frame.minX
                f.walk.y = min(max(0, p.y + grab.dy - panel.frame.minY - Self.floor), panel.frame.height - f.size.height - Self.floor)
                f.walk.vy = 0
            case .dragEnded:
                f.held = false
                f.walk.drop(from: f.walk.y)   // falls back onto the floor
                if still { f.walk = MeadowWalk(x: f.walk.x) }
            case .single, .double:   // a double never comes: singles are answered at once
                // FriendQuickAsk takes a click in its owner (this whole panel) as a toggle, so it stays open: shut it, or
                // the line's bubble lands on top of it.
                MainActor.assumeIsolated { if FriendQuickAsk.shared.isOpen { FriendQuickAsk.shared.close() } }
                let r = MeadowReaction.click(&f.combo, at: now, has: f.has, key: "meadow.react.\(f.slot)")
                FriendCry.play(r.reaction, friend: "meadow-\(f.slot)", character: f.character)
                react(f, r, now: now)
                neighbourLooks(at: f, worried: r.reaction == .dizzy || r.reaction == .pout)
            }
        }
    }

    // MARK: QA

    /// QA renders only: the panel's content layer.
    var qaLayer: CALayer? { panel?.contentView?.layer }

    /// QA renders only (FriendMark.qa on): the friends side by side, each 40 % into one reaction with its mark (a sit:
    /// sitting, no mark), as under 동작 줄이기 when `still`: the everyday ones first, then dizzy and a pout. Returns the
    /// box round them in the panel, room left for the marks.
    func qaStage(_ shown: [MeadowReaction], still qaStill: Bool = false) -> CGRect {
        let now = ProcessInfo.processInfo.systemUptime
        still = qaStill
        defer { still = DesktopKit.reduceMotion }
        var x: CGFloat = 40
        for (f, r) in zip(friends, shown) {
            f.walk = MeadowWalk(x: x + f.size.width / 2)
            x += f.size.width * 1.25
            f.facingLeft = r.reaction == .pout
            f.react = r.sits ? nil : (r, now - r.duration * 0.4)
            if r.sits { f.walk.state = .sit }
            f.frame = still ? 0 : 1
            layout(f, now: now)
            f.layer.removeAnimation(forKey: "bob")
            if let m = r.reaction.mark, !r.sits { pop(m.text, m.color, over: f) }
            if r == .pet { pop("♥", .systemPink, over: f, dx: f.size.width * 0.3) }
        }
        let box = friends.prefix(shown.count).map(\.layer.frame).reduce(CGRect.null) { $0.union($1) }
        return box.isNull ? .zero : box.insetBy(dx: -24, dy: -24).offsetBy(dx: 0, dy: 16)
    }
}

/// Never key, never main: touching a friend never takes the focus from the app in front.
private final class MeadowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MeadowView: NSView {
    weak var owner: MeadowFriends?
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Moves over a friend reach us even while another app is in front (rubbing one pets it).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { owner?.hover() }
    override func mouseDown(with event: NSEvent) { owner?.mouse(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouse(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouse(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.mouse(event) }
}
