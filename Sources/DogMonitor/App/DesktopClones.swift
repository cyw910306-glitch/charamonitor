import AppKit
import Combine
import QuartzCore

// MARK: Settings

/// One 복제 친구: who it is and where its feet stand, as shares (0...1) of the main screen's visible frame.
struct CloneSpot: Codable, Equatable, Identifiable {
    var id = UUID()
    /// An original's id, or nil for the character chosen now (as HangSlot.character).
    var character: String?
    var x: Double
    var y: Double

    init(id: UUID = UUID(), character: String?, x: Double, y: Double) {
        self.id = id; self.character = character; self.x = x; self.y = y
    }

    /// Feet at screen point `p` within `r`, kept inside it.
    init(point p: CGPoint, in r: CGRect, character: String?) {
        self.init(character: character,
                  x: r.width > 0 ? min(1, max(0, Double((p.x - r.minX) / r.width))) : 0.5,
                  y: r.height > 0 ? min(1, max(0, Double((p.y - r.minY) / r.height))) : 0)
    }

    /// Its feet (bottom middle) in `r`'s coordinates, a drawing of `size` kept wholly inside.
    func point(in r: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: r.minX + min(max(CGFloat(x) * r.width, size.width / 2), max(size.width / 2, r.width - size.width / 2)),
                y: r.minY + min(max(CGFloat(y) * r.height, 0), max(0, r.height - size.height)))
    }
}

struct ClonePrefs: Codable, Equatable {
    var on = false
    var clones: [CloneSpot] = []
    /// Off: each stands still where it was put, a decoration.
    var moves = true
    /// With each other, the cursor and the rug.
    var interacts = true
    /// 친구들끼리 (with 어울리기): now and then a round of 술래잡기, or a 기차놀이 behind the 커서 친구.
    var tag = false
    var train = false

    static let maxCount = 8

    /// False when there is no room left.
    mutating func add(_ s: CloneSpot) -> Bool {
        guard clones.count < Self.maxCount else { return false }
        clones.append(s)
        return true
    }
}

extension ClonePrefs {
    /// Settings saved before a field existed keep everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClonePrefs()
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? d.on
        clones = Array((try c.decodeIfPresent([CloneSpot].self, forKey: .clones) ?? d.clones).prefix(Self.maxCount))
        moves = try c.decodeIfPresent(Bool.self, forKey: .moves) ?? d.moves
        interacts = try c.decodeIfPresent(Bool.self, forKey: .interacts) ?? d.interacts
        tag = try c.decodeIfPresent(Bool.self, forKey: .tag) ?? d.tag
        train = try c.decodeIfPresent(Bool.self, forKey: .train) ?? d.train
    }
}

final class CloneStore: ObservableObject {
    static let shared = CloneStore()
    static let key = "desktopClones"

    private let defaults: UserDefaults
    @Published var prefs: ClonePrefs {
        didSet { if let d = try? JSONEncoder().encode(prefs) { defaults.set(d, forKey: Self.key) } }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ClonePrefs.self, from: $0) } ?? ClonePrefs()
    }
}

/// What two idle 복제 친구 close together do: say hi (face each other, hop, ♥), one chases the other, or one tags along.
enum CloneSocial {
    enum Action: Equatable { case greet, chase, follow }
    /// Farther apart than this they leave each other alone.
    static let reach: CGFloat = 160

    /// `random` 0..<1 picks the action.
    static func pick(distance: CGFloat, random: Double) -> Action? {
        guard distance <= reach else { return nil }
        return random < 0.45 ? .greet : random < 0.75 ? .chase : .follow
    }
}

// MARK: The clones

/// "복제 친구" (데스크톱 친구): copies of the 커서 친구 put on the desktop from its menu, up to 8, back where they were
/// after a restart. On their own they stroll, sit, nap and hop; with 어울리기 they greet, chase and follow each other,
/// turn to the cursor, run over when it rests nearby and sit on the 러그. A click is a Reaction (combos as the buddy),
/// ⌥ click 퀵물어보기, a drag carries one anywhere and a flick throws it (Fling). 움직이기 off: they stand as put.
/// One desktop-level panel over the main screen, taking the mouse only over a drawing. 동작 줄이기: they stand still.
final class DesktopClones {
    static let shared = DesktopClones()
    /// QA renders only: the panel stays see-through (alpha 0).
    static var qaHidden = false

    fileprivate final class Clone {
        let id: UUID
        var walk: MeadowWalk
        /// Where its feet stand in the panel (walks move it toward `groundTarget`); `walk.y` is a hop above it.
        var ground: CGFloat, groundTarget: CGFloat
        var frames: [BuddyGait: [NSImage]] = [:]
        var size = CGSize.zero
        let layer = CALayer()
        let phase = Double.random(in: 0..<(2 * .pi))
        var facingLeft = false, held = false, running = false, napping = false
        var fling: Fling?
        var react: (r: Reaction, start: TimeInterval)?
        var combo = ClickCombo()
        var think: TimeInterval = 0, sitUntil: TimeInterval = 0, touched: TimeInterval = 0
        var cursorRunAfter: TimeInterval = 0, bumpAfter: TimeInterval = 0, hoverAfter: TimeInterval = 0
        var sitOnArrival = false
        /// Walking to a 장난감 to use it there.
        var toy: (id: UUID, kind: ToyKind)?
        /// Out playing (놀이 모드): hidden, left alone and untouchable until given back.
        var lent = false
        var following: UUID?
        var frame = 0, clock: TimeInterval = 0
        var shown: NSImage?

        init(id: UUID, x: CGFloat, ground: CGFloat) {
            self.id = id; walk = MeadowWalk(x: x); self.ground = ground; groundTarget = ground
        }

        var walking: Bool { walk.state == .walk || ground != groundTarget }
        var busy: Bool { !lent && (walking || walk.airborne || fling != nil || react != nil || held) }
        var idle: Bool { !busy && walk.state == .idle && !lent }
        var gait: BuddyGait {
            if fling != nil { return .run }
            if let r = react?.r { return frames[r.gait] != nil ? r.gait : r.gait == .special && frames[.eat] != nil ? .eat : .walk }
            if held || walk.airborne { return .walk }
            if walking { return running ? .run : .walk }
            return walk.state == .sit ? .sleep : .stand
        }
        /// Runs at `speed` to `x`, feet at `y`.
        func go(x: CGFloat, y: CGFloat, run: Bool) {
            walk.speed = run ? 140 : MeadowWalk.speed
            running = run
            walk.walk(to: x)
            groundTarget = y
            napping = false
        }
    }

