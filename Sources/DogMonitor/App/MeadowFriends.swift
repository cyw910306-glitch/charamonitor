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
}

// MARK: Friends on the floor

/// "풀밭 친구들" (데스크톱 친구): 1~6 friends live along the bottom of the main screen, above the Dock, on the desktop
/// (windows cover them) or on top. Each bobs where it stands; some stroll, sit or hop now and then; they keep a little
/// room between them. A click opens 퀵물어보기 over that friend, a drag picks it up and it falls when let go, a right
/// click is the menu bar menu. No background art: the user's own desktop shows through. Under 동작 줄이기 they stand still.
final class MeadowFriends {
    static let shared = MeadowFriends()
    /// QA renders only: the panel stays see-through (alpha 0).
    static var qaHidden = false

    fileprivate final class Friend {
        let slot: Int
        var walk: MeadowWalk
        var walking: [NSImage] = [], standing: [NSImage] = [], sitting: [NSImage] = []
        var size = CGSize.zero
        let layer = CALayer()
        let phase = Double.random(in: 0..<(2 * .pi))
        /// Odd places stroll about more; the others mostly stand.
        var walker: Bool { slot % 2 == 1 }
        var frame = 0, clock: TimeInterval = 0
        var think: TimeInterval = 0, sitUntil: TimeInterval = 0
        var facingLeft = false
        var held = false
        var shown: NSImage?

        init(slot: Int, x: CGFloat) { self.slot = slot; walk = MeadowWalk(x: x) }

        var frames: [NSImage] {
            if walk.state == .walk || walk.airborne { return walking }
            return walk.state == .sit ? sitting : standing
        }
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
            .sink { [weak self] _ in self?.cheer() }
            .store(in: &bag)
        refresh()
    }

    /// The top middle of friend `i` on screen; nil while off or when there is no such friend.
    func head(_ i: Int) -> CGPoint? {
        guard let p = panel, p.isVisible, friends.indices.contains(i) else { return nil }
        let f = friends[i]
        return CGPoint(x: p.frame.minX + f.walk.x, y: p.frame.minY + Self.floor + f.walk.y + f.size.height)
    }

    /// 춤춰 줘·응원해 줘: they hop one after another.
    private func cheer() {
        guard !still else { return }
        for (i, f) in friends.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) { [weak self] in f.walk.hop(); self?.wake() }
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
        let v = MeadowView()
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

    private func makeFriend(_ i: Int, _ slot: HangSlot, width: CGFloat, target: CGFloat, scale: CGFloat) -> Friend {
        let f = Friend(slot: i, x: width * CGFloat(slot.x))
        var smooth = false
        if let path = slot.imagePath, let picture = NSImage(contentsOfFile: path) {
            f.walking = [HangingFriends.framed(picture)]
            f.standing = f.walking; f.sitting = f.walking
            smooth = true
        } else {
            func cache(_ px: CGFloat) -> DogSpriteCache { Self.cache(character: slot.character, pixelSize: px) }
            let base = cache(1).imageSize.height
            let c = cache(max(1, (target / max(1, base)).rounded()))
            f.walking = c.frames(for: .walk)
            // Every third one holds something of its own (its 냠냠 frames: a cup, a snack) while it stands.
            f.standing = i % 3 == 2 ? c.frames(forExtra: .eat) ?? Array(f.walking.prefix(1)) : Array(f.walking.prefix(1))
            f.sitting = c.frames(for: .lying)
            smooth = c.smooth
        }
        f.size = f.walking.first?.size ?? .zero
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
        var busy = false
        for f in friends where !f.held {
            if !still { think(f, now: now) }
            f.walk.step(dt: dt)
            if f.walk.state == .sit, now >= f.sitUntil { f.walk.state = .idle }
            if f.walk.vx < -1 { f.facingLeft = true } else if f.walk.vx > 1 { f.facingLeft = false }
            busy = busy || f.walk.state == .walk || f.walk.airborne
        }
        separate()
        for f in friends {
            f.clock += dt
            let per = f.walk.state == .walk ? 0.12 : 0.5
            if !still, f.clock >= per { f.clock = 0; f.frame += 1 }
            layout(f)
        }
        hover()
        // Walking or falling: 30 fps. Standing about: 2 a second, the pace of its idle frames and of thinking what to do
        // next (the bounce is Core Animation's). Still, or behind every window: nothing until a change.
        let visible = panel?.occlusionState.contains(.visible) ?? false
        if still && !busy && pressed == nil || !visible && !busy { timer?.invalidate(); timer = nil; interval = 0; return }
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
        } else if r < stroll + 0.2, !f.sitting.isEmpty {
            f.walk.state = .sit
            f.sitUntil = now + .random(in: 4...9)
        } else if r < stroll + 0.3 {
            f.walk.hop()
        }
    }

    private func separate() {
        guard let w = panel?.frame.width else { return }
        var walks = friends.map(\.walk)
        MeadowWalk.separate(&walks, widths: friends.map { $0.size.width * 0.8 }, gap: 6, lo: 0, hi: w,
                            pinned: friends.firstIndex { $0.held })
        for (f, walk) in zip(friends, walks) { f.walk = walk }
    }

    private func layout(_ f: Friend) {
        let set = f.frames
        guard !set.isEmpty else { return }
        let image = set[f.frame % set.count]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if f.shown !== image { f.layer.contents = image; f.shown = image }
        f.layer.position = CGPoint(x: f.walk.x, y: Self.floor + f.walk.y)
        f.layer.setAffineTransform(f.facingLeft ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        // A small bounce where it stands; none under 동작 줄이기, while held, sitting or in the air. Core Animation runs it,
        // so a meadow of idle friends needs no fast timer of ours.
        let bob = !(still || f.held || f.walk.airborne || f.walk.state == .sit)
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

    // MARK: Mouse

    private func friend(at p: CGPoint) -> Friend? {
        guard let origin = panel?.frame.origin else { return nil }
        return friends.last { f in
            guard let image = f.shown else { return false }
            let id = ObjectIdentifier(image)
            if hits[id] == nil { hits[id] = AlphaHit(image) }
            var lx = p.x - origin.x - (f.walk.x - f.size.width / 2)
            if f.facingLeft { lx = f.size.width - lx }
            let ly = p.y - origin.y - (f.layer.position.y)
            return hits[id]?.hits(CGPoint(x: lx, y: ly), in: f.size) ?? false
        }
    }

    private func hover() {
        guard let panel, pressed == nil else { return }
        let p = NSEvent.mouseLocation
        let over = panel.frame.contains(p) && friend(at: p) != nil
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    fileprivate func mouse(_ e: NSEvent) {
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        switch e.type {
        case .rightMouseDown: showMenu(e, at: p)
        case .leftMouseDown where e.modifierFlags.contains(.control): showMenu(e, at: p)
        case .leftMouseDown:
            handle(clicks.mouseDown(p, at: t))
            pressed = friend(at: p)
            if let f = pressed, let o = panel?.frame.origin {
                grab = CGVector(dx: o.x + f.walk.x - p.x, dy: o.y + Self.floor + f.walk.y - p.y)
            }
        case .leftMouseDragged: handle(clicks.mouseMoved(p, at: t))
        case .leftMouseUp:
            var g = clicks.mouseUp(p, at: t)
            if clicks.pollAt != nil { clicks = ClickRecognizer(); g = [.single(p)] }   // no double-click action: answer at once
            handle(g)
            pressed = nil
        default: break
        }
        wake()
    }

    /// The menu swallows the button's release: a friend held up is put down first, and the press ends, so it never
    /// hangs in the air and the panel goes back to letting clicks through.
    private func showMenu(_ e: NSEvent, at p: CGPoint) {
        handle(clicks.cancel(at: p))
        pressed = nil
        guard let v = panel?.contentView else { return }
        FriendMenu.pop([
            FriendMenu.item(L("다른 창보다 위에 두기"), on: store.prefs.onTop) { MeadowStore.shared.prefs.onTop.toggle() },
            FriendMenu.item(L("풀밭 친구들 치우기")) { MeadowStore.shared.prefs.on = false },
        ], with: e, for: v)
        hover()   // the cursor may have left the friend while the menu was up
    }

    private func handle(_ gestures: [ClickRecognizer.Gesture]) {
        guard let f = pressed, let panel else { return }
        for g in gestures {
            switch g {
            case .dragBegan:
                f.held = true
                f.walk.state = .idle
            case .dragged(let p):
                f.walk.x = p.x + grab.dx - panel.frame.minX
                f.walk.y = min(max(0, p.y + grab.dy - panel.frame.minY - Self.floor), panel.frame.height - f.size.height - Self.floor)
                f.walk.vy = 0
            case .dragEnded:
                f.held = false
                f.walk.drop(from: f.walk.y)   // falls back onto the floor
                if still { f.walk = MeadowWalk(x: f.walk.x) }
            case .single, .double:
                if !still { f.walk.hop() }
                guard let i = friends.firstIndex(where: { $0 === f }) else { break }
                MainActor.assumeIsolated {
                    let ask = FriendQuickAsk.shared
                    ask.toggle(from: panel, key: i) { [weak self] in self?.head(i) }
                }
            }
        }
    }
}

/// Never key, never main: touching a friend never takes the focus from the app in front.
private final class MeadowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MeadowView: NSView {
    weak var owner: MeadowFriends?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouse(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouse(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouse(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.mouse(event) }
}