    private var panel: NSPanel?
    private var clones: [Clone] = []
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
    private var pressed: Clone?
    private var pressStart: TimeInterval = 0
    private var grab = CGVector.zero
    private var hovered: UUID?
    private var cursor: (p: CGPoint, since: TimeInterval) = (.zero, 0)

    /// What the sprites were made for; positions and who is out are diffed apart, so neither redraws the others.
    private struct Built: Equatable {
        var look: SpriteLook
        var colors: [String: [String: RGBColor]]
        var outfits: [String: Outfit]   // 옷 입히기 of the friends' own characters
        var pixelSize: CGFloat
        var screen: [CGRect]
    }
    private var built: Built?

    private var store: CloneStore { .shared }
    private var enabled: Bool { store.prefs.on && !store.prefs.clones.isEmpty && !asleep }
    private var moves: Bool { (store.prefs.moves || qaPosed) && !still }
    private var social: Bool { store.prefs.interacts && moves }
    /// QA renders only: poses show although 움직이기 is off (so nothing ticks).
    private var qaPosed = false

    // 친구들끼리: at most one game at a time, run from `tick` (30 fps while one is on, nothing extra otherwise).
    private struct TagRound { var it: UUID; var immune: UUID?; var runAt: TimeInterval; var until: TimeInterval }
    private struct TrainRound { var cars: [UUID]; var gap: CGFloat; var path: TrainPath; var until: TimeInterval }
    private var tagRound: TagRound?
    private var trainRound: TrainRound?
    private var dance: (start: TimeInterval, beat: Int)?
    /// When one starts on its own next.
    private var gameAt: TimeInterval = 0
    private var playing: Bool { tagRound != nil || trainRound != nil || dance != nil }
    /// "술래" over the 술래's head.
    private lazy var itMark: CATextLayer = {
        let m = CATextLayer()
        m.string = L("술래")
        m.fontSize = 10
        m.foregroundColor = NSColor.white.cgColor
        m.backgroundColor = NSColor.systemOrange.cgColor
        m.cornerRadius = 4
        m.alignmentMode = .center
        m.bounds = CGRect(x: 0, y: 0, width: 30, height: 14)
        m.zPosition = 1
        m.actions = ["position": NSNull()]
        return m
    }()

    func start() {
        guard !started else { return }
        started = true
        CloneStore.shared.objectWillChange
            .merge(with: AppSettings.shared.objectWillChange, CustomCharacterStore.shared.objectWillChange, MotionStore.shared.objectWillChange)
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
            .sink { [weak self] in self?.still = DesktopKit.reduceMotion; self?.refresh() }   // 동작 줄이기 on: walks stop as for 움직이기 off
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .filter { [weak self] in ($0.object as? NSWindow) === self?.panel }
            .sink { [weak self] _ in self?.wake() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveAll() }
            .store(in: &bag)
        DesktopKit.celebrate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cheer() }
            .store(in: &bag)
        refresh()
    }

    /// A copy of the character chosen now with its feet at screen point `p` (kept on the main screen). Says so and
    /// returns false when 8 are out already.
    // ponytail: main screen only; a buddy on another display drops its copy at the nearest edge of the main one
    @discardableResult
    func add(at p: CGPoint) -> Bool {
        guard let r = NSScreen.screens.first?.visibleFrame else { return false }
        let look = SpriteLook(AppSettings.shared)
        // ponytail: dogs, cats and custom characters copy as "the character chosen now"; a saved look if frozen copies are wanted
        var prefs = store.prefs
        guard prefs.add(CloneSpot(point: p, in: r, character: look.character == .original ? look.readyID : nil)) else {
            SpeechBubbleCenter.shared.say(text: L("바탕화면이 꽉 찼어요. 8명까지예요"), source: .system)
            return false
        }
        prefs.on = true
        store.prefs = prefs
        return true
    }

    /// 놀이 모드 takes that clone: hidden where it stands. Its drawing's rect on screen and who it is; nil when it is not out.
    func lendForPlay(_ id: UUID) -> (rect: CGRect, character: String?)? {
        guard let p = panel, p.isVisible, let c = clones.first(where: { $0.id == id }), !c.lent else { return nil }
        c.lent = true
        c.fling = nil; c.react = nil; c.held = false
        c.walk = MeadowWalk(x: c.walk.x)
        c.layer.isHidden = true
        if pressed === c { pressed = nil; clicks = ClickRecognizer() }
        let rect = CGRect(x: p.frame.minX + c.walk.x - c.size.width / 2, y: p.frame.minY + c.ground, width: c.size.width, height: c.size.height)
        return (rect, store.prefs.clones.first { $0.id == id }?.character)
    }

    /// Back from 놀이 모드 with its feet at screen point `feet` (kept on the panel), with a ✦; the spot is saved.
    func giveBackFromPlay(_ id: UUID, feet: CGPoint) {
        guard let p = panel, let c = clones.first(where: { $0.id == id }), c.lent else { return }
        c.lent = false
        c.walk = MeadowWalk(x: min(max(feet.x - p.frame.minX, c.size.width / 2), max(c.size.width / 2, p.frame.width - c.size.width / 2)))
        c.ground = min(max(0, feet.y - p.frame.minY), max(0, p.frame.height - c.size.height))
        c.groundTarget = c.ground
        c.touched = ProcessInfo.processInfo.systemUptime
        c.layer.isHidden = false
        layout(c)
        pop("✦", .systemYellow, over: c)
        save([c])
        wake()
    }

    /// 맥과 같이 놀기 (MacReactions): everyone out shows `mark` over its head, and hops too when `hop` (if they move).
    func macMark(_ mark: String, hop: Bool) {
        guard panel?.isVisible == true else { return }
        for c in clones where !c.lent && !c.held {
            pop(mark, .systemYellow, over: c)
            if hop, moves { c.walk.hop() }
        }
        if hop { wake() }
    }

    /// The top middle of that clone on screen; nil once it is gone.
    private func head(_ id: UUID) -> CGPoint? {
        guard let p = panel, p.isVisible, let c = clones.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: p.frame.minX + c.walk.x, y: p.frame.minY + c.ground + c.walk.y + c.size.height)
    }

    /// 춤춰 줘·응원해 줘: they hop one after another; with 단체 춤 they all dance to one beat for 10 s.
    private func cheer() {
        guard moves else { return }
        if GroupDance.on {
            endGames()
            for c in clones where !c.lent && !c.held && c.fling == nil { stopForGame(c) }
            dance = (ProcessInfo.processInfo.systemUptime, -1)
            wake()
            return
        }
        for (i, c) in clones.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) { [weak self] in c.walk.hop(); self?.wake() }
        }
    }

    // MARK: Building

    private func refresh() {
        // The menu bar's screen, not NSScreen.main (whichever has the key window).
        guard enabled, let screen = NSScreen.screens.first else { teardown(); return }
        let now = Built(look: SpriteLook(AppSettings.shared), colors: AppSettings.shared.characterColors, outfits: AppSettings.shared.outfits,
                        pixelSize: MotionStore.shared.buddySize.pixelSize, screen: [screen.frame, screen.visibleFrame])
        if now != built {
            saveAll()
            built = now
            build(screen: screen)
        } else {
            sync(fresh: true)
        }
        if !moves {   // 움직이기 off or 동작 줄이기: back on their feet where they are, a throw or a hop in the air ends there
            endGames()
            clones.forEach { $0.walk = MeadowWalk(x: $0.walk.x); $0.fling = nil; $0.react = nil; $0.napping = false; $0.groundTarget = $0.ground }
        }
        if tagRound != nil, !(social && store.prefs.tag) { endGames() }
        if trainRound != nil, !(social && store.prefs.train) { endGames() }
        clones.forEach(layout)
        wake()
    }

    private func build(screen: NSScreen) {
        pressed = nil
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(screen.visibleFrame, display: false)
        p.orderFrontRegardless()
        clones.forEach { $0.layer.removeFromSuperlayer() }
        clones = []
        hits = [:]
        dropGames()
        gameAt = ProcessInfo.processInfo.systemUptime + GroupPlay.gap(random: .random(in: 0..<1)) / 2
        sync(fresh: false)
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.moved() }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.moved(); return e }) { monitors.append(l) }
        }
    }

    /// Who is out follows the saved list: gone ones leave, new ones pop in (`fresh`: with a ✦ and a hop).
    private func sync(fresh: Bool) {
        guard let panel else { return }
        let spots = store.prefs.clones, ids = Set(spots.map(\.id))
        for c in clones where !ids.contains(c.id) { c.layer.removeFromSuperlayer() }
        if clones.contains(where: { !ids.contains($0.id) }) { hits = [:] }   // keyed by image: a freed one's address may come back
        clones.removeAll { !ids.contains($0.id) }
        if let p = pressed, !clones.contains(where: { $0 === p }) { pressed = nil; clicks = ClickRecognizer() }
        let have = Set(clones.map(\.id))
        for s in spots where !have.contains(s.id) {
            let c = makeClone(s, scale: panel.backingScaleFactor)
            clones.append(c)
            if fresh {
                pop("✦", .systemYellow, over: c)
                if moves { c.walk.hop() }
            }
        }
    }

    private func teardown() {
        saveAll()
        timer?.invalidate(); timer = nil; interval = 0
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        clones.forEach { $0.layer.removeFromSuperlayer() }
        dropGames()
        clones = []; pressed = nil; built = nil; hovered = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = ClonePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        if Self.qaHidden { p.alphaValue = 0 }
        p.ignoresMouseEvents = true   // until the cursor is over a clone (hover)
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)   // over the 러그 (+1), so they sit on it
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        let v = CloneView()
        v.owner = self
        v.wantsLayer = true
        p.contentView = v
        return p
    }

    private func makeClone(_ s: CloneSpot, scale: CGFloat) -> Clone {
        let cache = MeadowFriends.cache(character: s.character, pixelSize: MotionStore.shared.buddySize.pixelSize)
        let size = cache.imageSize
        let feet = s.point(in: CGRect(origin: .zero, size: panel?.frame.size ?? .zero), size: size)
        let c = Clone(id: s.id, x: feet.x, ground: feet.y)
        c.frames = BuddyGait.frames(cache).filter { !$0.value.isEmpty }
        c.size = size
        c.layer.contentsScale = scale
        c.layer.magnificationFilter = cache.smooth ? .linear : .nearest
        c.layer.bounds = CGRect(origin: .zero, size: size)
        c.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        c.layer.actions = ["position": NSNull(), "transform": NSNull(), "contents": NSNull(), "bounds": NSNull()]
        let now = ProcessInfo.processInfo.systemUptime
        c.think = now + .random(in: 1...5)
        c.touched = now
        c.facingLeft = Bool.random()
        panel?.contentView?.layer?.addSublayer(c.layer)
        return c
    }

    // MARK: Saving

    /// Where each one stands now, written only when it changed: on a drop, a landing, a rebuild and at quit, never
    /// while they wander.
    private func saveAll() { save(clones) }

    private func save(_ list: [Clone]) {
        guard let size = panel?.frame.size, size.width > 0 else { return }
        var prefs = store.prefs
        let r = CGRect(origin: .zero, size: size)
        for c in list {
            guard let i = prefs.clones.firstIndex(where: { $0.id == c.id }) else { continue }
            let s = CloneSpot(point: CGPoint(x: c.walk.x, y: c.ground), in: r, character: prefs.clones[i].character)
            (prefs.clones[i].x, prefs.clones[i].y) = (s.x, s.y)
        }
        if prefs != store.prefs { store.prefs = prefs }
    }

    private func remove(_ ids: Set<UUID>) {
        store.prefs.clones.removeAll { ids.contains($0.id) }
    }

    // MARK: Ticking

    private func wake() {
        guard !clones.isEmpty, enabled else { return }
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
        let mouse = NSEvent.mouseLocation
        handle(clicks.poll(at: now))
        // A release we never saw (a menu took it): the press ends where it is.
        if pressed != nil, now - pressStart > 0.5, NSEvent.pressedMouseButtons & 1 == 0 { handle(clicks.cancel(at: mouse)); pressed = nil }
        if mouse != cursor.p { cursor = (mouse, now) }
        let local = panel.map { CGPoint(x: mouse.x - $0.frame.minX, y: mouse.y - $0.frame.minY) }
        let over = panel.map { $0.frame.contains(mouse) } == true ? clone(at: mouse) : nil
        let h = panel?.frame.height ?? 0
        games(now: now, dt: dt)

        for c in clones where !c.held && !c.lent {
            if var f = c.fling {
                f.step(dt: dt)
                c.walk.x = f.position.x; c.ground = f.position.y; c.groundTarget = c.ground
                if f.velocity.dx < -1 { c.facingLeft = true } else if f.velocity.dx > 1 { c.facingLeft = false }
                if f.isSettled { c.fling = nil; land(c, f, now: now) } else { c.fling = f }
                continue
            }
            if let r = c.react, now - r.start >= r.r.duration { c.react = nil }
            if trainRound?.cars.contains(c.id) == true {   // a car: `games` moves it along the path, a hop still lands
                if c.walk.airborne { c.walk.step(dt: dt) }
                continue
            }
            if moves, c.react == nil, !playing { think(c, now: now) }
            c.walk.step(dt: dt)
            if c.ground != c.groundTarget, !c.walk.airborne {
                let d = c.groundTarget - c.ground, most = c.walk.speed * CGFloat(dt)
                c.ground = abs(d) <= most ? c.groundTarget : c.ground + (d > 0 ? most : -most)
            }
            if c.walk.state == .walk { if c.walk.vx < -1 { c.facingLeft = true } else if c.walk.vx > 1 { c.facingLeft = false } }
            if !c.walking, c.running || c.walk.speed != MeadowWalk.speed { c.running = false; c.walk.speed = MeadowWalk.speed }
            if !c.walking, c.sitOnArrival, c.walk.state == .idle { c.sitOnArrival = false; c.walk.state = .sit; c.sitUntil = now + .random(in: 6...14) }
            if !c.walking, let t = c.toy, c.walk.state == .idle { c.toy = nil; use(c, t, now: now) }
            if c.walk.state == .sit, now >= c.sitUntil { c.walk.state = .idle; c.napping = false }
        }
        separate(now: now)
        if social, !playing, let local { meetCursor(local, over: over, now: now, height: h) }
        if let o = over, o.id != hovered, social, now >= o.hoverAfter {   // the cursor comes onto one: a heart and a little hop
            o.hoverAfter = now + 3
            o.touched = now
            if o.idle || o.walk.state == .sit { o.walk.state = .idle; o.napping = false; o.walk.hop() }
            pop("♥", .systemPink, over: o)
        }
        hovered = over?.id

        var busy = false
        for c in clones {
            c.clock += dt
            let per: TimeInterval = switch c.gait {
            case .walk: 0.12
            case .run: 0.07
            case .eat: DogSpriteCache.extraFrameDuration(.eat)
            case .special: DogSpriteCache.extraFrameDuration(.special)
            case .sulk: DogSpriteCache.extraFrameDuration(.hungry)
            case .dizzy: 0.12
            default: 0.5
            }
            if moves, c.clock >= per { c.clock = 0; c.frame += 1 }
            layout(c, now: now)
            busy = busy || c.busy
        }
        // A game behind every window ends: nobody would see it, and it would keep the frames at 30 fps.
        let visible = panel?.occlusionState.contains(.visible) ?? false
        if !visible, playing { endGames() }
        busy = busy || playing
        if let r = tagRound, let it = clones.first(where: { $0.id == r.it }) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            itMark.position = CGPoint(x: it.walk.x, y: it.ground + it.walk.y + it.size.height + 10)
            CATransaction.commit()
        }
        hover()
        // Walking, flying, reacting or held: 30 fps. Standing about: 2 a second (the bob is Core Animation's). Still, or
        // 움직이기 off, or behind every window: nothing until a change.
        if !moves && !busy && pressed == nil || !visible && !busy { timer?.invalidate(); timer = nil; interval = 0; return }
        schedule(busy || pressed != nil ? 1.0 / 30 : 0.5)
    }

    /// Now and then an idle one picks something: a stroll, a sit, a nap (after a minute untouched), a hop, the rug, a
    /// 장난감 nearby, or (어울리기) a friend nearby.
    private func think(_ c: Clone, now: TimeInterval) {
        guard now >= c.think, c.idle || c.walk.state == .sit && c.napping, let size = panel?.frame.size else { return }
        c.think = now + .random(in: 3...8)
        if c.napping {   // zzz, and now and then it wakes up
            if Double.random(in: 0..<1) < 0.2 { c.napping = false; c.walk.state = .idle } else { pop("z", .systemBlue, over: c) }
            return
        }
        let w = c.size.width
        if let id = c.following, let b = clones.first(where: { $0.id == id }), store.prefs.interacts, Double.random(in: 0..<1) < 0.6 {
            c.go(x: b.walk.x + (c.walk.x < b.walk.x ? -1 : 1) * (w + b.size.width) / 2 + 6, y: b.groundTarget, run: false)
            return
        }
        c.following = nil
        if store.prefs.interacts, let b = nearest(to: c), let a = CloneSocial.pick(distance: abs(b.walk.x - c.walk.x), random: .random(in: 0..<1)),
           Double.random(in: 0..<1) < 0.35 {
            meet(c, b, a, now: now)
            return
        }
        let r = Double.random(in: 0..<1)
        if store.prefs.interacts, r < 0.15, RugStore.shared.prefs.on, let rug = rug(inset: c.size) {
            c.go(x: .random(in: rug.minX...rug.maxX), y: .random(in: rug.minY...rug.maxY), run: false)
            c.sitOnArrival = true
        } else if store.prefs.interacts, r < 0.3, let o = panel?.frame.origin,
                  let t = ToyBox.shared.pick(near: CGPoint(x: o.x + c.walk.x, y: o.y + c.ground), reach: 400) {
            let s = t.kind.spot(in: t.frame, width: w, fromX: o.x + c.walk.x)
            c.go(x: min(max(s.x - o.x, w / 2), size.width - w / 2), y: min(max(s.y - o.y, 0), size.height - c.size.height), run: false)
            c.toy = (t.id, t.kind)
        } else if r < 0.5 {
            c.go(x: min(max(c.walk.x + .random(in: -220...220), w / 2), size.width - w / 2),
                 y: min(max(c.ground + .random(in: -40...40), 0), size.height - c.size.height), run: false)
        } else if r < 0.7 {
            c.walk.state = .sit
            c.sitUntil = now + .random(in: 4...9)
        } else if r < 0.8, now - c.touched >= 60 {
            c.walk.state = .sit
            c.napping = true
            c.sitUntil = now + .random(in: 15...40)
            pop("z", .systemBlue, over: c)
        } else if r < 0.9 {
            c.walk.hop()
        }
    }

    /// At a 장난감: bounces on the 트램펄린, kicks the 공 and runs after it, naps on the 쿠션, goes down the 미끄럼틀.
    private func use(_ c: Clone, _ t: (id: UUID, kind: ToyKind), now: TimeInterval) {
        guard let o = panel?.frame.origin, let size = panel?.frame.size, let f = ToyBox.shared.frame(of: t.id) else { return }
        let s = t.kind.spot(in: f, width: c.size.width, fromX: o.x + c.walk.x)
        guard hypot(s.x - o.x - c.walk.x, s.y - o.y - c.ground) < 16 else { return }   // stopped short (a bump): never mind
        c.think = now + .random(in: 4...8)
        let w = c.size.width
        switch t.kind {
        case .trampoline:
            for k in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(k)) { [weak self] in
                    guard let self, !c.held, !c.lent, c.fling == nil, c.react == nil, !c.walking else { return }
                    c.walk.state = .hop
                    c.walk.vy = MeadowWalk.hopSpeed * 1.6   // the mat throws it higher than a hop
                    ToyBox.shared.played(t.id, dir: 0)
                    self.wake()
                }
            }
            pop("♪", .systemPurple, over: c)
        case .ball:
            let dir: CGFloat = s.x < f.midX ? 1 : -1
            c.facingLeft = dir < 0
            ToyBox.shared.played(t.id, dir: dir)
            c.go(x: min(max(c.walk.x + dir * ToyPhysics.rollDistance(320), w / 2), size.width - w / 2), y: c.ground, run: true)
            pop("!", .systemOrange, over: c)
        case .cushion, .cloud:
            c.walk.state = .sit
            c.napping = true
            c.sitUntil = now + .random(in: 12...30)
            ToyBox.shared.played(t.id, dir: 0)
            pop("z", .systemBlue, over: c)
        case .slide:
            let end = ToyKind.chute(f).bottom
            c.facingLeft = false
            c.go(x: min(max(end.x - o.x + w * 0.3, w / 2), size.width - w / 2), y: max(0, f.minY - o.y), run: true)
            pop("♪", .systemYellow, over: c)
        }
    }

    /// The closest idle one standing on about the same level.
    private func nearest(to c: Clone) -> Clone? {
        clones.filter { $0 !== c && $0.idle && abs($0.ground - c.ground) < c.size.height }
            .min { abs($0.walk.x - c.walk.x) < abs($1.walk.x - c.walk.x) }
    }

    private func meet(_ a: Clone, _ b: Clone, _ action: CloneSocial.Action, now: TimeInterval) {
        b.think = now + .random(in: 3...6)
        let w = panel?.frame.width ?? 0
        switch action {
        case .greet:
            a.facingLeft = b.walk.x < a.walk.x
            b.facingLeft = !a.facingLeft
            a.walk.hop(); b.walk.hop()
            pop("♥", .systemPink, over: a); pop("♥", .systemPink, over: b)
        case .chase:
            let away: CGFloat = b.walk.x >= a.walk.x ? 1 : -1
            a.go(x: b.walk.x, y: b.ground, run: true)
            b.go(x: min(max(b.walk.x + away * .random(in: 120...260), b.size.width / 2), w - b.size.width / 2), y: b.ground, run: true)
            pop("!", .systemOrange, over: b)
        case .follow:
            a.following = b.id
            a.go(x: b.walk.x + (a.walk.x < b.walk.x ? -1 : 1) * (a.size.width + b.size.width) / 2 + 6, y: b.groundTarget, run: false)
        }
    }

    /// The 러그's box in the panel, shrunk so a clone of `size` stands wholly on it; nil when off or too small.
    private func rug(inset size: CGSize) -> CGRect? {
        guard let o = panel?.frame.origin, let r = DesktopRug.shared.footprint() else { return nil }
        let box = r.offsetBy(dx: -o.x, dy: -o.y).insetBy(dx: size.width / 2, dy: size.height * 0.2)
        return box.width > 0 && box.height > 0 ? box : nil
    }

    /// Turns to look at a cursor nearby; when it rests near (not on) them, the nearest idle one runs over, at most
    /// every 8 s each.
    private func meetCursor(_ p: CGPoint, over: Clone?, now: TimeInterval, height: CGFloat) {
        for c in clones where c.idle && hypot(p.x - c.walk.x, p.y - c.ground) < 300 { c.facingLeft = p.x < c.walk.x }
        guard over == nil, now - cursor.since >= 0.6 else { return }
        let near = clones.filter { $0.idle && now >= $0.cursorRunAfter && hypot(p.x - $0.walk.x, p.y - $0.ground) < 200 }
        guard let c = near.min(by: { hypot(p.x - $0.walk.x, p.y - $0.ground) < hypot(p.x - $1.walk.x, p.y - $1.ground) }),
              hypot(p.x - c.walk.x, p.y - c.ground - c.size.height / 2) > c.size.width else { return }
        c.cursorRunAfter = now + 8
        let w = panel?.frame.width ?? 0   // a cursor on another display: as far as the edge, never off the panel
        c.go(x: min(max(p.x, c.size.width / 2), w - c.size.width / 2), y: min(max(p.y - c.size.height / 2, 0), height - c.size.height), run: true)
    }

    /// Ones standing on about the same level keep a little room between them; two walking into each other bump
    /// (a hop and a "!"). 움직이기 off: none of it, they stay as put, side by side if so.
    private func separate(now: TimeInterval) {
        guard moves, let w = panel?.frame.width else { return }
        let cars = Set(trainRound?.cars ?? [])   // a train keeps its own spacing
        var left = clones.filter { !$0.held && !$0.lent && $0.fling == nil && !cars.contains($0.id) }.sorted { $0.ground < $1.ground }
        while let first = left.first {
            let shelf = left.prefix { $0.ground - first.ground < first.size.height * 0.6 }
            left.removeFirst(shelf.count)
            guard shelf.count > 1 else { continue }
            let group = Array(shelf)
            var walks = group.map(\.walk)
            MeadowWalk.separate(&walks, widths: group.map { $0.size.width * 0.8 }, gap: 6, lo: 0, hi: w)
            for (c, walk) in zip(group, walks) {
                if c.walk.state == .walk, abs(walk.x - c.walk.x) > 0.5, now >= c.bumpAfter {
                    c.bumpAfter = now + 4
                    c.walk = walk
                    c.walk.hop()   // stops the walk
                    c.groundTarget = c.ground
                    c.following = nil
                    pop("!", .systemOrange, over: c)
                } else {
                    c.walk = walk
                }
            }
        }
    }

    /// Down from a throw: dizzy after a hard landing or a lot of bouncing, else happy; its new spot is saved.
    private func land(_ c: Clone, _ f: Fling, now: TimeInterval) {
        c.walk = MeadowWalk(x: c.walk.x)
        react(c, f.impact > 1500 || f.bounces >= 4 ? .dizzy : .hearts, now: now)
        save([c])
    }

    private func react(_ c: Clone, _ r: Reaction, now: TimeInterval) {
        c.touched = now
        c.napping = false
        if c.walk.state == .sit { c.walk.state = .idle }
        if r == .pout { c.facingLeft.toggle() }   // turns its back on you
        if moves {   // 움직이기 off or 동작 줄이기: the mark only
            c.react = (r, now)
            c.walk = MeadowWalk(x: c.walk.x)   // stops where it is for it, as the 커서 친구 does
            c.groundTarget = c.ground
            c.following = nil; c.sitOnArrival = false; c.toy = nil
        }
        if let m = r.mark { pop(m.text, m.color, over: c) } else if !moves { pop("♥", .systemPink, over: c) }
    }

    // MARK: 친구들끼리

    /// Who can join a game now: out, not held up and not flying.
    private var players: [Clone] { clones.filter { !$0.lent && !$0.held && $0.fling == nil } }

    /// Stops what it was doing (a walk, a nap, tagging along) to join in.
    private func stopForGame(_ c: Clone) {
        c.walk = MeadowWalk(x: c.walk.x)
        c.groundTarget = c.ground
        c.react = nil; c.napping = false; c.following = nil; c.sitOnArrival = false; c.running = false; c.toy = nil
    }

    /// 술래잡기 or 기차놀이 from a menu: says why when it cannot start.
    private func startGame(tag: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        endGames()
        if tag ? !startTag(now: now) : !startTrain(now: now) {
            SpeechBubbleCenter.shared.say(text: tag ? L("술래잡기는 복제 친구가 두 명 있어야 해요") : L("기차놀이는 커서 친구가 나와 있어야 해요"),
                                          source: .system)
        }
        wake()
    }

    @discardableResult
    private func startTag(now: TimeInterval) -> Bool {
        let ps = players
        guard social, store.prefs.tag, ps.count >= 2, let it = ps.randomElement(), let layer = panel?.contentView?.layer else { return false }
        ps.forEach(stopForGame)
        tagRound = TagRound(it: it.id, immune: nil, runAt: now + CloneTag.count, until: now + CloneTag.round)
        itMark.contentsScale = panel?.backingScaleFactor ?? 2
        layer.addSublayer(itMark)
        it.walk.hop()
        pop("!", .systemOrange, over: it)
        return true
    }

    @discardableResult
    private func startTrain(now: TimeInterval) -> Bool {
        let ps = players
        guard social, store.prefs.train, !ps.isEmpty, let p = panel, let lead = CursorBuddy.shared.feet() else { return false }
        let head = CGPoint(x: lead.x - p.frame.minX, y: lead.y - p.frame.minY)
        let cars = ps.sorted { hypot($0.walk.x - head.x, $0.ground - head.y) < hypot($1.walk.x - head.x, $1.ground - head.y) }
        cars.forEach(stopForGame)
        let gap = (cars.map(\.size.width).max() ?? 40) + 4
        // Laid out through where they stand now, so each first walks to its place in line instead of all to one point.
        var path = TrainPath(maxLength: gap * CGFloat(cars.count + 1) + 200)
        for c in cars.reversed() { path.add(CGPoint(x: c.walk.x, y: c.ground)) }
        path.add(head)
        trainRound = TrainRound(cars: cars.map(\.id), gap: gap, path: path, until: now + 25)
        cars.forEach { pop("!", .systemOrange, over: $0) }
        return true
    }

    /// Over: the 술래잡기 players sit down for a rest, the train cars stop where they are; spots are saved.
    private func endGames() {
        let now = ProcessInfo.processInfo.systemUptime
        if tagRound != nil {
            for c in players {
                stopForGame(c)
                c.walk.state = .sit
                c.sitUntil = now + .random(in: 6...10)
                c.think = c.sitUntil
            }
        }
        if let r = trainRound {
            for c in clones where r.cars.contains(c.id) && !c.lent {
                stopForGame(c)
                c.think = now + .random(in: 3...8)
                pop("♥", .systemPink, over: c)
            }
        }
        if tagRound != nil || trainRound != nil { save(clones.filter { !$0.lent }) }
        dropGames()
    }

    /// Forgets any game at once (the clones are rebuilt or put away).
    private func dropGames() {
        tagRound = nil; trainRound = nil; dance = nil
        itMark.removeFromSuperlayer()
    }

    /// One step of the game on, or (at the standing-about pace) now and then a new one.
    private func games(now: TimeInterval, dt: TimeInterval) {
        if tagRound != nil { stepTag(now: now) }
        if trainRound != nil { stepTrain(now: now, dt: dt) }
        if let d = dance {
            guard let n = GroupDance.beat(now - d.start) else { dance = nil; return }
            guard n != d.beat else { return }
            dance = (d.start, n)
            let m = GroupDance.move(n)
            for c in players {
                c.facingLeft = m.facingLeft
                if m.hop { c.walk.hop() }
                if m.note { pop("♪", .systemPurple, over: c) }
            }
        }
        guard !playing, social, now >= gameAt, store.prefs.tag || store.prefs.train else { return }
        gameAt = now + GroupPlay.gap(random: .random(in: 0..<1))
        let tagFirst = store.prefs.tag && (!store.prefs.train || Bool.random())
        if !(tagFirst ? startTag(now: now) : startTrain(now: now)) { _ = tagFirst ? startTrain(now: now) : startTag(now: now) }
    }

    private func stepTag(now: TimeInterval) {
        guard var r = tagRound, let size = panel?.frame.size else { return }
        let ps = players
        guard now < r.until, ps.count >= 2, clones.contains(where: { $0.id == r.it && !$0.lent }) else { endGames(); return }
        let points = ps.map { CGPoint(x: $0.walk.x, y: $0.ground) }
        // Held up or flying, the 술래 is not in `ps`: the others just keep away meanwhile.
        if let i = ps.firstIndex(where: { $0.id == r.it }), now >= r.runAt {
            let it = ps[i], immune = ps.firstIndex { $0.id == r.immune }
            if let j = CloneTag.tagged(it: i, at: points, reach: it.size.width * 0.8 + 14, immune: immune) {
                let caught = ps[j]   // counts to one where it stands, then runs
                r = TagRound(it: caught.id, immune: it.id, runAt: now + CloneTag.count, until: r.until)
                stopForGame(caught)
                caught.walk.hop()
                pop("!", .systemOrange, over: caught)
            } else if now >= it.think, let q = CloneTag.quarry(it: i, at: points, immune: immune) {
                it.think = now + 0.3
                it.go(x: ps[q].walk.x, y: ps[q].ground, run: true)
                it.walk.speed = 150   // a bit quicker than the ones running away, so a round has tags
            }
        }
        tagRound = r
        guard let it = clones.first(where: { $0.id == r.it }) else { return }
        for c in ps where c !== it && now >= c.think && hypot(c.walk.x - it.walk.x, c.ground - it.ground) < 260 {
            c.think = now + .random(in: 0.5...0.9)
            let x = CloneTag.flee(me: c.walk.x, it: it.walk.x, lo: c.size.width / 2, hi: size.width - c.size.width / 2, run: .random(in: 120...220))
            c.go(x: x, y: min(max(c.ground + .random(in: -30...30), 0), max(0, size.height - c.size.height)), run: true)
            c.walk.speed = 120
        }
    }

    private func stepTrain(now: TimeInterval, dt: TimeInterval) {
        guard var r = trainRound, let p = panel else { return }
        guard now < r.until, let lead = CursorBuddy.shared.feet() else { endGames(); return }
        let s = p.frame.size
        r.path.add(CGPoint(x: min(max(lead.x - p.frame.minX, 0), s.width), y: min(max(lead.y - p.frame.minY, 0), s.height)))
        trainRound = r
        for (k, id) in r.cars.enumerated() {
            guard let c = clones.first(where: { $0.id == id }), !c.lent, !c.held, c.fling == nil, c.react == nil,
                  let to = r.path.point(behind: r.gap * CGFloat(k + 1)) else { continue }
            let tx = min(max(to.x, c.size.width / 2), max(c.size.width / 2, s.width - c.size.width / 2))
            let ty = min(max(to.y, 0), max(0, s.height - c.size.height))
            let dx = tx - c.walk.x, dy = ty - c.ground, d = hypot(dx, dy), most = 320 * CGFloat(dt)
            if d > 0.5 {
                let f = min(1, most / d)
                c.walk.x += dx * f; c.ground += dy * f
                if abs(dx) > 0.5 { c.facingLeft = dx < 0 }
            }
            c.walk.target = c.walk.x; c.groundTarget = c.ground
            c.walk.state = d > 1 ? .walk : .idle
            c.running = d > 40
        }
    }

    private func layout(_ c: Clone) { layout(c, now: ProcessInfo.processInfo.systemUptime) }

    private func layout(_ c: Clone, now: TimeInterval) {
        guard let set = c.frames[c.gait] ?? c.frames[.walk], !set.isEmpty else { return }
        let image = set[moves ? c.frame % set.count : 0]
        var turn: (angle: CGFloat, sx: CGFloat, sy: CGFloat) = (0, 1, 1), pivot: CGFloat = 0, lift: CGFloat = 0
        if let f = c.fling, !still {
            turn = (-f.spin, 1, 1); pivot = 0.5
        } else if let r = c.react {
            let p = r.r.pose(now - r.start, still: still)
            turn = (p.angle, p.sx, p.sy); lift = p.lift * c.size.height
            if r.r.spins { pivot = 0.5 }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if c.shown !== image { c.layer.contents = image; c.shown = image }
        c.layer.position = CGPoint(x: c.walk.x, y: c.ground + c.walk.y + lift)
        let flip = c.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        c.layer.setAffineTransform(flip.concatenating(BuddyMath.transform(angle: turn.angle, sx: turn.sx, sy: turn.sy,
                                                                          pivot: CGPoint(x: c.size.width / 2, y: c.size.height * pivot),
                                                                          anchor: c.layer.anchorPoint, size: c.size)))
        // A small bounce where it stands, from Core Animation, so a desk of idle clones needs no fast timer of ours.
        let bob = moves && c.idle
        if bob, c.layer.animation(forKey: "bob") == nil {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0; a.toValue = 2
            a.duration = .pi / 6
            a.autoreverses = true
            a.repeatCount = .infinity
            a.isAdditive = true
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.timeOffset = c.phase / 3
            c.layer.add(a, forKey: "bob")
        } else if !bob, c.layer.animation(forKey: "bob") != nil {
            c.layer.removeAnimation(forKey: "bob")
        }
        CATransaction.commit()
    }

    private func pop(_ text: String, _ color: NSColor, over c: Clone) {
        guard let layer = panel?.contentView?.layer else { return }
        let rect = CGRect(x: c.walk.x - c.size.width / 2, y: c.ground + c.walk.y, width: c.size.width, height: c.size.height)
        FriendMark.pop(text, color: color, over: rect, in: layer, still: still, scale: panel?.backingScaleFactor ?? 2)
    }

    // MARK: Mouse

    private func clone(at p: CGPoint) -> Clone? {
        guard let origin = panel?.frame.origin else { return nil }
        return clones.last { c in
            guard !c.lent, let image = c.shown else { return false }
            let id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            var lx = p.x - origin.x - (c.walk.x - c.size.width / 2)
            if c.facingLeft { lx = c.size.width - lx }
            if hits[id]?.hits(CGPoint(x: lx, y: p.y - origin.y - c.layer.position.y), in: c.size) == true { return true }
            // Hopping or reacting it rises off the spot it was clicked on: that spot keeps taking clicks, so the next
            // one of a combo never falls through to the window below.
            let feet = p.y - origin.y - c.ground
            return (c.react != nil || c.walk.airborne) && lx >= 0 && lx <= c.size.width && feet >= 0 && feet <= c.size.height
        }
    }

    /// The mouse moved anywhere: only near a clone does it wake the tick, so moving elsewhere costs nothing.
    private func moved() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation, o = panel.frame.origin
        let near = clones.contains { c in
            let dx = p.x - o.x - c.walk.x, dy = p.y - o.y - c.ground
            return dx * dx + dy * dy < 300 * 300
        }
        if near { hover(); wake() } else if !panel.ignoresMouseEvents { hover() }
    }

    private func hover() {
        guard let panel, pressed == nil else { return }
        let p = NSEvent.mouseLocation
        let over = panel.frame.contains(p) && clone(at: p) != nil
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    fileprivate func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        switch e.type {
        case .rightMouseDown: showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.option): quickAsk(clone(at: p))
        case .leftMouseDown:
            handle(clicks.mouseDown(p, at: t))
            pressed = clone(at: p)
            pressStart = t
            if let c = pressed, let o = panel?.frame.origin {
                grab = CGVector(dx: o.x + c.walk.x - p.x, dy: o.y + c.ground + c.walk.y - p.y)
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

    private func quickAsk(_ c: Clone?) {
        guard let c, let panel else { return }
        let id = c.id
        MainActor.assumeIsolated {
            let ask = FriendQuickAsk.shared
            ask.toggle(from: panel, key: id) { [weak self] in self?.head(id) }
        }
    }

    /// The menu swallows the button's release: a clone held up is put down first and the press ends, so the panel goes
    /// back to letting clicks through.
    private func showMenu(_ e: NSEvent, at p: CGPoint) {
        handle(clicks.cancel(at: p))
        pressed = nil
        guard let v = panel?.contentView else { return }
        let id = clone(at: p)?.id
        var own: [NSMenuItem] = []
        if let id {
            own.append(FriendMenu.item(L("이 친구 치우기")) { [weak self] in self?.remove([id]) })
            own.append(FriendMenu.submenu(L("놀이"), StarGame.menuItems(.clone(id))))
        }
        if social, store.prefs.tag { own.append(FriendMenu.item(L("술래잡기")) { [weak self] in self?.startGame(tag: true) }) }
        if social, store.prefs.train { own.append(FriendMenu.item(L("기차놀이")) { [weak self] in self?.startGame(tag: false) }) }
        own += [
            FriendMenu.item(L("모두 치우기")) { CloneStore.shared.prefs.clones = [] },
            FriendMenu.item(L("움직이기"), on: store.prefs.moves) { CloneStore.shared.prefs.moves.toggle() },
        ]
        FriendMenu.pop(own, with: e, for: v)
        hover()   // the cursor may have left the clone while the menu was up
    }

    private func handle(_ gestures: [ClickRecognizer.Gesture]) {
        guard let c = pressed, let panel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for g in gestures {
            switch g {
            case .dragBegan:
                c.held = true
                c.fling = nil; c.react = nil
                c.walk = MeadowWalk(x: c.walk.x)
                c.napping = false; c.following = nil; c.sitOnArrival = false; c.toy = nil
            case .dragged(let p):
                c.walk.x = min(max(p.x + grab.dx - panel.frame.minX, c.size.width / 2), panel.frame.width - c.size.width / 2)
                c.ground = min(max(0, p.y + grab.dy - panel.frame.minY), panel.frame.height - c.size.height)
                c.groundTarget = c.ground
                layout(c, now: now)
            case .dragEnded(_, let v):
                c.held = false
                c.touched = now
                if moves, hypot(v.dx, v.dy) >= BuddyMath.throwMin {
                    let s = panel.frame.size
                    let walls = CGRect(x: c.size.width / 2, y: 0, width: max(0, s.width - c.size.width), height: max(0, s.height - c.size.height))
                    c.fling = Fling(at: CGPoint(x: c.walk.x, y: c.ground), velocity: v, walls: walls)
                    FriendCry.play(.hop, friend: "clone-\(c.id)", character: store.prefs.clones.first { $0.id == c.id }?.character)
                } else {
                    save([c])   // put down right where it is
                }
            case .single, .double:
                let r = c.combo.click(at: now)
                FriendCry.play(r, friend: "clone-\(c.id)", character: store.prefs.clones.first { $0.id == c.id }?.character)
                react(c, r, now: now)
            }
        }
    }

    // MARK: QA

    /// QA renders only: the panel's content layer.
    var qaLayer: CALayer? { panel?.contentView?.layer }

    /// QA renders only (needs 5 out, 움직이기 off, FriendMark.qa): one sitting with a z, one mid-hop, one blushing, two
    /// saying hi. Returns the box round them in the panel, room left for the marks.
    func qaStage() -> CGRect {
        guard clones.count >= 5 else { return .zero }
        let now = ProcessInfo.processInfo.systemUptime
        let (sit, hop, blush, a, b) = (clones[0], clones[1], clones[2], clones[3], clones[4])
        sit.walk.state = .sit
        hop.walk.y = hop.size.height * 0.45; hop.facingLeft = true
        a.facingLeft = false; b.facingLeft = true
        blush.react = (.blush, now - Reaction.blush.duration * 0.4)
        qaPosed = true
        clones.forEach { layout($0, now: now) }
        pop("z", .systemBlue, over: sit)
        pop("///", .systemPink, over: blush)
        pop("♥", .systemPink, over: a); pop("♥", .systemPink, over: b)
        qaPosed = false
        let box = clones.map(\.layer.frame).reduce(CGRect.null) { $0.union($1) }
        return box.insetBy(dx: -24, dy: -24).offsetBy(dx: 0, dy: 12)
    }
}

/// Never key, never main: touching a clone never takes the focus from the app in front.
private final class ClonePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CloneView: NSView {
    weak var owner: DesktopClones?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouse(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouse(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouse(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.mouse(event) }
}
